"""Tests for scripts/launch_aitoolkit.py and scripts/launch_ltx.py (POD-SPEC §4.3).

No GPU, no trainer, no network: the trainer and push commands are replaced by small
``python -c`` programs, the TensorBoard writer by a recording fake. PyYAML is exercised when
importable; the stdlib YAML emitter always is.
"""

from __future__ import annotations

import errno
import importlib.util
import io
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
RUN_ID = "nora7-h3-001"
PROMPT = "NORA7 woman, studio portrait, soft key light"


def load_script(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


aitoolkit = load_script("launch_aitoolkit")
ltx = load_script("launch_ltx")
WRAPPERS = {"aitoolkit": aitoolkit, "ltx": ltx}


class FakeWriter:
    """Stands in for torch.utils.tensorboard.SummaryWriter."""

    def __init__(self) -> None:
        self.scalars: list[tuple[str, float, int]] = []
        self.flushed = 0
        self.closed = False

    def add_scalar(self, tag: str, value: float, step: int) -> None:
        self.scalars.append((tag, value, step))

    def flush(self) -> None:
        self.flushed += 1

    def close(self) -> None:
        self.closed = True


@pytest.fixture(params=sorted(WRAPPERS))
def wrapper(request: pytest.FixtureRequest) -> ModuleType:
    return WRAPPERS[request.param]


@pytest.fixture
def workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """A workspace with datasets/faces (two captioned images, one without) and runs/<id>/."""
    root = tmp_path.resolve() / "workspace"
    dataset = root / "datasets" / "faces"
    dataset.mkdir(parents=True)
    (dataset / "0001.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    (dataset / "0001.txt").write_text(f"{PROMPT}\n", encoding="utf-8")
    (dataset / "0002.jpg").write_bytes(b"\xff\xd8\xff")
    (dataset / "0002.txt").write_text("NORA7 woman, outdoors, overcast light", encoding="utf-8")
    (dataset / "0003.png").write_bytes(b"\x89PNG\r\n\x1a\n")  # no caption: skipped by ltx
    (dataset / "notes.md").write_text("not media", encoding="utf-8")
    (root / "runs" / RUN_ID).mkdir(parents=True)
    (root / "models" / "gemma").mkdir(parents=True)
    (root / "models" / "ltx-2.safetensors").write_bytes(b"\x00")
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(root))
    return root


def run_config(workspace: Path, **overrides: Any) -> dict[str, Any]:
    cfg: dict[str, Any] = {
        "run_id": RUN_ID,
        "dataset": {"path": str(workspace / "datasets" / "faces"), "caption_ext": "txt"},
        "triggers": ["NORA7"],
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
        "sample_prompts": [PROMPT],
        "hub": {"repo_id": "you/nora7-h3-lora", "private": True, "push_on_finish": False},
        "hf_token": None,
        "extra": {},
    }
    cfg.update(overrides)
    return cfg


def ltx_model(workspace: Path) -> str:
    """LTX-2 loads local files only: the checkpoint lives under <workspace>/models."""
    return str(workspace / "models" / "ltx-2.safetensors")


def ltx_text_encoder(workspace: Path) -> str:
    return str(workspace / "models" / "gemma")


def ltx_run_config(workspace: Path, **overrides: Any) -> dict[str, Any]:
    """``run_config`` the LTX wrapper accepts: a local checkpoint and the Gemma path in extra.

    An ``extra`` override is deep-merged over the default ``{"model": {"text_encoder_path"}}``
    (a non-mapping ``model`` replaces it, as the wrapper's own merge would).
    """
    extra = {"model": {"text_encoder_path": ltx_text_encoder(workspace)}}
    if "extra" in overrides:
        extra = ltx.deep_merge(extra, overrides.pop("extra"))
    overrides.setdefault("base_model", ltx_model(workspace))
    return run_config(workspace, extra=extra, **overrides)


def run_config_for(wrapper: ModuleType, workspace: Path, **overrides: Any) -> dict[str, Any]:
    """The run config each wrapper can turn into a native config."""
    if wrapper is ltx:
        return ltx_run_config(workspace, **overrides)
    return run_config(workspace, **overrides)


def write_run_json(workspace: Path, cfg: dict[str, Any]) -> Path:
    path = workspace / "runs" / RUN_ID / "run.json"
    path.write_text(json.dumps(cfg), encoding="utf-8")
    return path


def fake_command(script: str) -> list[str]:
    return [sys.executable, "-c", script]


def load_yaml_if_available(path: Path) -> Any:
    yaml = pytest.importorskip("yaml")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


# --- the shared block is really shared --------------------------------------------------------


def shared_block(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    start = text.index("# --- shared:")
    end = text.index("# --- end shared")
    return text[start:end]


def test_shared_block_identical_between_wrappers() -> None:
    assert shared_block(SCRIPTS / "launch_aitoolkit.py") == shared_block(SCRIPTS / "launch_ltx.py")


@pytest.mark.parametrize("name", sorted(WRAPPERS))
def test_help_runs_in_isolated_mode(name: str) -> None:
    """`python -I script --help` needs nothing beyond the standard library (scripts/README)."""
    result = subprocess.run(
        [sys.executable, "-I", str(SCRIPTS / f"launch_{name}.py"), "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "--config" in result.stdout


# --- validation ---------------------------------------------------------------------------------


def test_validate_applies_defaults(wrapper: ModuleType, workspace: Path) -> None:
    minimal = {
        "run_id": RUN_ID,
        "dataset": {"path": str(workspace / "datasets" / "faces")},
        "triggers": ["NORA7", "IVAN9"],
        "base_model": "black-forest-labs/FLUX.1-dev",
    }
    cfg = wrapper.validate_run_config(minimal, workspace)
    assert cfg["dataset"] == {
        "path": str(workspace / "datasets" / "faces"),
        "caption_ext": "txt",
    }
    assert cfg["triggers"] == ["NORA7", "IVAN9"]
    assert cfg["profile"] is None
    assert cfg["steps"] == 2000
    assert cfg["learning_rate"] == pytest.approx(1e-4)
    assert cfg["rank"] == 16
    assert cfg["alpha"] == 16  # defaults to rank
    assert cfg["resolution"] == [512, 768, 1024]
    assert cfg["batch_size"] == 1
    assert cfg["gradient_accumulation"] == 1
    assert cfg["seed"] == 42
    assert cfg["save_every"] == 250
    assert cfg["sample_every"] == 250
    assert cfg["sample_prompts"] == []
    assert cfg["hub"] is None
    assert cfg["hf_token"] is None
    assert cfg["extra"] == {}


def test_validate_normalises_scalars(wrapper: ModuleType, workspace: Path) -> None:
    cfg = wrapper.validate_run_config(
        run_config(
            workspace,
            resolution=768,
            alpha=8,
            dataset={"path": str(workspace / "datasets" / "faces"), "caption_ext": ".caption"},
            hub={"repo_id": "you/nora7"},
        ),
        workspace,
    )
    assert cfg["resolution"] == [768]
    assert cfg["alpha"] == 8
    assert cfg["dataset"]["caption_ext"] == "caption"
    assert cfg["hub"] == {"repo_id": "you/nora7", "private": True, "push_on_finish": False}


@pytest.mark.parametrize(
    ("overrides", "fragment"),
    [
        ({"run_id": "-bad"}, "run_id"),
        ({"run_id": "x" * 65}, "run_id"),
        ({"triggers": []}, "triggers"),
        ({"triggers": ["NORA7", ""]}, "triggers"),
        ({"base_model": ""}, "base_model"),
        ({"steps": 0}, "steps"),
        ({"steps": True}, "steps"),
        ({"steps": 2.5}, "steps"),
        ({"learning_rate": 0}, "learning_rate"),
        ({"learning_rate": "1e-4"}, "learning_rate"),
        ({"rank": 0}, "rank"),
        ({"alpha": 0}, "alpha"),
        ({"resolution": []}, "resolution"),
        ({"resolution": [512, "768"]}, "resolution"),
        ({"seed": -1}, "seed"),
        ({"save_every": 0}, "save_every"),
        ({"sample_every": -1}, "sample_every"),
        ({"sample_prompts": "NORA7"}, "sample_prompts"),
        ({"hub": {"repo_id": "no-slash"}}, "hub.repo_id"),
        ({"hub": {"repo_id": "you/x", "private": 1}}, "hub.private"),
        ({"hub": {"repo_id": "you/x", "push": True}}, "hub: unknown keys"),
        ({"hf_token": ""}, "hf_token"),
        ({"extra": []}, "extra"),
        ({"bogus": 1}, "unknown keys: bogus"),
        ({"dataset": {"path": "/elsewhere/faces"}}, "dataset.path: must resolve under"),
        ({"dataset": {"path": "", "caption_ext": "txt"}}, "dataset.path"),
        ({"dataset": {"path": "x", "caption_ext": "a/b"}}, "dataset.caption_ext"),
        ({"dataset": "faces"}, "dataset: must be an object"),
    ],
)
def test_validate_rejects(
    wrapper: ModuleType, workspace: Path, overrides: dict[str, Any], fragment: str
) -> None:
    with pytest.raises(wrapper.ConfigError, match=fragment):
        wrapper.validate_run_config(run_config(workspace, **overrides), workspace)


def test_validate_requires_existing_dataset_dir(wrapper: ModuleType, workspace: Path) -> None:
    cfg = run_config(workspace, dataset={"path": str(workspace / "datasets" / "missing")})
    with pytest.raises(wrapper.ConfigError, match="is not a directory"):
        wrapper.validate_run_config(cfg, workspace)


def test_validate_reports_every_error_at_once(wrapper: ModuleType, workspace: Path) -> None:
    with pytest.raises(wrapper.ConfigError) as excinfo:
        wrapper.validate_run_config({"run_id": "ok", "nope": 1}, workspace)
    message = str(excinfo.value)
    for fragment in ("unknown keys: nope", "dataset: required", "triggers: required", "base_model"):
        assert fragment in message


def test_validate_rejects_non_object(wrapper: ModuleType) -> None:
    with pytest.raises(wrapper.ConfigError):
        wrapper.validate_run_config(["not", "a", "dict"])


# --- deep merge and YAML ------------------------------------------------------------------------


def test_deep_merge(wrapper: ModuleType) -> None:
    base = {"a": {"b": 1, "c": [1, 2]}, "d": 4}
    override = {"a": {"b": 2, "c": [3], "e": {"f": 5}}, "g": None}
    assert wrapper.deep_merge(base, override) == {
        "a": {"b": 2, "c": [3], "e": {"f": 5}},
        "d": 4,
        "g": None,
    }
    assert base == {"a": {"b": 1, "c": [1, 2]}, "d": 4}  # untouched


SAMPLE_DOC: dict[str, Any] = {
    "job": "extension",
    "config": {
        "name": RUN_ID,
        "process": [
            {
                "type": "sd_trainer",
                "lr": 1e-05,
                "lr2": 0.0001,
                "flag": True,
                "nothing": None,
                "big": 1.5e20,
                "resolution": [512, 768],
                "prompts": ['say "hi": [trigger]', "unicode ✓"],
                "empty_map": {},
                "empty_list": [],
                "nested": [{"a": 1, "b": [1, {"c": 2}]}, [1, 2]],
                "true": "a reserved-word key",
                "with space": 1,
            }
        ],
    },
    "meta": {"name": "[name]", "version": "1.0"},
}

EXPECTED_FALLBACK_YAML = """\
job: "extension"
config:
  name: "nora7-h3-001"
  process:
    - type: "sd_trainer"
      lr: 1.0e-05
      lr2: 0.0001
      flag: true
      nothing: null
      big: 1.5e+20
      resolution:
        - 512
        - 768
      prompts:
        - "say \\"hi\\": [trigger]"
        - "unicode ✓"
      empty_map: {}
      empty_list: []
      nested:
        - a: 1
          b:
            - 1
            - c: 2
        - - 1
          - 2
      "true": "a reserved-word key"
      "with space": 1
meta:
  name: "[name]"
  version: "1.0"
"""


def test_stdlib_yaml_emitter_output(wrapper: ModuleType, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(sys.modules, "yaml", None)  # makes `import yaml` raise ImportError
    assert wrapper.dump_yaml(SAMPLE_DOC) == EXPECTED_FALLBACK_YAML


def test_stdlib_yaml_emitter_round_trips_through_pyyaml(wrapper: ModuleType) -> None:
    yaml = pytest.importorskip("yaml")
    assert yaml.safe_load(EXPECTED_FALLBACK_YAML) == SAMPLE_DOC
    assert isinstance(yaml.safe_load("lr: 1.0e-05")["lr"], float)


def test_pyyaml_path_round_trips(wrapper: ModuleType) -> None:
    yaml = pytest.importorskip("yaml")
    text = wrapper.dump_yaml(SAMPLE_DOC)
    assert yaml.safe_load(text) == SAMPLE_DOC


def test_yaml_float_formatting(wrapper: ModuleType) -> None:
    assert wrapper._yaml_float(1e-05) == "1.0e-05"
    assert wrapper._yaml_float(0.0001) == "0.0001"
    assert wrapper._yaml_float(2.0) == "2.0"
    assert wrapper._yaml_float(1.5e20) == "1.5e+20"
    assert wrapper._yaml_float(float("inf")) == ".inf"
    assert wrapper._yaml_float(float("-inf")) == "-.inf"
    assert wrapper._yaml_float(float("nan")) == ".nan"


def test_yaml_rejects_unknown_types(wrapper: ModuleType, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(sys.modules, "yaml", None)
    with pytest.raises(TypeError):
        wrapper.dump_yaml({"path": Path("/x")})


# --- ai-toolkit mapping -------------------------------------------------------------------------


def expected_aitoolkit(workspace: Path) -> dict[str, Any]:
    run = workspace / "runs" / RUN_ID
    return {
        "job": "extension",
        "config": {
            "name": RUN_ID,
            "process": [
                {
                    "type": "sd_trainer",
                    "training_folder": str(run / "output"),
                    "device": "cuda:0",
                    "trigger_word": "NORA7",
                    "log_dir": str(run / "tensorboard"),
                    "network": {"type": "lora", "linear": 16, "linear_alpha": 16},
                    "save": {
                        "dtype": "float16",
                        "save_every": 250,
                        "max_step_saves_to_keep": 4,
                        "push_to_hub": False,
                    },
                    "datasets": [
                        {
                            "folder_path": str(workspace / "datasets" / "faces"),
                            "caption_ext": "txt",
                            "resolution": [512, 768, 1024],
                            "cache_latents_to_disk": True,
                            "caption_dropout_rate": 0.05,
                        }
                    ],
                    "train": {
                        "batch_size": 1,
                        "steps": 2000,
                        "gradient_accumulation_steps": 1,
                        "lr": 0.0001,
                        "dtype": "bf16",
                        "optimizer": "adamw8bit",
                        "noise_scheduler": "flowmatch",
                        "gradient_checkpointing": True,
                        "train_text_encoder": False,
                        "disable_sampling": False,
                    },
                    "model": {
                        "name_or_path": "black-forest-labs/FLUX.1-dev",
                        "arch": "flux",
                        "is_flux": True,
                        "quantize": True,
                    },
                    "sample": {
                        "sampler": "flowmatch",
                        "sample_every": 250,
                        "width": 1024,
                        "height": 1024,
                        "prompts": [PROMPT],
                        "seed": 42,
                        "guidance_scale": 4,
                        "sample_steps": 20,
                    },
                }
            ],
        },
        "meta": {"name": "[name]", "version": "1.0"},
    }


def test_aitoolkit_dry_run_writes_expected_yaml(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    run_json = write_run_json(workspace, run_config(workspace))
    assert aitoolkit.main(["--config", str(run_json), "--dry-run"]) == 0
    run = workspace / "runs" / RUN_ID
    config_yaml = run / "config.yaml"
    assert config_yaml.is_file()
    text = config_yaml.read_text(encoding="utf-8")
    assert text.startswith("# ai-toolkit config written by launch_aitoolkit.py")
    cfg = aitoolkit.validate_run_config(run_config(workspace), workspace)
    assert aitoolkit.build_native_config(cfg, run) == expected_aitoolkit(workspace)
    out = capsys.readouterr().out
    assert "trainer command:" in out and "run.py" in out and "dry run" in out
    assert not (run / "output").exists()  # dry run starts nothing and creates no run dirs
    if importlib.util.find_spec("yaml") is not None:
        assert load_yaml_if_available(config_yaml) == expected_aitoolkit(workspace)


def test_aitoolkit_model_block_by_family() -> None:
    assert aitoolkit.model_block("black-forest-labs/FLUX.1-dev") == {
        "name_or_path": "black-forest-labs/FLUX.1-dev",
        "arch": "flux",
        "is_flux": True,
        "quantize": True,
    }
    assert aitoolkit.model_block("/workspace/models/MiniMax-H3") == {
        "name_or_path": "/workspace/models/MiniMax-H3",
        "arch": "h3",
        "quantize": True,
    }
    assert aitoolkit.model_block("vendor/h3-base") == {
        "name_or_path": "vendor/h3-base",
        "arch": "h3",
        "quantize": True,
    }
    assert aitoolkit.model_block("vendor/sh3ll") == {"name_or_path": "vendor/sh3ll"}
    assert aitoolkit.model_block("stabilityai/sdxl") == {"name_or_path": "stabilityai/sdxl"}


def test_aitoolkit_disables_sampling_without_prompts(workspace: Path) -> None:
    run = workspace / "runs" / RUN_ID
    cfg = aitoolkit.validate_run_config(run_config(workspace, sample_prompts=[]), workspace)
    process = aitoolkit.build_native_config(cfg, run)["config"]["process"][0]
    assert process["train"]["disable_sampling"] is True
    assert process["sample"]["sample_every"] == 2000  # never 0: ai-toolkit takes step % it
    cfg = aitoolkit.validate_run_config(run_config(workspace, sample_every=0), workspace)
    process = aitoolkit.build_native_config(cfg, run)["config"]["process"][0]
    assert process["train"]["disable_sampling"] is True


def test_aitoolkit_extra_deep_merge(workspace: Path) -> None:
    run = workspace / "runs" / RUN_ID
    extra = {
        "train": {"optimizer": "prodigy", "lr": 1.0, "ema_config": {"use_ema": True}},
        "model": {"arch": "flex1", "quantize": False},
        "meta": {"version": "2.0"},
        "config": {"name": "renamed"},
        "datasets": [{"folder_path": str(workspace / "datasets" / "other")}],
    }
    cfg = aitoolkit.validate_run_config(run_config(workspace, extra=extra), workspace)
    doc = aitoolkit.build_native_config(cfg, run)
    expected = expected_aitoolkit(workspace)
    process = doc["config"]["process"][0]
    assert process["train"]["optimizer"] == "prodigy"
    assert process["train"]["lr"] == 1.0
    assert process["train"]["ema_config"] == {"use_ema": True}
    assert process["train"]["steps"] == 2000  # siblings survive
    assert process["model"] == {
        "name_or_path": "black-forest-labs/FLUX.1-dev",
        "arch": "flex1",
        "is_flux": True,
        "quantize": False,
    }
    # lists replace
    assert process["datasets"] == [{"folder_path": str(workspace / "datasets" / "other")}]
    assert doc["meta"] == {"name": "[name]", "version": "2.0"}
    assert doc["config"]["name"] == "renamed"
    assert doc["job"] == "extension"
    assert process["network"] == expected["config"]["process"][0]["network"]


@pytest.mark.parametrize(
    ("extra", "fragment"),
    [
        ({"training_folder": "/opt/venvs/agent"}, r"training_folder"),
        ({"training_folder": "output"}, r"training_folder"),  # relative: never
        ({"log_dir": "/var/log"}, r"log_dir"),
        ({"datasets": [{"folder_path": "/"}]}, r"datasets\[0\]\.folder_path"),
        ({"datasets": [{"caption_ext": "txt"}]}, r"datasets\[0\]\.folder_path"),  # dropped
        ({"datasets": "faces"}, r"datasets: must be a list"),
        ({"model": {"name_or_path": "/etc"}}, r"model\.name_or_path"),
        ({"model": {"name_or_path": "../../etc/passwd"}}, r"model\.name_or_path"),
        ({"model": {"name_or_path": None}}, r"model\.name_or_path"),
        ({"model": "flux"}, r"model: must be a mapping"),
        ({"config": {"name": "../escape"}}, r"config\.name"),
        ({"config": {"name": "/"}}, r"config\.name"),
        (
            {"config": {"process": [{"type": "sd_trainer", "training_folder": "/"}]}},
            r"training_folder",
        ),
        ({"config": {"process": []}}, r"config\.process"),
        ({"config": "nope"}, r"config: must be a mapping"),
    ],
)
def test_aitoolkit_extra_cannot_leave_the_workspace(
    workspace: Path, extra: dict[str, Any], fragment: str
) -> None:
    """The finding: ``extra`` merges last, so every path it can reach is re-checked after."""
    run = workspace / "runs" / RUN_ID
    cfg = aitoolkit.validate_run_config(run_config(workspace, extra=extra), workspace)
    with pytest.raises(aitoolkit.ConfigError, match=fragment):
        aitoolkit.build_native_config(cfg, run)


def test_aitoolkit_extra_paths_inside_the_workspace_are_fine(workspace: Path) -> None:
    run = workspace / "runs" / RUN_ID
    extra = {
        "training_folder": str(workspace / "runs" / "shared-output"),
        "log_dir": None,  # no native logging: nothing to check
        "datasets": [
            {"folder_path": str(workspace / "datasets" / "faces")},
            {"folder_path": str(run / "extra-dataset")},  # the run directory is a root too
        ],
        "model": {"name_or_path": str(workspace / "models" / "h3")},
    }
    cfg = aitoolkit.validate_run_config(run_config(workspace, extra=extra), workspace)
    process = aitoolkit.build_native_config(cfg, run)["config"]["process"][0]
    assert process["training_folder"] == str(workspace / "runs" / "shared-output")
    assert process["log_dir"] is None
    assert process["model"]["name_or_path"] == str(workspace / "models" / "h3")


def test_aitoolkit_dry_run_refuses_extra_outside_workspace(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """End to end: the scenario from the finding exits 2 and writes no config.yaml."""
    extra = {"training_folder": "/opt/venvs/agent", "datasets": [{"folder_path": "/"}]}
    run_json = write_run_json(workspace, run_config(workspace, extra=extra))
    assert aitoolkit.main(["--config", str(run_json), "--dry-run"]) == 2
    out = capsys.readouterr().out
    assert "invalid run config" in out and "training_folder" in out and "folder_path" in out
    assert not (workspace / "runs" / RUN_ID / "config.yaml").exists()


# --- LTX mapping --------------------------------------------------------------------------------


def expected_ltx(workspace: Path) -> dict[str, Any]:
    run = workspace / "runs" / RUN_ID
    return {
        "model": {
            "model_path": ltx_model(workspace),
            "text_encoder_path": ltx_text_encoder(workspace),
            "training_mode": "lora",
            "load_checkpoint": None,
        },
        "lora": {"rank": 16, "alpha": 16},
        "optimization": {
            "learning_rate": 0.0001,
            "steps": 2000,
            "batch_size": 1,
            "gradient_accumulation_steps": 1,
            "enable_gradient_checkpointing": True,
        },
        "acceleration": {"mixed_precision_mode": "bf16"},
        "data": {"preprocessed_data_root": str(run / "preprocessed")},
        "validation": {
            "prompts": [PROMPT],
            "interval": 250,
            "seed": 42,
            "video_dims": [1024, 1024, 1],
        },
        "checkpoints": {"interval": 250, "keep_last_n": 4},
        "seed": 42,
        "output_dir": str(run / "output"),
    }


def test_ltx_dry_run_writes_expected_files(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    run_json = write_run_json(workspace, ltx_run_config(workspace))
    assert ltx.main(["--config", str(run_json), "--dry-run"]) == 0
    run = workspace / "runs" / RUN_ID
    config_yaml = run / "config.yaml"
    assert config_yaml.read_text(encoding="utf-8").startswith("# LTX-2 trainer config")
    cfg = ltx.validate_run_config(ltx_run_config(workspace), workspace)
    assert ltx.build_native_config(cfg, run) == expected_ltx(workspace)
    entries = json.loads((run / "dataset.json").read_text(encoding="utf-8"))
    faces = workspace / "datasets" / "faces"
    assert entries == [
        {"caption": PROMPT, "media_path": str(faces / "0001.png")},
        {"caption": "NORA7 woman, outdoors, overcast light", "media_path": str(faces / "0002.jpg")},
    ]
    out = capsys.readouterr().out
    assert "2 items, 1 without a caption skipped" in out
    assert "--resolution-buckets 1024x1024x1" in out
    assert f"--model-path {ltx_model(workspace)}" in out
    assert f"--text-encoder-path {ltx_text_encoder(workspace)}" in out
    assert "--model-source" not in out
    assert "process_dataset.py" in out and "train.py" in out
    assert not (run / "preprocessed").exists()
    if importlib.util.find_spec("yaml") is not None:
        assert load_yaml_if_available(config_yaml) == expected_ltx(workspace)


def test_ltx_preprocess_argv(workspace: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LTX_TRAINER_DIR", "/opt/ltx-x")
    monkeypatch.delenv("LTX_PREPROCESS_SCRIPT", raising=False)
    run = workspace / "runs" / RUN_ID
    cfg = ltx.validate_run_config(ltx_run_config(workspace), workspace)
    assert ltx.preprocess_argv(run, cfg) == [
        sys.executable,
        "/opt/ltx-x/scripts/process_dataset.py",
        str(run / "dataset.json"),
        "--resolution-buckets",
        "1024x1024x1",
        "--caption-column",
        "caption",
        "--video-column",
        "media_path",
        "--model-path",
        ltx_model(workspace),
        "--text-encoder-path",
        ltx_text_encoder(workspace),
        "--output-dir",
        str(run / "preprocessed"),
    ]
    monkeypatch.setenv("LTX_PREPROCESS_SCRIPT", "/custom/pre.py")
    monkeypatch.setenv("LTX_TRAIN_SCRIPT", "/custom/train.py")
    assert ltx.preprocess_argv(run, cfg)[1] == "/custom/pre.py"
    assert ltx.trainer_argv(run, cfg) == [
        sys.executable,
        "/custom/train.py",
        str(run / "config.yaml"),
    ]


IMAGES = SCRIPTS.parent / "images"
LTX_DOCKERFILE = IMAGES / "Dockerfile.ltx"
LTX_IMAGE_ENTRYPOINTS = {
    "/opt/ltx-2/packages/ltx-trainer/scripts/process_dataset.py",
    "/opt/ltx-2/packages/ltx-trainer/scripts/train.py",
}


def ltx_image_env() -> dict[str, str]:
    """The ``ENV LTX_*=…`` lines of images/Dockerfile.ltx."""
    text = LTX_DOCKERFILE.read_text(encoding="utf-8")
    return dict(re.findall(r"^ENV (LTX_\w+)=(\S+)$", text, re.MULTILINE))


def test_ltx_image_env_points_the_wrapper_at_the_trainer_package(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """With the image's ENV the wrapper's defaults are exactly the two files the build checks."""
    env = ltx_image_env()
    assert "LTX_TRAINER_DIR" in env, "Dockerfile.ltx must set LTX_TRAINER_DIR for launch_ltx.py"
    for key in ("LTX_TRAINER_DIR", "LTX_PREPROCESS_SCRIPT", "LTX_TRAIN_SCRIPT"):
        monkeypatch.delenv(key, raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    computed = {str(ltx.preprocess_script()), str(ltx.train_script())}
    assert computed == LTX_IMAGE_ENTRYPOINTS
    # The wrapper's own default is the workspace root, which has no scripts/ directory: the ENV
    # is load-bearing, not decoration.
    monkeypatch.delenv("LTX_TRAINER_DIR")
    assert {str(ltx.preprocess_script()), str(ltx.train_script())}.isdisjoint(LTX_IMAGE_ENTRYPOINTS)


def test_ltx_image_build_check_runs_the_wrapper(tmp_path: Path) -> None:
    """The build-time check in Dockerfile.ltx imports launch_ltx.py and fails on a missing file."""
    text = LTX_DOCKERFILE.read_text(encoding="utf-8")
    match = re.search(r"/opt/venvs/agent/bin/python -I -c \"(.+?)\"\n", text)
    assert match is not None, "Dockerfile.ltx must verify the wrapper's entrypoints at build time"
    program = match.group(1).replace(
        "/opt/pod/scripts/launch_ltx.py", str(SCRIPTS / "launch_ltx.py")
    )
    assert "preprocess_script()" in program and "train_script()" in program
    trainer = tmp_path / "packages" / "ltx-trainer"
    (trainer / "scripts").mkdir(parents=True)
    env = {**os.environ, "LTX_TRAINER_DIR": str(trainer)}
    env.pop("LTX_PREPROCESS_SCRIPT", None)
    env.pop("LTX_TRAIN_SCRIPT", None)

    def run() -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", "-c", program], env=env, capture_output=True, text=True
        )

    missing = run()
    assert missing.returncode != 0
    assert "process_dataset.py" in missing.stderr and "train.py" in missing.stderr
    for name in ("process_dataset.py", "train.py"):
        (trainer / "scripts" / name).write_text("", encoding="utf-8")
    present = run()
    assert present.returncode == 0, present.stderr
    assert str(trainer / "scripts" / "train.py") in present.stdout


def test_ltx_extra_preprocess_and_deep_merge(workspace: Path) -> None:
    run = workspace / "runs" / RUN_ID
    extra = {
        "preprocess": {"resolution_buckets": "768x768x49;512x512x49", "args": ["--decode"]},
        "optimization": {"optimizer_type": "adamw", "steps": 100},
        "validation": {"guidance_scale": 3.5, "prompts": ["IVAN9 man, portrait"]},
        "flow_matching": {"timestep_sampling_mode": "shifted_logit_normal"},
    }
    cfg = ltx.validate_run_config(ltx_run_config(workspace, extra=extra), workspace)
    argv = ltx.preprocess_argv(run, cfg)
    assert argv[argv.index("--resolution-buckets") + 1] == "768x768x49;512x512x49"
    assert argv[-1] == "--decode"
    doc = ltx.build_native_config(cfg, run)
    assert "preprocess" not in doc
    assert doc["optimization"]["optimizer_type"] == "adamw"
    assert doc["optimization"]["steps"] == 100
    assert doc["optimization"]["learning_rate"] == 0.0001  # siblings survive
    assert doc["validation"]["guidance_scale"] == 3.5
    assert doc["validation"]["prompts"] == ["IVAN9 man, portrait"]
    assert doc["validation"]["interval"] == 250
    assert doc["flow_matching"] == {"timestep_sampling_mode": "shifted_logit_normal"}


@pytest.mark.parametrize(
    "preprocess",
    [
        "768x768x49",
        {"resolution_buckets": "768x768"},
        {"resolution_buckets": 768},
        {"resolution_buckets": "768x768x49,512x512x49"},  # the trainer splits on ";" only
        {"args": "--decode"},
        {"bucket": "768x768x49"},
    ],
)
def test_ltx_rejects_bad_extra_preprocess(workspace: Path, preprocess: Any) -> None:
    run = workspace / "runs" / RUN_ID
    cfg = ltx.validate_run_config(
        ltx_run_config(workspace, extra={"preprocess": preprocess}), workspace
    )
    with pytest.raises(ltx.ConfigError, match=r"extra\.preprocess"):
        ltx.preprocess_argv(run, cfg)


@pytest.mark.parametrize(
    "args",
    [
        ["--output-dir=/opt/venvs/agent"],
        ["--output-dir", "/opt/venvs/agent"],
        ["--model-path=/etc/passwd"],
        ["--text-encoder-path=/etc/passwd"],
        ["--video-vae-path=/etc/passwd"],
        ["--audio-vae-path=/etc/passwd"],
        ["--device=cuda:1"],
        ["--caption-column=other"],
        ["--video-column=other"],
        ["--resolution-buckets=512x512x1"],
        ["--help"],
        ["--unknown"],
        ["--decode=true"],
        ["--batch-size"],
        ["--batch-size=0"],
        ["--batch-size=65"],
        ["--batch-size=1.5"],
        ["--decode", "--decode"],
        ["--batch-size=1", "--batch-size=2"],
        ["--batch-size=1\n--output-dir=/tmp"],
    ],
)
def test_ltx_preprocess_rejects_before_writing_or_spawning(
    workspace: Path, monkeypatch: pytest.MonkeyPatch, args: list[str]
) -> None:
    def refuse_spawn(*_args: Any, **_kwargs: Any) -> None:
        pytest.fail("invalid preprocess arguments reached a subprocess")

    monkeypatch.setattr(ltx.subprocess, "Popen", refuse_spawn)
    run_json = write_run_json(
        workspace, ltx_run_config(workspace, extra={"preprocess": {"args": args}})
    )
    assert ltx.main(["--config", str(run_json)]) == 2
    assert not (run_json.parent / "dataset.json").exists()
    assert not (run_json.parent / "config.yaml").exists()


def test_ltx_allowlisted_preprocess_options_reach_argv(workspace: Path) -> None:
    args = [
        "--decode",
        "--vae-tiling",
        "--load-text-encoder-in-8bit",
        "--skip-audio",
        "--remove-llm-prefixes",
        "--overwrite",
        "--batch-size=2",
        "--reference-downscale-factor=2",
        "--reference-temporal-scale-factor=2",
    ]
    cfg = ltx.validate_run_config(
        ltx_run_config(workspace, extra={"preprocess": {"args": args}}), workspace
    )
    run = workspace / "runs" / RUN_ID
    argv = ltx.preprocess_argv(run, cfg)
    assert argv[-len(args) :] == args
    assert argv[argv.index("--output-dir") + 1] == str(run / "preprocessed")
    assert argv.count("--output-dir") == 1


def test_ltx_dry_run_fails_without_captioned_media(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    empty = workspace / "datasets" / "empty"
    empty.mkdir()
    (empty / "0001.png").write_bytes(b"\x89PNG")
    run_json = write_run_json(workspace, ltx_run_config(workspace, dataset={"path": str(empty)}))
    assert ltx.main(["--config", str(run_json), "--dry-run"]) == 2
    assert "no captioned media" in capsys.readouterr().out


def test_ltx_warns_on_videos_with_stills_bucket(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    faces = workspace / "datasets" / "faces"
    (faces / "clip.mp4").write_bytes(b"\x00")
    (faces / "clip.txt").write_text("IVAN9 man walks through a doorway", encoding="utf-8")
    run_json = write_run_json(workspace, ltx_run_config(workspace))
    assert ltx.main(["--config", str(run_json), "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert "warning: 1 video item(s)" in out and "1024x1024x1" in out
    entries = json.loads((workspace / "runs" / RUN_ID / "dataset.json").read_text())
    assert str(faces / "clip.mp4") in [e["media_path"] for e in entries]
    extra = {"preprocess": {"resolution_buckets": "768x768x49"}}
    write_run_json(workspace, ltx_run_config(workspace, extra=extra))
    assert ltx.main(["--config", str(run_json), "--dry-run"]) == 0
    assert "warning:" not in capsys.readouterr().out


def test_ltx_disables_validation_without_prompts(workspace: Path) -> None:
    run = workspace / "runs" / RUN_ID
    cfg = ltx.validate_run_config(ltx_run_config(workspace, sample_every=0), workspace)
    assert ltx.build_native_config(cfg, run)["validation"]["interval"] is None


def test_ltx_resumes_from_newest_checkpoint(workspace: Path) -> None:
    run = workspace / "runs" / RUN_ID
    checkpoints = run / "output" / "checkpoints"
    checkpoints.mkdir(parents=True)
    older = checkpoints / "step_000250.safetensors"
    newer = checkpoints / "step_000500.safetensors"
    older.write_bytes(b"a")
    newer.write_bytes(b"b")
    os.utime(older, (1_000_000, 1_000_000))
    os.utime(newer, (2_000_000, 2_000_000))
    cfg = ltx.validate_run_config(ltx_run_config(workspace), workspace)
    assert ltx.build_native_config(cfg, run)["model"]["load_checkpoint"] == str(newer)
    chosen = str(workspace / "models" / "ivan9-ltx.safetensors")
    cfg = ltx.validate_run_config(
        ltx_run_config(workspace, extra={"model": {"load_checkpoint": chosen}}), workspace
    )
    assert ltx.build_native_config(cfg, run)["model"]["load_checkpoint"] == chosen


@pytest.mark.parametrize(
    ("extra", "fragment"),
    [
        ({"output_dir": "/opt/venvs/agent"}, r"output_dir"),
        ({"output_dir": "output"}, r"output_dir"),
        ({"data": {"preprocessed_data_root": "/"}}, r"data\.preprocessed_data_root"),
        ({"data": "preprocessed"}, r"data: must be a mapping"),
        ({"model": {"model_path": "/etc/ltx.safetensors"}}, r"model\.model_path"),
        ({"model": {"model_path": "../../etc"}}, r"model\.model_path"),
        ({"model": {"model_path": "Lightricks/LTX-2"}}, r"model\.model_path.*not Hub ids"),
        ({"model": {"model_path": None}}, r"model\.model_path"),
        ({"model": {"text_encoder_path": "/opt/gemma"}}, r"model\.text_encoder_path"),
        ({"model": {"text_encoder_path": "google/gemma"}}, r"model\.text_encoder_path"),
        ({"model": {"text_encoder_path": None}}, r"model\.text_encoder_path: required"),
        ({"model": {"video_vae_path": "/vae.safetensors"}}, r"model\.video_vae_path"),
        ({"model": {"audio_vae_path": "relative/vae"}}, r"model\.audio_vae_path"),
        ({"model": {"load_checkpoint": "/elsewhere.safetensors"}}, r"model\.load_checkpoint"),
        ({"model": None}, r"model: must be a mapping"),
    ],
)
def test_ltx_extra_cannot_leave_the_workspace(
    workspace: Path, extra: dict[str, Any], fragment: str
) -> None:
    run = workspace / "runs" / RUN_ID
    cfg = ltx.validate_run_config(ltx_run_config(workspace, extra=extra), workspace)
    with pytest.raises(ltx.ConfigError, match=fragment):
        ltx.build_native_config(cfg, run)


def test_ltx_dry_run_refuses_extra_outside_workspace(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    extra = {"output_dir": "/opt/venvs/agent", "data": {"preprocessed_data_root": "/"}}
    run_json = write_run_json(workspace, ltx_run_config(workspace, extra=extra))
    assert ltx.main(["--config", str(run_json), "--dry-run"]) == 2
    out = capsys.readouterr().out
    assert "output_dir" in out and "preprocessed_data_root" in out
    run = workspace / "runs" / RUN_ID
    assert not (run / "config.yaml").exists() and not (run / "dataset.json").exists()


def test_ltx_prepares_supported_hub_model_without_network_on_dry_run(
    workspace: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import huggingface_hub

    def refuse_download(**_kwargs: Any) -> None:
        pytest.fail("dry run downloaded a model")

    monkeypatch.setattr(huggingface_hub, "snapshot_download", refuse_download)
    cfg = ltx_run_config(
        workspace, base_model="Lightricks/LTX-2", extra={"model": {"text_encoder_path": None}}
    )
    cfg["extra"].pop("model")
    run_json = write_run_json(workspace, cfg)
    assert ltx.main(["--config", str(run_json), "--dry-run"]) == 0
    native = load_yaml_if_available(run_json.parent / "config.yaml")
    model_dir = workspace / "models" / "ltx-2"
    assert native["model"]["model_path"] == str(model_dir / "ltx-2-19b-dev.safetensors")
    assert native["model"]["text_encoder_path"] == str(model_dir)
    assert not model_dir.exists()


def test_ltx_hub_download_uses_controlled_destination(
    workspace: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import huggingface_hub

    calls: list[dict[str, Any]] = []
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda **kwargs: calls.append(kwargs))
    cfg = ltx.validate_run_config(
        ltx_run_config(workspace, base_model="Lightricks/LTX-2"), workspace
    )
    ltx.download_hub_model(cfg)
    assert len(calls) == 1
    assert calls[0]["repo_id"] == "Lightricks/LTX-2"
    assert calls[0]["local_dir"] == str(workspace / "models" / "ltx-2")
    assert calls[0]["allow_patterns"] == list(ltx.LTX_HUB_FILES)


def test_ltx_refuses_unknown_hub_source(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    cfg = ltx_run_config(workspace, base_model="other/model")
    run_json = write_run_json(workspace, cfg)
    assert ltx.main(["--config", str(run_json), "--dry-run"]) == 2
    assert "automatic LTX preparation supports Lightricks/LTX-2" in capsys.readouterr().out


def test_ltx_requires_text_encoder_path(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """process_dataset.py needs --text-encoder-path; without extra.model.text_encoder_path the
    wrapper stops at exit 2 with the hint instead of letting the preprocessor fail."""
    cfg = run_config(workspace, base_model=ltx_model(workspace))  # no extra.model at all
    run = workspace / "runs" / RUN_ID
    with pytest.raises(ltx.ConfigError, match=r"model\.text_encoder_path: required"):
        ltx.build_native_config(ltx.validate_run_config(cfg, workspace), run)
    run_json = write_run_json(workspace, cfg)
    assert ltx.main(["--config", str(run_json), "--dry-run"]) == 2
    out = capsys.readouterr().out
    assert "extra.model.text_encoder_path" in out and "Gemma" in out
    assert not (run / "config.yaml").exists()


def test_ltx_extra_model_reaches_preprocess_and_config(workspace: Path) -> None:
    """extra.model replaces the model files for both phases: a split pack names the transformer,
    a packed Gemma and both VAEs, and the preprocessor gets exactly the same four files."""
    run = workspace / "runs" / RUN_ID
    models = workspace / "models"
    split = {
        "model_path": str(models / "ltx-2.5-transformer.safetensors"),
        "text_encoder_path": str(models / "gemma-packed.safetensors"),
        "video_vae_path": str(models / "video-vae.safetensors"),
        "audio_vae_path": str(models / "audio-vae.safetensors"),
    }
    cfg = ltx.validate_run_config(ltx_run_config(workspace, extra={"model": split}), workspace)
    doc = ltx.build_native_config(cfg, run)
    assert doc["model"] == {**split, "training_mode": "lora", "load_checkpoint": None}
    assert "model_source" not in doc["model"]
    argv = ltx.preprocess_argv(run, cfg)
    assert "--model-source" not in argv
    for key, flag in (
        ("model_path", "--model-path"),
        ("text_encoder_path", "--text-encoder-path"),
        ("video_vae_path", "--video-vae-path"),
        ("audio_vae_path", "--audio-vae-path"),
    ):
        assert argv[argv.index(flag) + 1] == split[key]
    assert argv.index("--audio-vae-path") < argv.index("--output-dir")
    # the unified default passes no VAE flags
    cfg = ltx.validate_run_config(ltx_run_config(workspace), workspace)
    argv = ltx.preprocess_argv(run, cfg)
    assert "--video-vae-path" not in argv and "--audio-vae-path" not in argv


def test_ltx_extra_model_null_deletes_key(workspace: Path) -> None:
    """A null under extra.model removes the key (the trainer forbids unknown keys, so a key must
    be deletable, not only overridable); elsewhere null stays a value."""
    run = workspace / "runs" / RUN_ID
    (run / "output").mkdir()
    (run / "output" / "step-250.safetensors").write_bytes(b"x")
    cfg = ltx.validate_run_config(ltx_run_config(workspace), workspace)
    assert ltx.build_native_config(cfg, run)["model"]["load_checkpoint"].endswith(
        "step-250.safetensors"
    )
    extra = {"model": {"load_checkpoint": None}, "validation": {"interval": None}}
    cfg = ltx.validate_run_config(ltx_run_config(workspace, extra=extra), workspace)
    doc = ltx.build_native_config(cfg, run)
    assert "load_checkpoint" not in doc["model"]
    assert doc["model"]["model_path"] == ltx_model(workspace)  # siblings survive
    assert "interval" in doc["validation"] and doc["validation"]["interval"] is None
    # deleting a required model path is still an error, not a silent trainer default
    cfg = ltx.validate_run_config(
        ltx_run_config(workspace, extra={"model": {"model_path": None}}), workspace
    )
    with pytest.raises(ltx.ConfigError, match=r"model\.model_path"):
        ltx.build_native_config(cfg, run)


def test_ltx_model_args_from_block() -> None:
    assert ltx.model_args({"model_path": "/w/m.safetensors", "text_encoder_path": "/w/g"}) == [
        "--model-path",
        "/w/m.safetensors",
        "--text-encoder-path",
        "/w/g",
    ]
    with pytest.raises(ltx.ConfigError, match=r"model\.text_encoder_path: required"):
        ltx.model_args({"model_path": "/w/m.safetensors"})


# --- log scraper --------------------------------------------------------------------------------


def test_find_step(wrapper: ModuleType) -> None:
    find = wrapper.find_step
    assert (
        find("nora7:   5%|▌         | 100/2000 [01:23<26:20,  1.20it/s, lr: 1.0e-04 loss: 3.4e-01]")
        == 100
    )
    assert find("100it [00:10,  9.90it/s]") == 100
    assert find("Step 250/2000 | loss 0.12") == 250
    assert find("step=7 loss=0.5") == 7
    assert find('{"global_step": 42, "loss": 0.1}') == 42
    assert find("Saving at step 500") == 500
    assert find("steps: 2000") is None
    assert find("max_step_saves_to_keep: 4") is None
    assert find("timestep 5") is None
    assert find("step_num 5") is None
    assert find("[01:23<26:20,  1.20it/s]") is None


def test_scraper_on_sample_lines(wrapper: ModuleType) -> None:
    scraper = wrapper.LogScraper()
    # config echo before training: no step known -> nothing
    assert scraper.feed("steps: 2000") == []
    assert scraper.feed("lr: 0.0001") == []
    assert scraper.feed("loss: 0.5") == []
    # ai-toolkit style tqdm postfix
    line = "nora7-h3-001:   5%|▌         | 100/2000 [01:23<26:20,  1.20it/s, lr: 1.0e-04 loss: 3.412e-01]"
    assert scraper.feed(line) == [
        ("scraped/loss", 100, pytest.approx(0.3412)),
        ("scraped/lr", 100, pytest.approx(1e-4)),
    ]
    # a redraw of the same step emits nothing more
    assert scraper.feed(line) == []
    assert scraper.feed(line.replace("100/2000", "101/2000").replace("3.412e-01", "3.300e-01")) == [
        ("scraped/loss", 101, pytest.approx(0.33)),
        ("scraped/lr", 101, pytest.approx(1e-4)),
    ]
    # generic forms
    assert scraper.feed("Step 200 | train/loss=0.25 | learning_rate 5e-5") == [
        ("scraped/loss", 200, pytest.approx(0.25)),
        ("scraped/lr", 200, pytest.approx(5e-5)),
    ]
    assert scraper.feed('{"global_step": 300, "loss": 0.2, "lr": 0.00004}') == [
        ("scraped/loss", 300, pytest.approx(0.2)),
        ("scraped/lr", 300, pytest.approx(4e-5)),
    ]
    # a loss line without a step attaches to the last known step
    assert scraper.feed("val_loss: 0.9  eval_loss=0.8") == []  # not training loss
    assert scraper.feed("Step 400") == []
    assert scraper.feed("loss: 0.15") == [("scraped/loss", 400, pytest.approx(0.15))]
    assert scraper.feed("loss: nan") == []
    assert scraper.feed("lr_scheduler: cosine") == []
    assert scraper.written == 9


def test_open_writer_without_torch(
    wrapper: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setitem(sys.modules, "torch", None)
    assert wrapper.open_writer(tmp_path / "tensorboard") is None
    assert "not importable" in capsys.readouterr().out


# --- tee, exit codes, push ----------------------------------------------------------------------

TRAINER_SCRIPT = r"""
import sys
sys.stdout.write("Loading config...\n")
sys.stdout.write("lr: 0.0001 (config echo, no step yet)\n")
sys.stdout.write("run:   5%|  | 100/2000 [00:01<00:10, lr: 1.0e-04 loss: 3.412e-01]\r")
sys.stdout.write("run:   5%|  | 100/2000 [00:01<00:10, lr: 1.0e-04 loss: 3.412e-01]\r")
sys.stdout.write("run:  10%|  | 200/2000 [00:02<00:10, lr: 1.0e-04 loss: 2.000e-01]\n")
sys.stderr.write("warning on stderr\n")
sys.stdout.write("done without newline")
sys.stdout.flush()
sys.exit(int(sys.argv[1]))
"""

# Prints its first argument and exits with its second. Fake children are files, not `-c`
# strings, so the wrapper's announce line ("trainer command: ...") does not echo their output.
ECHO_SCRIPT = "import sys; print(sys.argv[1]); sys.exit(int(sys.argv[2]))\n"


def fake_script(directory: Path, name: str, source: str) -> Path:
    path = directory / name
    path.write_text(source, encoding="utf-8")
    return path


def echo_command(directory: Path, message: str, exit_code: int) -> list[str]:
    return [
        sys.executable,
        str(fake_script(directory, "fake_echo.py", ECHO_SCRIPT)),
        message,
        str(exit_code),
    ]


def install_fakes(
    wrapper: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    directory: Path,
    *,
    trainer_exit: int,
    push_exit: int = 0,
) -> tuple[FakeWriter, list[list[str]], list[list[str]]]:
    """Replace the trainer, the push and the TensorBoard writer; record what was asked for."""
    writer = FakeWriter()
    trainer_calls: list[list[str]] = []
    push_calls: list[list[str]] = []
    trainer_script = fake_script(directory, "fake_trainer.py", TRAINER_SCRIPT)
    real_push_argv = wrapper.push_lora_argv

    def fake_trainer_argv(run_dir: Path, cfg: dict[str, Any]) -> list[str]:
        argv = [sys.executable, str(trainer_script), str(trainer_exit)]
        trainer_calls.append(argv)
        return argv

    def fake_push_argv(run_dir: Path, cfg: dict[str, Any]) -> list[str]:
        push_calls.append(real_push_argv(run_dir, cfg))
        return echo_command(directory, "pushed", push_exit)

    monkeypatch.setattr(wrapper, "trainer_argv", fake_trainer_argv)
    monkeypatch.setattr(wrapper, "push_lora_argv", fake_push_argv)
    monkeypatch.setattr(wrapper, "open_writer", lambda logdir: writer)
    if wrapper is ltx:
        # preprocessing is the trainer's business; stand it in with an echo
        monkeypatch.setattr(
            wrapper,
            "preprocess_argv",
            lambda run_dir, cfg: echo_command(directory, "preprocessed", 0),
        )
    return writer, trainer_calls, push_calls


def test_exit_code_propagates_and_log_is_scraped(
    wrapper: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    writer, trainer_calls, _ = install_fakes(wrapper, monkeypatch, workspace, trainer_exit=3)
    run_json = write_run_json(
        workspace,
        run_config_for(wrapper, workspace, hub={"repo_id": "you/x", "push_on_finish": True}),
    )
    assert wrapper.main(["--config", str(run_json)]) == 3
    assert len(trainer_calls) == 1
    out = capsys.readouterr().out
    assert "pushed\n" not in out  # a failed run is not pushed
    # every byte of the child's output is in the tee, \r redraws as their own lines
    assert "Loading config...\n" in out
    assert "warning on stderr\n" in out
    assert "done without newline\n" in out
    assert out.count("100/2000") == 2
    assert "\r" not in out
    assert "trainer exited with code 3; scraped 4 scalars" in out
    assert "not pushing" in out
    assert writer.scalars == [
        ("scraped/loss", pytest.approx(0.3412), 100),
        ("scraped/lr", pytest.approx(1e-4), 100),
        ("scraped/loss", pytest.approx(0.2), 200),
        ("scraped/lr", pytest.approx(1e-4), 200),
    ]
    assert writer.closed and writer.flushed >= 1
    run = workspace / "runs" / RUN_ID
    assert (run / "tensorboard").is_dir() and (run / "output").is_dir()


def test_push_on_finish_after_success(
    wrapper: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("POD_AGENT_PYTHON", sys.executable)
    _, _, push_calls = install_fakes(wrapper, monkeypatch, workspace, trainer_exit=0)
    run_json = write_run_json(
        workspace,
        run_config_for(
            wrapper,
            workspace,
            hub={"repo_id": "you/nora7-lora", "private": True, "push_on_finish": True},
        ),
    )
    assert wrapper.main(["--config", str(run_json)]) == 0
    run = workspace / "runs" / RUN_ID
    assert push_calls[-1] == [
        sys.executable,
        str(SCRIPTS / "push_lora.py"),
        "--run-dir",
        str(run),
        "--repo",
        "you/nora7-lora",
        "--private",
    ]
    out = capsys.readouterr().out
    assert "pushed\n" in out and "pushing to you/nora7-lora" in out


def test_public_repo_omits_private_flag(
    wrapper: ModuleType, workspace: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("POD_AGENT_PYTHON", sys.executable)
    cfg = wrapper.validate_run_config(
        run_config_for(wrapper, workspace, hub={"repo_id": "you/open", "private": False}), workspace
    )
    argv = wrapper.push_lora_argv(workspace / "runs" / RUN_ID, cfg)
    assert argv[-2:] == ["--repo", "you/open"] and "--private" not in argv


def test_failed_push_sets_exit_code(
    wrapper: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    install_fakes(wrapper, monkeypatch, workspace, trainer_exit=0, push_exit=5)
    run_json = write_run_json(
        workspace,
        run_config_for(wrapper, workspace, hub={"repo_id": "you/x", "push_on_finish": True}),
    )
    assert wrapper.main(["--config", str(run_json)]) == 5
    assert "push_lora.py exited with 5" in capsys.readouterr().out


def test_no_push_without_push_on_finish(
    wrapper: ModuleType,
    workspace: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _, _, push_calls = install_fakes(wrapper, monkeypatch, workspace, trainer_exit=0)
    run_json = write_run_json(workspace, run_config_for(wrapper, workspace))  # push_on_finish false
    assert wrapper.main(["--config", str(run_json)]) == 0
    assert push_calls == []
    assert "pushed\n" not in capsys.readouterr().out


def test_hf_token_goes_to_env_not_yaml(
    wrapper: ModuleType, workspace: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("HF_TOKEN", raising=False)
    cfg = wrapper.validate_run_config(
        run_config_for(wrapper, workspace, hf_token="hf_secret_value_0000"), workspace
    )
    env = wrapper.child_env(cfg)
    assert env["HF_TOKEN"] == "hf_secret_value_0000" and env["PYTHONUNBUFFERED"] == "1"
    run = workspace / "runs" / RUN_ID
    text = wrapper.dump_yaml(wrapper.build_native_config(cfg, run))
    assert "hf_secret_value_0000" not in text
    cfg = wrapper.validate_run_config(run_config_for(wrapper, workspace), workspace)
    assert "HF_TOKEN" not in wrapper.child_env(cfg)  # inherits the agent's, if any


def test_tee_reports_signal_death(wrapper: ModuleType, tmp_path: Path) -> None:
    out = io.StringIO()
    code = wrapper.tee(
        fake_command("import os, signal; os.kill(os.getpid(), signal.SIGTERM)"),
        cwd=tmp_path,
        env=dict(os.environ),
        out=out,
    )
    assert code == 128 + 15


class FullDiskWriter(FakeWriter):
    """``add_scalar`` fails the way it does when the volume holding the event file is full."""

    def add_scalar(self, tag: str, value: float, step: int) -> None:
        raise OSError(errno.ENOSPC, "No space left on device")


def recording_popen(monkeypatch: pytest.MonkeyPatch) -> list[subprocess.Popen[bytes]]:
    """Every ``Popen`` the wrapper creates, so a test can check what became of the child."""
    created: list[subprocess.Popen[bytes]] = []
    real = subprocess.Popen

    class RecordingPopen(real):  # type: ignore[type-arg,misc]
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            super().__init__(*args, **kwargs)
            created.append(self)

    monkeypatch.setattr(subprocess, "Popen", RecordingPopen)
    return created


# A trainer that reports one step, then keeps "training" far longer than any test should take.
LINGERING_TRAINER = (
    "import sys, time; print('step 1 loss 0.5', flush=True); time.sleep(60); sys.exit(0)"
)
STUBBORN_TRAINER = (
    "import signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
    "print('step 1 loss 0.5', flush=True); time.sleep(60); sys.exit(0)"
)


def test_tee_failure_stops_the_child(
    wrapper: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The finding: when the tee raises, the trainer must not keep running (and its GPUs)."""
    created = recording_popen(monkeypatch)
    with pytest.raises(OSError, match="No space left"):
        wrapper.tee(
            fake_command(LINGERING_TRAINER),
            cwd=tmp_path,
            env=dict(os.environ),
            out=io.StringIO(),
            scraper=wrapper.LogScraper(),
            writer=FullDiskWriter(),
        )
    (child,) = created
    assert child.returncode == -signal.SIGTERM  # terminated, and reaped


def test_tee_failure_kills_a_child_that_ignores_sigterm(
    wrapper: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(wrapper, "CHILD_GRACE_SECONDS", 0.5)
    created = recording_popen(monkeypatch)
    with pytest.raises(OSError, match="No space left"):
        wrapper.tee(
            fake_command(STUBBORN_TRAINER),
            cwd=tmp_path,
            env=dict(os.environ),
            out=io.StringIO(),
            scraper=wrapper.LogScraper(),
            writer=FullDiskWriter(),
        )
    (child,) = created
    assert child.returncode == -signal.SIGKILL


def test_run_trainer_closes_writer_and_propagates_tee_failure(
    wrapper: ModuleType, workspace: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Through ``run_trainer``: the writer is closed and the error reaches the wrapper's exit."""
    writer = FullDiskWriter()
    monkeypatch.setattr(wrapper, "open_writer", lambda logdir: writer)
    created = recording_popen(monkeypatch)
    run = workspace / "runs" / RUN_ID
    cfg = wrapper.validate_run_config(run_config_for(wrapper, workspace), workspace)
    with pytest.raises(OSError):
        wrapper.run_trainer(fake_command(LINGERING_TRAINER), run, cfg, io.StringIO())
    assert writer.closed
    assert created[0].returncode == -signal.SIGTERM


def test_main_rejects_bad_config(
    wrapper: ModuleType, workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    run_json = write_run_json(workspace, run_config_for(wrapper, workspace, triggers=[]))
    assert wrapper.main(["--config", str(run_json), "--dry-run"]) == 2
    assert "triggers" in capsys.readouterr().out
    run_json.write_text("{not json", encoding="utf-8")
    assert wrapper.main(["--config", str(run_json), "--dry-run"]) == 2
    assert wrapper.main(["--config", str(workspace / "nowhere.json"), "--dry-run"]) == 2


def test_ltx_skips_preprocess_when_populated(
    workspace: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    install_fakes(ltx, monkeypatch, workspace, trainer_exit=0)
    run = workspace / "runs" / RUN_ID
    (run / "preprocessed").mkdir()
    (run / "preprocessed" / "latents.pt").write_bytes(b"x")
    run_json = write_run_json(workspace, ltx_run_config(workspace))
    assert ltx.main(["--config", str(run_json)]) == 0
    out = capsys.readouterr().out
    assert "skipping preprocessing" in out and "preprocessed\n" not in out
    assert ltx.main(["--config", str(run_json), "--reprocess"]) == 0
    assert "preprocessed\n" in capsys.readouterr().out


def test_ltx_preprocess_failure_stops_run(
    workspace: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    install_fakes(ltx, monkeypatch, workspace, trainer_exit=0)
    monkeypatch.setattr(
        ltx, "preprocess_argv", lambda run_dir, cfg: echo_command(workspace, "boom", 7)
    )
    run_json = write_run_json(workspace, ltx_run_config(workspace))
    assert ltx.main(["--config", str(run_json)]) == 7
    out = capsys.readouterr().out
    assert "boom\n" in out and "preprocessing exited with code 7" in out
    assert "Loading config..." not in out  # the trainer never started
