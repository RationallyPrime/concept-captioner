"""Command line: caption a folder or a Hugging Face dataset; pull/push data and jobs."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import Any

from .endpoints import build_endpoint
from .job import Job
from .profiles import load_profile
from .runner import Runner
from .sources.local import LocalFolderSource, SidecarSink, atomic_write_json
from .types import ConfigurationError


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="concept-captioner",
        description="Concept-boundary captions for diffusion LoRA training.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="caption a local folder with sidecar outputs")
    run.add_argument("job", type=Path, help="job.yaml")
    run.add_argument("--images", type=Path, required=True)
    run.add_argument("--out", type=Path, required=True)
    _endpoint_args(run)
    run.add_argument("--dry-run", action="store_true", help="validate the job and list unmapped samples")

    hf = sub.add_parser("hf", help="Hugging Face dataset operations (needs concept-captioner[hf])")
    hfsub = hf.add_subparsers(dest="hf_command", required=True)

    hrun = hfsub.add_parser("run", help="caption a dataset and write captions back as a column")
    hrun.add_argument("job", type=Path)
    hrun.add_argument("--repo", required=True, help="source dataset repo id")
    hrun.add_argument("--split", default="train")
    hrun.add_argument("--image-column", default="image")
    hrun.add_argument("--id-column", default=None)
    hrun.add_argument("--caption-column", default="caption")
    hrun.add_argument("--target-repo", default=None, help="push to a different repo id")
    hrun.add_argument("--private", action="store_true")
    hrun.add_argument("--no-push", action="store_true", help="materialize locally, do not push")
    _endpoint_args(hrun)
    hrun.add_argument("--dry-run", action="store_true")

    pull = hfsub.add_parser("pull", help="download a dataset's images to a folder")
    pull.add_argument("--repo", required=True)
    pull.add_argument("--to", type=Path, required=True)
    pull.add_argument("--split", default="train")
    pull.add_argument("--image-column", default="image")

    pjob = hfsub.add_parser("push-job", help="store job.yaml inside the dataset repo")
    pjob.add_argument("job", type=Path)
    pjob.add_argument("--repo", required=True)

    fjob = hfsub.add_parser("fetch-job", help="download job.yaml from the dataset repo")
    fjob.add_argument("--repo", required=True)
    fjob.add_argument("--to", type=Path, default=Path("job.yaml"))

    prompt = sub.add_parser("show-prompt", help="print the exact system prompt for one sample")
    prompt.add_argument("job", type=Path)
    prompt.add_argument("sample_id")
    prompt.add_argument("--critique", action="store_true")

    val = sub.add_parser("validate", help="validate a job file")
    val.add_argument("job", type=Path)

    return parser


def _endpoint_args(command: argparse.ArgumentParser) -> None:
    command.add_argument(
        "--endpoint",
        help="captioner endpoint spec, e.g. gemini:gemini-3.8-flash or openai:http://localhost:8000/v1#Qwen/Qwen3-VL-32B-Instruct (overrides job.endpoints.captioner)",
    )
    command.add_argument("--critic-endpoint", help="critic endpoint spec (overrides job.endpoints.critic)")
    command.add_argument("--profile", help="profile name or directory (overrides job.profile)")
    command.add_argument("--concurrency", type=int, default=4)
    command.add_argument("--receipts", type=Path, help="write per-call provider receipts to this JSONL file")


def _record_sink(path: Path | None):
    if path is None:
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a", encoding="utf-8")

    def sink(record: dict[str, Any]) -> None:
        handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        handle.flush()

    return sink


def _endpoints(job: Job, args: argparse.Namespace):
    record = _record_sink(args.receipts)
    captioner_spec: Any = args.endpoint or (job.endpoints.captioner.model_dump() if job.endpoints else None)
    if captioner_spec is None:
        raise ConfigurationError("no captioner endpoint: pass --endpoint or set job.endpoints.captioner")
    critic_spec: Any = args.critic_endpoint or (
        job.endpoints.critic.model_dump() if job.endpoints and job.endpoints.critic else None
    )
    captioner = build_endpoint(captioner_spec, concurrency=args.concurrency, record=record)
    critic = build_endpoint(critic_spec, concurrency=args.concurrency, record=record) if critic_spec else None
    return captioner, critic


def _print(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=1))


async def _run_local(args: argparse.Namespace) -> int:
    job = Job.load(args.job)
    profile = load_profile(args.profile or job.profile)
    source = LocalFolderSource(args.images)
    unmapped = [sid for sid in source.sample_ids if job.mapping_for(sid) is None]
    if args.dry_run:
        _print({"images": await source.count(), "mapped": await source.count() - len(unmapped), "needs_mapping": unmapped, "profile": profile.name})
        return 0
    captioner, critic = _endpoints(job, args)
    try:
        runner = Runner(job=job, profile=profile, captioner_endpoint=captioner, critic_endpoint=critic, concurrency=args.concurrency)
        summary = await runner.run(source, SidecarSink(args.out))
    finally:
        await captioner.aclose()
        if critic is not None:
            await critic.aclose()
    report = {"counts": summary.counts(), "elapsed_s": round(summary.elapsed_s, 1), "sink": summary.sink,
              "samples": [{"id": o.sample_id, "status": o.status, "attempts": o.attempts, "issues": o.issues} for o in summary.outcomes]}
    atomic_write_json(Path(args.out) / "_summary.json", report)
    _print({k: v for k, v in report.items() if k != "samples"})
    return 0 if summary.counts().get("failed", 0) == 0 else 1


async def _run_hf(args: argparse.Namespace) -> int:
    from .sources.hf import HFDatasetSink, HFDatasetSource

    job = Job.load(args.job)
    profile = load_profile(args.profile or job.profile)
    source = HFDatasetSource(args.repo, split=args.split, image_column=args.image_column, id_column=args.id_column)
    ids = source.sample_ids
    unmapped = [sid for sid in ids if job.mapping_for(sid) is None]
    if args.dry_run:
        _print({"rows": len(ids), "mapped": len(ids) - len(unmapped), "needs_mapping": unmapped[:50], "profile": profile.name})
        return 0
    sink = HFDatasetSink(source, target_repo_id=args.target_repo, caption_column=args.caption_column, private=args.private or None, push=not args.no_push)
    captioner, critic = _endpoints(job, args)
    try:
        runner = Runner(job=job, profile=profile, captioner_endpoint=captioner, critic_endpoint=critic, concurrency=args.concurrency)
        summary = await runner.run(source, sink)
    finally:
        await captioner.aclose()
        if critic is not None:
            await critic.aclose()
    _print({"counts": summary.counts(), "elapsed_s": round(summary.elapsed_s, 1), "sink": summary.sink})
    return 0 if summary.counts().get("failed", 0) == 0 else 1


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "run":
            return asyncio.run(_run_local(args))
        if args.command == "validate":
            job = Job.load(args.job)
            _print({"ok": True, "profile": job.profile, "triggers": job.triggers, "samples": len(job.samples)})
            return 0
        if args.command == "show-prompt":
            from .policy import build_critique_prompt, build_system_prompt

            job = Job.load(args.job)
            mapping = job.mapping_for(args.sample_id)
            if mapping is None:
                raise ConfigurationError(f"sample {args.sample_id!r} has no mapping in the job")
            profile = load_profile(job.profile)
            text = build_critique_prompt(job, profile, mapping, "<PROPOSED_CAPTION>") if args.critique else build_system_prompt(job, profile, mapping)
            sys.stdout.write(text)
            return 0
        if args.command == "hf":
            if args.hf_command == "run":
                return asyncio.run(_run_hf(args))
            from .sources import hf as hfmod

            if args.hf_command == "pull":
                count = hfmod.pull_images(args.repo, args.to, split=args.split, image_column=args.image_column)
                _print({"written": count, "to": str(args.to)})
                return 0
            if args.hf_command == "push-job":
                Job.load(args.job)  # validate before uploading
                _print({"uploaded": hfmod.push_job(args.repo, args.job)})
                return 0
            if args.hf_command == "fetch-job":
                path = hfmod.fetch_job(args.repo)
                args.to.write_bytes(path.read_bytes())
                _print({"job": str(args.to)})
                return 0
        raise ConfigurationError("unknown command")
    except ConfigurationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
