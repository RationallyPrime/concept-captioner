from __future__ import annotations

import json
from pathlib import Path

from conftest import captioner_ok, critic_ok, function_model, h3
from pydantic_ai import BinaryContent

from concept_captioner.cli import main
from concept_captioner.runner import Runner
from concept_captioner.schemas import Caption, Critique
from concept_captioner.sources.local import LocalFolderSource, SidecarSink


async def test_happy_path_with_critic_writes_mapped_samples(job, images: Path, tmp_path: Path):
    seen_images = []

    def captioner(messages, info):
        seen_images.append(
            [c for c in messages[0].parts[0].content if isinstance(c, BinaryContent)]
        )
        return captioner_ok(messages, info)

    runner = Runner(
        job=job,
        captioner=function_model(captioner, model_name="cap-1"),
        critic=function_model(critic_ok, model_name="crit-1"),
    )
    summary = await runner.run(LocalFolderSource(images), SidecarSink(tmp_path / "out"))
    assert summary.counts() == {"written": 2, "needs_mapping": 1}
    assert all(len(imgs) == 1 for imgs in seen_images)  # the image is attached to every call
    out = tmp_path / "out"
    assert "NORA7" in (out / "solo.txt").read_text()
    record = json.loads((out / "pair.json").read_text())
    assert record["status"] == "written" and record["source"] == "model"
    assert record["captioner"] == {"requested": "cap-1", "served": "cap-1"}
    assert record["critic"]["served"] == "crit-1" and record["critique"]["approved"] is True
    assert "IVAN9" in (out / "pair.txt").read_text()

    # rerun: everything already captioned is skipped without a model call
    calls_before = len(seen_images)
    summary = await runner.run(LocalFolderSource(images), SidecarSink(out))
    assert (
        summary.counts() == {"skipped": 2, "needs_mapping": 1} and len(seen_images) == calls_before
    )

    # a human-final caption survives --overwrite
    record["source"] = "human"
    (out / "pair.json").write_text(json.dumps(record))
    runner.overwrite = True
    summary = await runner.run(
        LocalFolderSource(images), SidecarSink(out), only=["pair.png", "solo.png"]
    )
    statuses = {o.sample_id: o.status for o in summary.outcomes}
    assert statuses == {"pair.png": "skipped", "solo.png": "written"}


async def test_trigger_retry_and_critic_feedback(job, images: Path, tmp_path: Path):
    attempts = {"caption": 0, "critic": 0}

    def captioner(messages, info):
        attempts["caption"] += 1
        last_parts = [p.part_kind for p in messages[-1].parts]
        if attempts["caption"] == 1:
            return Caption(caption=h3("A photograph of a woman by a window."))  # no trigger
        if "retry-prompt" in last_parts:
            return Caption(caption=h3("A photograph of NORA7, a woman, by a window."))
        # reviewer feedback arrives as a plain user turn with the notes
        assert "Reviewer notes" in messages[-1].parts[0].content
        return Caption(caption=h3("A photograph of NORA7, a woman, by a window, in a red coat."))

    def critic(messages, info):
        attempts["critic"] += 1
        caption = messages[0].parts[0].content[0]
        if "red coat" in caption:
            return Critique(approved=True)
        return Critique(approved=False, notes=["the red coat is not described"])

    runner = Runner(job=job, captioner=function_model(captioner), critic=function_model(critic))
    summary = await runner.run(
        LocalFolderSource(images), SidecarSink(tmp_path / "out"), only=["solo.png"]
    )
    (outcome,) = summary.outcomes
    assert outcome.status == "written" and "red coat" in outcome.caption
    assert attempts == {"caption": 3, "critic": 2}  # trigger retry + one feedback round
    assert outcome.record["attempts"] == 2


async def test_unusable_and_rejected_write_records_but_no_caption(
    job, images: Path, tmp_path: Path
):
    def captioner(messages, info):
        return Caption(caption="", usable=False, note="face too small")

    runner = Runner(job=job, captioner=function_model(captioner))
    summary = await runner.run(
        LocalFolderSource(images), SidecarSink(tmp_path / "a"), only=["solo.png"]
    )
    assert summary.outcomes[0].status == "unusable" and summary.outcomes[0].notes == [
        "face too small"
    ]
    assert not (tmp_path / "a" / "solo.txt").exists() and (tmp_path / "a" / "solo.json").exists()

    def never_approve(messages, info):
        return Critique(approved=False, notes=["still wrong"])

    runner = Runner(
        job=job, captioner=function_model(captioner_ok), critic=function_model(never_approve)
    )
    summary = await runner.run(
        LocalFolderSource(images), SidecarSink(tmp_path / "b"), only=["solo.png"]
    )
    assert summary.outcomes[0].status == "rejected" and summary.outcomes[0].notes == ["still wrong"]
    assert not (tmp_path / "b" / "solo.txt").exists()


def test_cli_validate_dry_run_and_show_prompt(images: Path, tmp_path: Path, capsys):
    example = Path(__file__).parent.parent / "examples" / "job.example.yaml"
    assert main(["validate", str(example)]) == 0
    assert '"needs_mapping": [\n  "unmapped.png"\n ]' in capsys.readouterr().out
    assert (
        main(
            [
                "run",
                str(example),
                "--images",
                str(images),
                "--out",
                str(tmp_path / "o"),
                "--dry-run",
            ]
        )
        == 0
    )
    report = json.loads(capsys.readouterr().out)
    assert report["mapped"] == 2 and report["needs_mapping"] == ["unmapped.png"]
    assert main(["show-prompt", str(example), "pair.png"]) == 0
    assert "IVAN9" in capsys.readouterr().out
    assert main(["run", str(example), "--out", str(tmp_path / "o")]) == 2  # no source
