"""Command line: caption a folder or a Hugging Face dataset into sidecars or a dataset column."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import Any

from . import skills
from .job import Job
from .models import Resolved, resolve
from .runner import Runner
from .sources.local import LocalFolderSource, SidecarSink, atomic_write_json
from .types import ConfigurationError


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="concept-captioner",
        description="Concept-boundary captions for diffusion LoRA training.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="caption images from a folder or an HF dataset")
    run.add_argument("job", type=Path, help="job.yaml")
    source = run.add_argument_group("source (one of)")
    source.add_argument("--images", type=Path, help="folder of images")
    source.add_argument("--repo", help="Hugging Face dataset repo id")
    source.add_argument("--split", default="train")
    source.add_argument("--image-column", default="image")
    source.add_argument("--id-column", default=None)
    sink = run.add_argument_group("sink (default: sidecars next to --out, or the source repo)")
    sink.add_argument("--out", type=Path, help="write <stem>.txt and <stem>.json sidecars here")
    sink.add_argument("--to-repo", help="write a caption column to this HF dataset repo")
    sink.add_argument("--caption-column", default="caption")
    sink.add_argument("--private", action="store_true")
    sink.add_argument("--no-push", action="store_true", help="materialize locally, do not push")
    run.add_argument("--endpoint", help="captioner spec, e.g. google:gemini-3.8-flash")
    run.add_argument("--critic-endpoint", help="critic spec; absent (and no job critic): no critic")
    run.add_argument("--skill", help="skill directory (overrides job.skill)")
    run.add_argument("--profile", help="profile name or .md path (overrides job.profile)")
    run.add_argument("--concurrency", type=int, default=None)
    run.add_argument("--overwrite", action="store_true", help="re-caption samples that have one")
    run.add_argument("--only", nargs="+", metavar="ID", help="caption only these sample ids")
    run.add_argument("--dry-run", action="store_true", help="list samples and mappings; no model")

    hf = sub.add_parser("hf", help="Hugging Face dataset utilities (needs concept-captioner[hf])")
    hfsub = hf.add_subparsers(dest="hf_command", required=True)
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

    prompt = sub.add_parser("show-prompt", help="print the exact instructions for one sample")
    prompt.add_argument("job", type=Path)
    prompt.add_argument("sample_id")
    prompt.add_argument("--critic", action="store_true")

    val = sub.add_parser("validate", help="validate a job file and its skill/profile")
    val.add_argument("job", type=Path)
    return parser


def _print(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=1))


def _models(job: Job, args: argparse.Namespace) -> tuple[Resolved, Resolved | None]:
    if args.endpoint:
        captioner = resolve(args.endpoint, thinking=job.captioner_thinking)
    elif job.endpoints:
        captioner = resolve(job.endpoints.captioner, thinking=job.captioner_thinking)
    else:
        raise ConfigurationError("no captioner: pass --endpoint or set job.endpoints.captioner")
    critic = None
    if args.critic_endpoint:
        critic = resolve(args.critic_endpoint, thinking=job.critic_thinking)
    elif job.endpoints and job.endpoints.critic:
        critic = resolve(job.endpoints.critic, thinking=job.critic_thinking)
    return captioner, critic


def _source(args: argparse.Namespace):
    if args.images and args.repo:
        raise ConfigurationError("pass --images or --repo, not both")
    if args.images:
        return LocalFolderSource(args.images)
    if args.repo:
        from .sources.hf import HFDatasetSource

        return HFDatasetSource(
            args.repo, split=args.split, image_column=args.image_column, id_column=args.id_column
        )
    raise ConfigurationError("pass --images DIR or --repo ID")


def _sink(args: argparse.Namespace, source):
    if args.out and args.to_repo:
        raise ConfigurationError("pass --out or --to-repo, not both")
    if args.out:
        return SidecarSink(args.out)
    if args.to_repo or args.repo:
        from .sources.hf import HFDatasetSink

        return HFDatasetSink(
            source,
            target_repo_id=args.to_repo,
            caption_column=args.caption_column,
            private=args.private or None,
            push=not args.no_push,
        )
    raise ConfigurationError("pass --out DIR or --to-repo ID")


async def _run(args: argparse.Namespace) -> int:
    job = Job.load(args.job)
    skill = skills.load(args.skill or job.skill)
    source = _source(args)
    ids = source.sample_ids
    unmapped = job.unmapped(ids)
    if args.dry_run:
        _print(
            {
                "samples": len(ids),
                "mapped": len(ids) - len(unmapped),
                "needs_mapping": unmapped,
                "skill": skill.name,
                "profile": args.profile or job.profile,
            }
        )
        return 0
    captioner, critic = _models(job, args)
    runner = Runner(
        job=job,
        captioner=captioner,
        critic=critic,
        skill=skill,
        profile=args.profile,
        concurrency=args.concurrency,
        overwrite=args.overwrite,
    )
    sink = _sink(args, source)
    summary = await runner.run(source, sink, only=args.only)
    report = {
        "counts": summary.counts(),
        "elapsed_s": round(summary.elapsed_s, 1),
        "sink": summary.sink,
        "samples": [
            {"id": o.sample_id, "status": o.status, "notes": o.notes} for o in summary.outcomes
        ],
    }
    if args.out:
        atomic_write_json(Path(args.out) / "_summary.json", report)
    _print(report)
    return 0 if summary.counts().get("failed", 0) == 0 else 1


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "run":
            return asyncio.run(_run(args))
        if args.command == "validate":
            job = Job.load(args.job)
            skill = skills.load(job.skill)
            skill.profile(job.profile)
            _print(
                {
                    "ok": True,
                    "skill": skill.name,
                    "profile": job.profile,
                    "triggers": job.triggers,
                    "samples": len(job.samples),
                    "needs_mapping": job.unmapped(list(job.samples)),
                }
            )
            return 0
        if args.command == "show-prompt":
            from .prompt import captioner_instructions, critic_instructions

            job = Job.load(args.job)
            mapping = job.mapping_for(args.sample_id)
            if mapping is None:
                raise ConfigurationError(f"sample {args.sample_id!r} has no mapping in the job")
            skill = skills.load(job.skill)
            profile_text = skill.profile(job.profile)
            build = critic_instructions if args.critic else captioner_instructions
            sys.stdout.write(build(skill, profile_text, job, mapping))
            return 0
        if args.command == "hf":
            from .sources import hf as hfmod

            if args.hf_command == "pull":
                count = hfmod.pull_images(
                    args.repo, args.to, split=args.split, image_column=args.image_column
                )
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
