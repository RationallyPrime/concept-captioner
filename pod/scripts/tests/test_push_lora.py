"""push_lora.py: file selection, the upload plan, the model card and the Hub seam."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "push_lora.py"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


push = _load("push_lora_under_test", SCRIPT)

RUN = {
    "run_id": "nora7-h3-001",
    "dataset": {"path": "/workspace/datasets/faces", "caption_ext": "txt"},
    "triggers": ["NORA7", "IVAN9"],
    "profile": "h3-still",
    "base_model": "black-forest-labs/FLUX.1-dev",
    "steps": 2000,
    "learning_rate": 0.0001,
    "rank": 16,
    "alpha": None,
    "resolution": [512, 768, 1024],
    "batch_size": 1,
    "gradient_accumulation": 1,
    "seed": 42,
    "save_every": 250,
    "sample_every": 250,
    "sample_prompts": ["NORA7 woman, studio portrait, soft key light"],
    "hub": {"repo_id": "someone/nora7-h3-lora", "private": True, "push_on_finish": False},
    "extra": {},
}


class FakeHub:
    def __init__(
        self, *, url: str = "https://huggingface.co/someone/nora7-h3-lora", oid: str = "deadbeef"
    ) -> None:
        self.url = url
        self.oid = oid
        self.calls: list[tuple] = []

    def create_repo(self, repo_id, *, private):
        self.calls.append(("create_repo", repo_id, private))
        return self.url

    def commit(self, repo_id, files, *, commit_message):
        self.calls.append(("commit", repo_id, [path for path, _ in files], commit_message))
        self.contents = dict(files)
        return self.oid


def _touch(path: Path, mtime: int, content: bytes = b"\x00" * 8) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    os.utime(path, (mtime, mtime))
    return path


def make_run(tmp_path: Path, *, run: dict | None = RUN, samples: bool = True) -> Path:
    """An ai-toolkit-shaped run folder: two checkpoints, a newer final file, samples, config, run.json."""
    run_dir = tmp_path / "runs" / "nora7-h3-001"
    output = run_dir / "output" / "nora7-h3-001"
    _touch(output / "nora7-h3-001_000000250.safetensors", 1_000)
    _touch(output / "nora7-h3-001_000000500.safetensors", 2_000)
    _touch(output / "nora7-h3-001.safetensors", 3_000)
    _touch(output / "optimizer.pt", 3_000)
    _touch(run_dir / "preprocessed" / "latents.safetensors", 9_000)  # LTX cache: never a weight
    _touch(run_dir / ".cache" / "x.safetensors", 9_000)
    if samples:
        _touch(run_dir / "samples" / "nora7-h3-001_000000250_0.jpg", 1_000)
        _touch(output / "samples" / "nora7-h3-001_000000500_0.jpg", 2_000)
    (run_dir / "config.yaml").write_text("job: extension\n", encoding="utf-8")
    (run_dir / "trainer.log").write_text("step 500 loss 0.1\n", encoding="utf-8")
    _touch(run_dir / "tensorboard" / "events.out.tfevents.1.scraped", 1_000)
    _touch(run_dir / "tensorboard" / "nora7-h3-001_20261015" / "events.out.tfevents.2", 1_000)
    if run is not None:
        (run_dir / "run.json").write_text(json.dumps(run), encoding="utf-8")
    return run_dir


# --- selection -----------------------------------------------------------------------------------


def test_newest_safetensors_is_selected_by_mtime(tmp_path: Path):
    run_dir = make_run(tmp_path)
    (weight,) = push.select_weights(run_dir, all_checkpoints=False)
    assert push.relative(run_dir, weight) == "output/nora7-h3-001/nora7-h3-001.safetensors"
    # mtime decides, not the name: age the final file and a checkpoint wins
    os.utime(weight, (500, 500))
    (weight,) = push.select_weights(run_dir, all_checkpoints=False)
    assert weight.name == "nora7-h3-001_000000500.safetensors"


def test_all_checkpoints_keeps_every_weight_but_not_caches(tmp_path: Path):
    run_dir = make_run(tmp_path)
    names = [push.relative(run_dir, w) for w in push.select_weights(run_dir, all_checkpoints=True)]
    assert names == [
        "output/nora7-h3-001/nora7-h3-001_000000250.safetensors",
        "output/nora7-h3-001/nora7-h3-001_000000500.safetensors",
        "output/nora7-h3-001/nora7-h3-001.safetensors",
    ]


def test_sample_files_come_from_every_samples_folder(tmp_path: Path):
    run_dir = make_run(tmp_path)
    assert [push.relative(run_dir, p) for p in push.sample_files(run_dir)] == [
        "output/nora7-h3-001/samples/nora7-h3-001_000000500_0.jpg",
        "samples/nora7-h3-001_000000250_0.jpg",
    ]


def test_logs_go_under_logs_as_they_are_now(tmp_path: Path):
    run_dir = make_run(tmp_path)
    (tmp_path / "elsewhere.log").write_text("not this run's", encoding="utf-8")
    (run_dir / "tensorboard" / "linked").symlink_to(tmp_path / "elsewhere.log")
    logs = push.log_files(run_dir)
    assert [path for path, _ in logs] == [
        "logs/trainer.log",
        "logs/tensorboard/events.out.tfevents.1.scraped",
        "logs/tensorboard/nora7-h3-001_20261015/events.out.tfevents.2",
    ]
    (run_dir / "trainer.log").write_text("appended after reading\n", encoding="utf-8")
    assert logs[0][1] == b"step 500 loss 0.1\n"


def test_a_log_that_cannot_be_read_or_is_too_large_is_left_out(tmp_path: Path, monkeypatch):
    run_dir = make_run(tmp_path)
    monkeypatch.setattr(push, "MAX_LOG_BYTES", 10)
    (run_dir / "trainer.log").write_text("x" * 11, encoding="utf-8")
    unreadable = run_dir / "tensorboard" / "events.out.tfevents.1.scraped"
    read_bytes = Path.read_bytes

    def failing_read(path: Path) -> bytes:
        if path == unreadable:
            raise PermissionError("denied")
        return read_bytes(path)

    monkeypatch.setattr(Path, "read_bytes", failing_read)
    names = [path for path, _ in push.log_files(run_dir)]
    assert names == ["logs/tensorboard/nora7-h3-001_20261015/events.out.tfevents.2"]


# --- model card ----------------------------------------------------------------------------------


def test_model_card_content(tmp_path: Path):
    dataset_dir = tmp_path / "datasets" / "faces"
    dataset_dir.mkdir(parents=True)
    (dataset_dir / "manifest.json").write_text(
        json.dumps(
            {
                "repo_id": "someone/faces",
                "revision": "abc123def4567890",
                "count": 120,
                "with_caption": 118,
            }
        )
    )
    run = {**RUN, "dataset": {"path": str(dataset_dir), "caption_ext": "txt"}}
    card = push.model_card(
        run,
        run_id="nora7-h3-001",
        weights=["output/nora7-h3-001/nora7-h3-001.safetensors"],
        samples=2,
        dataset=push.dataset_info(run),
        version="0.2.0",
    )
    head, _, body = card.partition("\n---\n")
    assert head.startswith("---\n")
    assert 'base_model: "black-forest-labs/FLUX.1-dev"' in head
    assert 'instance_prompt: "NORA7"' in head
    assert "  - concept-captioner" in head
    assert 'datasets:\n  - "someone/faces"' in head
    assert body.startswith("\n# nora7-h3-001\n")
    for needle in (
        "| Base model | black-forest-labs/FLUX.1-dev |",
        "| Triggers | `NORA7`, `IVAN9` |",
        "| Steps | 2000 |",
        "| Rank / alpha | 16 / 16 |",  # alpha null -> rank
        "| Learning rate | 0.0001 |",
        "| Resolution | 512, 768, 1024 |",
        "| Caption profile | h3-still |",
        "| Dataset | faces (someone/faces @ abc123def456) |",
        "| Images | 120 (118 captioned) |",
        "| concept-captioner | 0.2.0 |",
        "- `output/nora7-h3-001/nora7-h3-001.safetensors` — LoRA weights",
        "- `samples/` — 2 sample images",
        "- NORA7 woman, studio portrait, soft key light",
        "Put the trigger `NORA7` in the prompt",
        "the other trigger (`IVAN9`) work",
    ):
        assert needle in body, needle


def test_model_card_with_a_sparse_run_json():
    card = push.model_card(
        {},
        run_id="r1",
        weights=["x.safetensors"],
        samples=0,
        dataset=push.dataset_info({}),
        version="unknown",
    )
    assert "base_model" not in card.split("\n---\n")[0]
    assert "instance_prompt" not in card
    assert "| Triggers | — |" in card
    assert "- no samples uploaded" in card
    assert "## Use" not in card


def test_dataset_info_falls_back_to_job_yaml_profile(tmp_path: Path):
    dataset_dir = tmp_path / "faces"
    dataset_dir.mkdir()
    (dataset_dir / "job.yaml").write_text(
        "# fixture\nprofile: flux-image   # comment\nconcepts: []\n", encoding="utf-8"
    )
    info = push.dataset_info({"dataset": {"path": str(dataset_dir)}})
    assert info == {"name": "faces", "manifest": None, "profile": "flux-image"}
    run = {"dataset": {"path": str(dataset_dir)}, "profile": None}
    assert "| Caption profile | flux-image |" in push.model_card(
        run, run_id="r", weights=[], samples=0, dataset=info, version="x"
    )
    assert push.dataset_info({}) == {"name": None, "manifest": None, "profile": None}


def test_concept_captioner_version_never_raises(monkeypatch):
    assert isinstance(push.concept_captioner_version(), str)
    monkeypatch.setattr(push.metadata, "version", lambda name: "9.9.9")
    assert push.concept_captioner_version() == "9.9.9"


# --- main() over the fake Hub --------------------------------------------------------------------


def test_main_pushes_newest_weight_card_and_samples(tmp_path: Path, capsys):
    run_dir = make_run(tmp_path)
    hub = FakeHub()
    assert (
        push.main(
            ["--run-dir", str(run_dir), "--repo", "someone/nora7-h3-lora", "--private"], hub=hub
        )
        == 0
    )
    assert hub.calls[0] == ("create_repo", "someone/nora7-h3-lora", True)
    kind, repo, files, message = hub.calls[1]
    assert (kind, repo) == ("commit", "someone/nora7-h3-lora")
    assert files == [
        "output/nora7-h3-001/nora7-h3-001.safetensors",
        "run.json",
        "config.yaml",
        "output/nora7-h3-001/samples/nora7-h3-001_000000500_0.jpg",
        "samples/nora7-h3-001_000000250_0.jpg",
        "logs/trainer.log",
        "logs/tensorboard/events.out.tfevents.1.scraped",
        "logs/tensorboard/nora7-h3-001_20261015/events.out.tfevents.2",
        "README.md",
    ]
    assert hub.contents["README.md"] == run_dir / "README.md"
    assert message == "Upload LoRA nora7-h3-001 (push_lora.py)"
    card = (run_dir / "README.md").read_text(encoding="utf-8")
    assert "`NORA7`" in card and "black-forest-labs/FLUX.1-dev" in card
    assert "- `logs/` — the trainer log and TensorBoard event files" in card
    receipt = json.loads((run_dir / "push.json").read_text(encoding="utf-8"))
    assert receipt["commit"] == "deadbeef"
    assert receipt["url"] == "https://huggingface.co/someone/nora7-h3-lora"
    assert receipt["files"] == files
    out = capsys.readouterr().out
    assert out.strip().endswith("https://huggingface.co/someone/nora7-h3-lora")
    assert "9 files" in out


def test_main_flags_no_samples_all_checkpoints_commit_message(tmp_path: Path):
    run_dir = make_run(tmp_path)
    hub = FakeHub()
    args = [
        "--run-dir",
        str(run_dir),
        "--repo",
        "someone/x",
        "--no-samples",
        "--all-checkpoints",
        "--commit-message",
        "final",
    ]
    assert push.main(args, hub=hub) == 0
    assert hub.calls[0] == ("create_repo", "someone/x", False)
    _, _, files, message = hub.calls[1]
    assert message == "final"
    assert [p for p in files if p.endswith(".safetensors")] == [
        "output/nora7-h3-001/nora7-h3-001_000000250.safetensors",
        "output/nora7-h3-001/nora7-h3-001_000000500.safetensors",
        "output/nora7-h3-001/nora7-h3-001.safetensors",
    ]
    assert not any("samples" in p for p in files)
    receipt = json.loads((run_dir / "push.json").read_text(encoding="utf-8"))
    assert not any("samples" in f for f in receipt["files"])


def test_main_exits_1_without_weights_and_touches_nothing(tmp_path: Path, capsys):
    run_dir = make_run(tmp_path)
    for path in run_dir.rglob("*.safetensors"):
        if "preprocessed" not in path.parts and ".cache" not in path.parts:
            path.unlink()
    hub = FakeHub()
    assert push.main(["--run-dir", str(run_dir), "--repo", "someone/x"], hub=hub) == 1
    assert "no .safetensors" in capsys.readouterr().err
    assert hub.calls == []
    assert not (run_dir / "README.md").exists()
    assert not (run_dir / "push.json").exists()


def test_main_without_run_json_uses_the_folder_name(tmp_path: Path):
    run_dir = make_run(tmp_path, run=None, samples=False)
    hub = FakeHub()
    assert push.main(["--run-dir", str(run_dir), "--repo", "someone/x"], hub=hub) == 0
    _, _, files, message = hub.calls[1]
    assert "run.json" not in files
    assert message == "Upload LoRA nora7-h3-001 (push_lora.py)"
    assert (
        (run_dir / "README.md")
        .read_text(encoding="utf-8")
        .split("\n---\n")[1]
        .startswith("\n# nora7-h3-001\n")
    )


def test_main_rejects_a_missing_run_dir(tmp_path: Path, capsys):
    assert (
        push.main(["--run-dir", str(tmp_path / "nope"), "--repo", "someone/x"], hub=FakeHub()) == 1
    )
    assert "is not a directory" in capsys.readouterr().err


# --- the script as a program ---------------------------------------------------------------------


def test_help_runs_isolated_without_heavy_imports():
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "SYSTEMROOT")}
    result = subprocess.run(
        [sys.executable, "-I", str(SCRIPT), "--help"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "--all-checkpoints" in result.stdout
    probe = (
        "import importlib.util, sys\n"
        f"spec = importlib.util.spec_from_file_location('m', {str(SCRIPT)!r})\n"
        "m = importlib.util.module_from_spec(spec); sys.modules['m'] = m; spec.loader.exec_module(m)\n"
        "print(sorted(k.split('.')[0] for k in sys.modules if k.split('.')[0] in {'huggingface_hub', 'datasets', 'PIL', 'pydantic'}))\n"
    )
    result = subprocess.run(
        [sys.executable, "-I", "-c", probe], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "[]"
