"""Catalog unit tests: param validation, argv/env/prepare builders, redaction (POD-SPEC §3, §4.1).

Pure: no subprocess, no network. Fixture triggers are NORA7 / IVAN9.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import pytest
from pydantic import ValidationError

from podagent.catalog import (
    ANY,
    CATALOG,
    FAKE_EXTRA_FLAGS,
    SERVICE_NAMES,
    VLLM_EXTRA_FLAGS,
    LtxRunConfig,
    PullDatasetParams,
    PushLoraParams,
    RunConfig,
    ServiceParams,
    TensorboardParams,
    VllmParams,
    fake_argv,
    parse_params,
    validate,
)
from podagent.settings import Paths, Settings

TOKEN = "agent-token-0123456789abcdef"
HF_SECRET = "hf_secret_token_value_000"


@pytest.fixture
def paths(tmp_path: Path) -> Paths:
    return Paths(workspace=tmp_path / "workspace", prefix=tmp_path / "opt")


@pytest.fixture
def agent_settings(paths: Paths) -> Settings:
    return Settings(token=TOKEN, paths=paths, fake_gpus=2)


def run_config(paths: Paths, **overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "run_id": "nora7-h3-001",
        "dataset": {"path": str(paths.datasets / "faces")},
        "triggers": ["NORA7"],
        "base_model": "black-forest-labs/FLUX.1-dev",
    }
    body.update(overrides)
    return body


def errors_of(exc: pytest.ExceptionInfo[ValidationError]) -> list[tuple[Any, ...]]:
    return [tuple(err["loc"]) for err in exc.value.errors()]


# --- the contract -------------------------------------------------------------------------------


def test_catalog_contract() -> None:
    assert SERVICE_NAMES == (
        "vllm",
        "tensorboard",
        "trainer-aitoolkit",
        "trainer-ltx",
        "pull-dataset",
        "push-lora",
    )
    expected = {
        "vllm": ((1, 1), 8000, VllmParams),
        "tensorboard": ((0, 0), 6006, TensorboardParams),
        "trainer-aitoolkit": ((1, ANY), None, RunConfig),
        "trainer-ltx": ((1, ANY), None, LtxRunConfig),
        "pull-dataset": ((0, 0), None, PullDatasetParams),
        "push-lora": ((0, 0), None, PushLoraParams),
    }
    for name, (gpus, port, model) in expected.items():
        spec = CATALOG[name]
        assert spec.name == name
        assert spec.gpus == gpus
        assert spec.port == port
        assert spec.params_model is model
        assert issubclass(model, ServiceParams)
        assert model.model_config.get("extra") == "forbid"


def test_gpu_count_ok() -> None:
    vllm, tb, trainer = CATALOG["vllm"], CATALOG["tensorboard"], CATALOG["trainer-ltx"]
    assert vllm.gpu_count_ok(1) and not vllm.gpu_count_ok(0) and not vllm.gpu_count_ok(2)
    assert tb.gpu_count_ok(0) and not tb.gpu_count_ok(1)
    assert not trainer.gpu_count_ok(0)
    assert all(trainer.gpu_count_ok(n) for n in (1, 2, 7, 64))


@pytest.mark.parametrize("name", SERVICE_NAMES)
def test_unknown_param_key_is_rejected(name: str) -> None:
    with pytest.raises(ValidationError):
        CATALOG[name].params_model.model_validate({"bogus": 1})


# --- vllm ----------------------------------------------------------------------------------------


def test_vllm_argv_defaults(paths: Paths) -> None:
    spec = CATALOG["vllm"]
    params = VllmParams(model="Qwen/Qwen3-VL-32B-Instruct")
    assert spec.argv(params, [0], paths) == [
        str(paths.prefix / "venvs" / "vllm" / "bin" / "vllm"),
        "serve",
        "Qwen/Qwen3-VL-32B-Instruct",
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
        "--max-model-len",
        "16384",
        "--gpu-memory-utilization",
        "0.9",
        "--dtype",
        "auto",
        "--max-num-seqs",
        "16",
        "--download-dir",
        str(paths.workspace / "models" / "hf-cache"),
    ]
    assert spec.cwd(params, paths) == paths.workspace
    assert spec.log_path(params, paths) == paths.workspace / "logs" / "vllm.log"
    assert spec.run_id(params) is None
    assert spec.prepare(params, paths) is None


def test_vllm_argv_with_options(paths: Paths) -> None:
    params = VllmParams(
        model="Qwen/Qwen3-VL-32B-Instruct",
        port=8001,
        max_model_len=8192,
        gpu_memory_utilization=0.85,
        dtype="bfloat16",
        max_num_seqs=4,
        served_model_name="qwen3-vl",
        extra_args=["--enable-prefix-caching", "--limit-mm-per-prompt=image=4"],
    )
    argv = CATALOG["vllm"].argv(params, [0], paths)
    assert argv[argv.index("--port") + 1] == "8001"
    assert argv[argv.index("--max-model-len") + 1] == "8192"
    assert argv[argv.index("--gpu-memory-utilization") + 1] == "0.85"
    assert argv[argv.index("--dtype") + 1] == "bfloat16"
    assert argv[argv.index("--max-num-seqs") + 1] == "4"
    assert argv[argv.index("--served-model-name") + 1] == "qwen3-vl"
    assert argv[-2:] == ["--enable-prefix-caching", "--limit-mm-per-prompt=image=4"]


def test_vllm_env_api_key_defaults_to_agent_token(agent_settings: Settings) -> None:
    env = CATALOG["vllm"].env
    assert env(VllmParams(model="org/model"), agent_settings) == {"VLLM_API_KEY": TOKEN}
    assert env(VllmParams(model="org/model", api_key="custom-key-1234"), agent_settings) == {
        "VLLM_API_KEY": "custom-key-1234"
    }


def test_vllm_secret_never_in_argv_and_redacted(paths: Paths) -> None:
    params = VllmParams(model="org/model", api_key="custom-key-1234")
    argv = CATALOG["vllm"].argv(params, [0], paths)
    assert "custom-key-1234" not in " ".join(argv)
    public = params.public()
    assert public["api_key"] == "***"
    assert public["model"] == "org/model"
    assert VllmParams(model="org/model").public()["api_key"] is None


@pytest.mark.parametrize(
    "bad",
    [
        {"port": 80},
        {"port": 70000},
        {"port": "eight"},
        {"max_model_len": 512},
        {"gpu_memory_utilization": 1.5},
        {"gpu_memory_utilization": 0.05},
        {"dtype": "fp8"},
        {"max_num_seqs": 0},
        {"max_num_seqs": 4096},
        {"extra_args": ["rm -rf /"]},
        {"extra_args": ["--foo bar"]},
        {"extra_args": ["foo"]},
        {"extra_args": ["--Upper"]},
        {"extra_args": ["-x"]},
        {"extra_args": "--not-a-list"},
        # the finding: flags that reach past the validated params or the workspace
        {"extra_args": ["--download-dir=/opt/venvs/agent"]},
        {"extra_args": ["--allowed-local-media-path=/"]},
        {"extra_args": ["--trust-remote-code"]},
        {"extra_args": ["--api-key=stolen"]},
        {"extra_args": ["--host=0.0.0.0"]},
        {"extra_args": ["--port=9000"]},
        {"extra_args": ["--chat-template=/etc/passwd"]},
        {"extra_args": ["--tokenizer=/workspace/models/x"]},
        {"extra_args": ["--hf-overrides={}"]},
        {"extra_args": ["--max-model-len=99999999"]},
        {"extra_args": ["--enable-prefix-caching", "--download-dir=/tmp"]},
        # allowed flags with values that fail their check
        {"extra_args": ["--enable-prefix-caching=1"]},
        {"extra_args": ["--max-num-batched-tokens"]},
        {"extra_args": ["--max-num-batched-tokens=abc"]},
        {"extra_args": ["--max-num-batched-tokens=-1"]},
        {"extra_args": ["--max-num-batched-tokens=8"]},
        {"extra_args": ["--cpu-offload-gb=1e9"]},
        {"extra_args": ["--quantization=evil"]},
        {"extra_args": ["--quantization"]},
        {"extra_args": ["--revision=../../etc"]},
        {"extra_args": ["--limit-mm-per-prompt=image=4;id"]},
        {"extra_args": ["--limit-mm-per-prompt=/etc/passwd"]},
        # Removed by the pinned vLLM 0.31; reject before a child can fail at argparse.
        {"extra_args": ["--disable-log-requests"]},
        {"extra_args": ["--disable-mm-preprocessor-cache"]},
        {"extra_args": ["--max-seq-len-to-capture=8192"]},
        {"extra_args": ["--swap-space=4"]},
        # fake-mode switches are unknown flags outside fake mode
        {"extra_args": ["--fail"]},
        {"extra_args": ["--ignore-sigterm"]},
        {"extra_args": ["--orphan"]},
        # a flag at most once
        {"extra_args": ["--seed=1", "--seed=2"]},
        {"extra_args": ["--enforce-eager", "--enforce-eager"]},
        {"served_model_name": ""},
        {"served_model_name": "a b"},
        {"served_model_name": "-flag"},
        {"api_key": ""},
    ],
)
def test_vllm_rejects(bad: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        VllmParams.model_validate({"model": "org/model", **bad})


@pytest.mark.parametrize(
    "model", ["", " ", "org/model name", "-serve", "--help", "../etc", "org/..", "./x", "a/b/c"]
)
def test_vllm_rejects_bad_model_refs(model: str) -> None:
    with pytest.raises(ValidationError):
        VllmParams(model=model)


GOOD_EXTRA_ARGS = [
    "--enable-prefix-caching",
    "--no-enable-chunked-prefill",
    "--enforce-eager",
    "--max-num-batched-tokens=8192",
    "--cpu-offload-gb=2.5",
    "--block-size=16",
    "--kv-cache-dtype=fp8",
    "--quantization=fp8",
    "--load-format=safetensors",
    "--tokenizer-mode=auto",
    "--revision=refs/pr/3",
    "--seed=0",
    "--limit-mm-per-prompt=image=4,video=1",
    "--disable-log-stats",
    "--uvicorn-log-level=warning",
]


def test_vllm_accepts_allowlisted_extra_args(paths: Paths) -> None:
    params = VllmParams(model="org/model", extra_args=GOOD_EXTRA_ARGS)
    argv = CATALOG["vllm"].argv(params, [0], paths)
    # Each item lands verbatim as its own argv element, after the fixed prefix.
    assert argv[-len(GOOD_EXTRA_ARGS) :] == GOOD_EXTRA_ARGS


def test_vllm_extra_arg_errors_name_the_item() -> None:
    with pytest.raises(ValidationError) as exc:
        VllmParams(model="org/model", extra_args=["--seed=1", "--download-dir=/tmp"])
    assert errors_of(exc) == [("extra_args", 1)]
    assert "--download-dir is not an allowed vllm flag" in str(exc.value)
    with pytest.raises(ValidationError) as exc:
        VllmParams(model="org/model", extra_args=["--block-size=7"])
    assert "--block-size must be one of" in str(exc.value)


def test_vllm_allowlist_never_overlaps_the_fixed_argv(paths: Paths) -> None:
    """No allowlisted flag can repeat (and so override) a flag the builder already emits."""
    fixed = CATALOG["vllm"].argv(VllmParams(model="org/model", served_model_name="m"), [0], paths)
    emitted = {item for item in fixed if item.startswith("--")}
    assert emitted  # the builder emits --port, --download-dir, ... as separate elements
    assert emitted.isdisjoint(VLLM_EXTRA_FLAGS)
    for flag in ("--api-key", "--trust-remote-code", "--allowed-local-media-path", "--host"):
        assert flag not in VLLM_EXTRA_FLAGS
    assert FAKE_EXTRA_FLAGS.isdisjoint(VLLM_EXTRA_FLAGS)


@pytest.mark.parametrize("switch", sorted(FAKE_EXTRA_FLAGS))
def test_vllm_fake_switches_only_in_fake_mode(paths: Paths, switch: str) -> None:
    raw = {"model": "org/model", "extra_args": [switch]}
    params = parse_params("vllm", raw, paths, fake=True)
    assert isinstance(params, VllmParams) and params.extra_args == [switch]
    with pytest.raises(ValidationError) as exc:
        parse_params("vllm", raw, paths)
    assert errors_of(exc) == [("extra_args", 0)]
    with pytest.raises(ValidationError):  # a value never passes, even in fake mode
        parse_params(
            "vllm", {"model": "org/model", "extra_args": [f"{switch}=1"]}, paths, fake=True
        )
    with pytest.raises(ValidationError):  # fake mode unlocks nothing else
        parse_params("vllm", {"model": "org/model", "extra_args": ["--host=x"]}, paths, fake=True)


@pytest.mark.parametrize("model", ["gpt2", "Qwen/Qwen3-VL-32B-Instruct", "org/model.v1-2_b"])
def test_vllm_accepts_hub_ids(model: str, paths: Paths) -> None:
    validate(VllmParams(model=model), paths)


def test_vllm_local_model_must_live_under_models(paths: Paths) -> None:
    validate(VllmParams(model=str(paths.models / "local-vl")), paths)
    with pytest.raises(ValidationError) as exc:
        validate(VllmParams(model="/elsewhere/model"), paths)
    assert errors_of(exc) == [("model",)]
    assert exc.value.errors()[0]["type"] == "path_outside_workspace"
    with pytest.raises(ValidationError):
        validate(VllmParams(model=str(paths.models / ".." / "runs" / "x")), paths)
    with pytest.raises(ValidationError):  # the models dir itself is not a model
        validate(VllmParams(model=str(paths.models)), paths)


# --- tensorboard ---------------------------------------------------------------------------------


def test_tensorboard_argv_defaults_to_runs(paths: Paths, agent_settings: Settings) -> None:
    spec = CATALOG["tensorboard"]
    params = TensorboardParams()
    assert spec.argv(params, [], paths) == [
        str(paths.prefix / "venvs" / "agent" / "bin" / "tensorboard"),
        "--logdir",
        str(paths.workspace / "runs"),
        "--host",
        "127.0.0.1",
        "--port",
        "6006",
        "--reload_multifile",
        "true",
        "--reload_interval",
        "15",
        "--path_prefix",
        "/tensorboard",
    ]
    assert spec.env(params, agent_settings) == {}
    assert spec.cwd(params, paths) == paths.workspace
    assert spec.log_path(params, paths) == paths.workspace / "logs" / "tensorboard.log"
    assert spec.run_id(params) is None
    validate(params, paths)


def test_tensorboard_custom_logdir(paths: Paths) -> None:
    logdir = str(paths.runs / "nora7-h3-001" / "tensorboard")
    params = TensorboardParams(logdir=logdir)
    validate(params, paths)
    argv = CATALOG["tensorboard"].argv(params, [], paths)
    assert argv[argv.index("--logdir") + 1] == logdir
    assert argv[argv.index("--port") + 1] == "6006"  # the catalog's port, never a param
    validate(TensorboardParams(logdir=str(paths.workspace)), paths)  # the workspace itself is ok


@pytest.mark.parametrize("logdir", ["/elsewhere", "/", "{ws}/../outside", "{ws}/runs/../.."])
def test_tensorboard_logdir_must_be_under_workspace(paths: Paths, logdir: str) -> None:
    params = TensorboardParams(logdir=logdir.format(ws=paths.workspace))
    with pytest.raises(ValidationError) as exc:
        validate(params, paths)
    assert errors_of(exc) == [("logdir",)]


@pytest.mark.parametrize(
    "bad", [{"logdir": "runs"}, {"logdir": ""}, {"port": 6006}, {"port": 7000}]
)
def test_tensorboard_rejects(bad: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        TensorboardParams.model_validate(bad)


# --- trainers ------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("name", "trainer"), [("trainer-aitoolkit", "aitoolkit"), ("trainer-ltx", "ltx")]
)
def test_trainer_argv_cwd_log_run_id(paths: Paths, name: str, trainer: str) -> None:
    spec = CATALOG[name]
    cfg = RunConfig.model_validate(run_config(paths))
    run_dir = paths.workspace / "runs" / "nora7-h3-001"
    assert spec.argv(cfg, [1, 2], paths) == [
        str(paths.prefix / "venvs" / trainer / "bin" / "python"),
        str(paths.prefix / "pod" / "scripts" / f"launch_{trainer}.py"),
        "--config",
        str(run_dir / "run.json"),
    ]
    assert spec.cwd(cfg, paths) == run_dir
    assert spec.log_path(cfg, paths) == run_dir / "trainer.log"
    assert spec.run_id(cfg) == "nora7-h3-001"


@pytest.mark.parametrize("name", ["trainer-aitoolkit", "trainer-ltx"])
def test_trainer_env(paths: Paths, agent_settings: Settings, name: str) -> None:
    env = CATALOG[name].env
    assert env(RunConfig.model_validate(run_config(paths)), agent_settings) == {
        "PYTHONUNBUFFERED": "1"
    }
    with_token = RunConfig.model_validate(run_config(paths, hf_token=HF_SECRET))
    assert env(with_token, agent_settings) == {"PYTHONUNBUFFERED": "1", "HF_TOKEN": HF_SECRET}


@pytest.mark.parametrize("name", ["trainer-aitoolkit", "trainer-ltx"])
def test_trainer_prepare_writes_run_json_without_secrets(paths: Paths, name: str) -> None:
    spec = CATALOG[name]
    cfg = RunConfig.model_validate(
        run_config(
            paths,
            hf_token=HF_SECRET,
            profile="h3-still",
            sample_prompts=["NORA7 woman, studio portrait, soft key light"],
            hub={"repo_id": "you/nora7-h3-lora"},
            extra={"train": {"optimizer": "prodigy"}},
        )
    )
    run_dir = paths.runs / "nora7-h3-001"
    assert not run_dir.exists()
    spec.prepare(cfg, paths)
    assert (run_dir / "tensorboard").is_dir()
    assert not (run_dir / "run.json.tmp").exists()
    written = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    assert "hf_token" not in written
    assert HF_SECRET not in (run_dir / "run.json").read_text(encoding="utf-8")
    assert written["run_id"] == "nora7-h3-001"
    assert written["dataset"] == {"path": str(paths.datasets / "faces"), "caption_ext": "txt"}
    assert written["triggers"] == ["NORA7"]
    assert written["profile"] == "h3-still"
    assert written["base_model"] == "black-forest-labs/FLUX.1-dev"
    assert written["rank"] == 16 and written["alpha"] == 16
    assert written["resolution"] == [512, 768, 1024]
    assert written["hub"] == {
        "repo_id": "you/nora7-h3-lora",
        "private": True,
        "push_on_finish": False,
    }
    assert written["extra"] == {"train": {"optimizer": "prodigy"}}
    assert written["steps"] == 2000 and written["save_every"] == 250 and written["seed"] == 42

    # A second prepare (resume) overwrites run.json and leaves the directory alone.
    (run_dir / "output").mkdir()
    cfg2 = RunConfig.model_validate(run_config(paths, steps=3000))
    spec.prepare(cfg2, paths)
    assert json.loads((run_dir / "run.json").read_text())["steps"] == 3000
    assert (run_dir / "output").is_dir()


def test_run_config_defaults_and_alpha(paths: Paths) -> None:
    cfg = RunConfig.model_validate(run_config(paths))
    assert cfg.alpha == 16 and cfg.rank == 16
    assert cfg.dataset.caption_ext == "txt"
    assert cfg.resolution == [512, 768, 1024]
    assert cfg.learning_rate == pytest.approx(1e-4)
    assert cfg.hub is None and cfg.hf_token is None and cfg.extra == {}
    explicit = RunConfig.model_validate(run_config(paths, rank=32, alpha=8, resolution=768))
    assert explicit.alpha == 8 and explicit.resolution == 768
    assert RunConfig.model_validate(run_config(paths, triggers=[" NORA7 ", "IVAN9"])).triggers == [
        "NORA7",
        "IVAN9",
    ]


def test_run_config_public_redacts_hf_token(paths: Paths) -> None:
    cfg = RunConfig.model_validate(run_config(paths, hf_token=HF_SECRET))
    public = cfg.public()
    assert public["hf_token"] == "***"
    assert HF_SECRET not in json.dumps(public)
    assert RunConfig.model_validate(run_config(paths)).public()["hf_token"] is None


@pytest.mark.parametrize(
    "bad",
    [
        {"run_id": ""},
        {"run_id": "../x"},
        {"run_id": ".hidden"},
        {"run_id": "a/b"},
        {"run_id": "x" * 65},
        {"run_id": "nora 7"},
        {"triggers": []},
        {"triggers": [" "]},
        {"triggers": "NORA7"},
        {"dataset": {"path": "faces"}},
        {"dataset": {"path": ""}},
        {"dataset": {"path": "/workspace/datasets/faces", "caption_ext": "tx.t"}},
        {"dataset": {"path": "/workspace/datasets/faces", "caption_ext": ""}},
        {"dataset": {"path": "/workspace/datasets/faces", "nope": 1}},
        {"base_model": ""},
        {"base_model": "../x"},
        {"base_model": "-x"},
        {"base_model": "a b"},
        {"steps": 0},
        {"learning_rate": 0},
        {"learning_rate": 2},
        {"rank": 0},
        {"alpha": 0},
        {"resolution": []},
        {"resolution": 0},
        {"resolution": [512, 0]},
        {"resolution": "abc"},
        {"resolution": 100000},
        {"batch_size": 0},
        {"gradient_accumulation": 0},
        {"seed": -1},
        {"save_every": 0},
        {"sample_every": -1},
        {"sample_prompts": [""]},
        {"profile": "h3 still"},
        {"hub": {"repo_id": "noslash"}},
        {"hub": {"repo_id": "you/x", "extra": 1}},
        {"hf_token": ""},
        {"extra": []},
        {"unknown": 1},
    ],
)
def test_run_config_rejects(bad: dict[str, Any]) -> None:
    body = {
        "run_id": "nora7-h3-001",
        "dataset": {"path": "/workspace/datasets/faces"},
        "triggers": ["NORA7"],
        "base_model": "black-forest-labs/FLUX.1-dev",
    }
    body.update(bad)
    with pytest.raises(ValidationError):
        RunConfig.model_validate(body)


def test_run_config_dataset_path_must_be_under_datasets(paths: Paths) -> None:
    validate(RunConfig.model_validate(run_config(paths)), paths)
    for bad in (
        "/elsewhere/faces",
        str(paths.runs / "faces"),
        str(paths.datasets),
        str(paths.datasets / ".." / "runs" / "faces"),
        str(paths.datasets / "faces" / ".." / ".." / "runs"),
    ):
        cfg = RunConfig.model_validate(run_config(paths, dataset={"path": bad}))
        with pytest.raises(ValidationError) as exc:
            validate(cfg, paths)
        assert errors_of(exc) == [("dataset", "path")], bad
        assert exc.value.errors()[0]["type"] == "path_outside_workspace"


def test_run_config_local_base_model_must_be_under_models(paths: Paths) -> None:
    validate(
        RunConfig.model_validate(run_config(paths, base_model=str(paths.models / "h3"))), paths
    )
    cfg = RunConfig.model_validate(run_config(paths, base_model="/elsewhere/h3"))
    with pytest.raises(ValidationError) as exc:
        validate(cfg, paths)
    assert errors_of(exc) == [("base_model",)]
    both = RunConfig.model_validate(
        run_config(paths, base_model="/elsewhere/h3", dataset={"path": "/elsewhere/faces"})
    )
    with pytest.raises(ValidationError) as exc:
        validate(both, paths)
    assert errors_of(exc) == [("dataset", "path"), ("base_model",)]


def test_run_config_extra_paths_must_be_under_workspace(paths: Paths) -> None:
    """``extra`` is deep-merged last by the wrappers; path-bearing keys in it are checked here
    too, so the API answers 422 before run.json is written."""
    fine = {
        "training_folder": str(paths.runs / "shared"),
        "log_dir": None,
        "train": {"optimizer": "prodigy"},
        "datasets": [{"folder_path": str(paths.datasets / "other"), "caption_ext": "txt"}],
        "model": {"name_or_path": "vendor/h3-base", "load_checkpoint": str(paths.models / "x")},
        "data": {"preprocessed_data_root": str(paths.runs / "shared" / "pre")},
        "output_dir": str(paths.workspace),  # the workspace itself is inside the workspace
        "config": {"process": [{"training_folder": str(paths.runs / "p")}]},
    }
    validate(RunConfig.model_validate(run_config(paths, extra=fine)), paths)
    cases: list[tuple[dict[str, Any], tuple[str | int, ...]]] = [
        ({"training_folder": "/opt/venvs/agent"}, ("extra", "training_folder")),
        ({"training_folder": "relative/output"}, ("extra", "training_folder")),
        ({"training_folder": 7}, ("extra", "training_folder")),
        ({"log_dir": "/var/log"}, ("extra", "log_dir")),
        ({"datasets": [{"folder_path": "/"}]}, ("extra", "datasets", 0, "folder_path")),
        ({"model": {"name_or_path": "/etc"}}, ("extra", "model", "name_or_path")),
        ({"model": {"name_or_path": "../../etc"}}, ("extra", "model", "name_or_path")),
        ({"model": {"name_or_path": None}}, ("extra", "model", "name_or_path")),
        ({"model": {"model_source": "/elsewhere"}}, ("extra", "model", "model_source")),
        ({"model": {"load_checkpoint": "/elsewhere.st"}}, ("extra", "model", "load_checkpoint")),
        ({"output_dir": str(paths.workspace.parent)}, ("extra", "output_dir")),
        ({"data": {"preprocessed_data_root": "/"}}, ("extra", "data", "preprocessed_data_root")),
        (
            {"config": {"process": [{"training_folder": "/"}]}},
            ("extra", "config", "process", 0, "training_folder"),
        ),
    ]
    for extra, loc in cases:
        cfg = RunConfig.model_validate(run_config(paths, extra=extra))
        with pytest.raises(ValidationError) as exc:
            validate(cfg, paths)
        assert errors_of(exc) == [loc], extra
    # the finding's request, through parse_params, lists both offending keys
    bad = {"training_folder": "/opt/venvs/agent", "datasets": [{"folder_path": "/"}]}
    with pytest.raises(ValidationError) as exc:
        parse_params("trainer-aitoolkit", run_config(paths, extra=bad), paths)
    assert errors_of(exc) == [
        ("extra", "training_folder"),
        ("extra", "datasets", 0, "folder_path"),
    ]


# --- pull-dataset --------------------------------------------------------------------------------


def test_pull_dataset_argv_defaults(paths: Paths, agent_settings: Settings) -> None:
    spec = CATALOG["pull-dataset"]
    params = PullDatasetParams(repo_id="you/nora7-faces")
    assert params.name == "nora7-faces"
    assert spec.argv(params, [], paths) == [
        str(paths.prefix / "venvs" / "agent" / "bin" / "python"),
        str(paths.prefix / "pod" / "scripts" / "pull_dataset.py"),
        "--repo",
        "you/nora7-faces",
        "--to",
        str(paths.workspace / "datasets" / "nora7-faces"),
        "--split",
        "train",
        "--image-column",
        "image",
        "--caption-column",
        "caption",
    ]
    assert spec.env(params, agent_settings) == {}
    assert spec.cwd(params, paths) == paths.workspace
    assert spec.log_path(params, paths) == paths.workspace / "logs" / "pull-dataset.log"
    assert spec.run_id(params) is None
    assert spec.prepare(params, paths) is None
    validate(params, paths)


def test_pull_dataset_argv_with_options(paths: Paths, agent_settings: Settings) -> None:
    params = PullDatasetParams(
        repo_id="you/nora7-faces",
        name="faces-v2",
        split="validation",
        revision="abc123",
        image_column="img",
        caption_column="text",
        id_column="file_name",
        hf_token=HF_SECRET,
    )
    argv = CATALOG["pull-dataset"].argv(params, [], paths)
    assert argv[argv.index("--to") + 1] == str(paths.datasets / "faces-v2")
    assert argv[argv.index("--split") + 1] == "validation"
    assert argv[argv.index("--revision") + 1] == "abc123"
    assert argv[argv.index("--image-column") + 1] == "img"
    assert argv[argv.index("--caption-column") + 1] == "text"
    assert argv[argv.index("--id-column") + 1] == "file_name"
    assert HF_SECRET not in " ".join(argv)
    assert CATALOG["pull-dataset"].env(params, agent_settings) == {"HF_TOKEN": HF_SECRET}
    assert params.public()["hf_token"] == "***"


@pytest.mark.parametrize(
    "bad",
    [
        {"repo_id": "noslash"},
        {"repo_id": "a/b/c"},
        {"repo_id": "a b/c"},
        {"repo_id": "/c"},
        {"repo_id": ""},
        {"repo_id": "you/.."},  # derived folder name would escape datasets/
        {"repo_id": "you/.hidden"},
        {"name": ".."},
        {"name": "../x"},
        {"name": "a/b"},
        {"name": ""},
        {"name": "x" * 65},
        {"split": ""},
        {"split": "train split"},
        {"split": "-x"},
        {"revision": "-x"},
        {"revision": "a b"},
        {"image_column": ""},
        {"image_column": "-x"},
        {"caption_column": "a b"},
        {"id_column": "a;b"},
        {"hf_token": ""},
        {"unknown": 1},
    ],
)
def test_pull_dataset_rejects(bad: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        PullDatasetParams.model_validate({"repo_id": "you/nora7-faces", **bad})


def test_pull_dataset_explicit_name_rescues_odd_repo_name() -> None:
    params = PullDatasetParams(repo_id="you/.odd", name="odd")
    assert params.name == "odd"


# --- push-lora -----------------------------------------------------------------------------------


def test_push_lora_argv_defaults(paths: Paths, agent_settings: Settings) -> None:
    spec = CATALOG["push-lora"]
    params = PushLoraParams(run_id="nora7-h3-001", repo_id="you/nora7-h3-lora")
    assert spec.argv(params, [], paths) == [
        str(paths.prefix / "venvs" / "agent" / "bin" / "python"),
        str(paths.prefix / "pod" / "scripts" / "push_lora.py"),
        "--run-dir",
        str(paths.workspace / "runs" / "nora7-h3-001"),
        "--repo",
        "you/nora7-h3-lora",
        "--private",
    ]
    assert spec.env(params, agent_settings) == {}
    assert spec.cwd(params, paths) == paths.workspace
    assert spec.log_path(params, paths) == paths.workspace / "logs" / "push-lora.log"
    assert spec.run_id(params) == "nora7-h3-001"
    assert spec.prepare(params, paths) is None
    validate(params, paths)


def test_push_lora_argv_with_options(paths: Paths, agent_settings: Settings) -> None:
    params = PushLoraParams(
        run_id="ivan9-ltx-002",
        repo_id="you/ivan9-ltx-lora",
        private=False,
        include_samples=False,
        all_checkpoints=True,
        commit_message="IVAN9 LoRA, step 2000",
        hf_token=HF_SECRET,
    )
    argv = CATALOG["push-lora"].argv(params, [], paths)
    assert "--private" not in argv
    assert "--no-samples" in argv and "--all-checkpoints" in argv
    assert argv[argv.index("--commit-message") + 1] == "IVAN9 LoRA, step 2000"
    assert HF_SECRET not in " ".join(argv)
    assert CATALOG["push-lora"].env(params, agent_settings) == {"HF_TOKEN": HF_SECRET}
    assert params.public()["hf_token"] == "***"


@pytest.mark.parametrize(
    "bad",
    [
        {"run_id": "../x"},
        {"run_id": ""},
        {"repo_id": "noslash"},
        {"private": "maybe"},
        {"commit_message": ""},
        {"commit_message": "   "},
        {"commit_message": "-m"},
        {"commit_message": "nul\x00byte"},
        {"hf_token": ""},
        {"unknown": 1},
    ],
)
def test_push_lora_rejects(bad: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        PushLoraParams.model_validate({"run_id": "nora7-h3-001", "repo_id": "you/x", **bad})


# --- LTX: the trainer-specific rule lives in its params model ---------------------------------


def test_ltx_preprocess_is_checked_by_the_ltx_params_model(paths: Paths) -> None:
    bad = run_config(paths, extra={"preprocess": {"args": ["--output-dir=/tmp"]}, "lora": {}})
    with pytest.raises(ValidationError) as exc:
        LtxRunConfig.model_validate(bad)
    assert [(e["type"], tuple(e["loc"])) for e in exc.value.errors()] == [
        ("preprocess_args", ("extra", "preprocess"))
    ]
    with pytest.raises(ValidationError):
        parse_params("trainer-ltx", bad, paths)
    # The rule is LTX's: ai-toolkit has no preprocess step and keeps a free-form extra.
    assert isinstance(parse_params("trainer-aitoolkit", bad, paths), RunConfig)
    good = {"resolution_buckets": "768x768x49", "args": ["--decode", "--batch-size=2"]}
    cfg = LtxRunConfig.model_validate(run_config(paths, extra={"preprocess": good, "lora": {}}))
    assert cfg.extra == {"preprocess": good, "lora": {}}
    assert LtxRunConfig.model_validate(run_config(paths)).extra == {}
    assert LtxRunConfig.hub_source == (
        "Lightricks/LTX-2",
        "dfcc2108383fe1aaa0584bdf55d368a4bdadd90c",
    )


# --- fake mode, parse_params, argv hygiene -------------------------------------------------------


def test_fake_argv_strips_secrets(paths: Paths) -> None:
    cfg = RunConfig.model_validate(run_config(paths, hf_token=HF_SECRET))
    argv = fake_argv("trainer-ltx", cfg)
    assert argv[:4] == [sys.executable, "-m", "podagent.fakeservice", "trainer-ltx"]
    payload = json.loads(argv[4])
    assert "hf_token" not in payload and payload["run_id"] == "nora7-h3-001"
    vllm = fake_argv("vllm", VllmParams(model="org/model", api_key="custom-key-1234", port=8000))
    assert json.loads(vllm[4]) == {
        "model": "org/model",
        "port": 8000,
        "max_model_len": 16384,
        "gpu_memory_utilization": 0.9,
        "dtype": "auto",
        "max_num_seqs": 16,
        "served_model_name": None,
        "extra_args": [],
    }
    # TensorBoard has no port param; the fake binds the catalog's port like the real one.
    assert json.loads(fake_argv("tensorboard", TensorboardParams())[4]) == {
        "logdir": None,
        "port": 6006,
    }


def test_parse_params_runs_both_steps(paths: Paths) -> None:
    params = parse_params("trainer-aitoolkit", run_config(paths), paths)
    assert isinstance(params, RunConfig)
    with pytest.raises(ValidationError) as exc:  # step 1: shape
        parse_params("trainer-aitoolkit", run_config(paths, steps=0), paths)
    assert ("steps",) in errors_of(exc)
    with pytest.raises(ValidationError) as exc:  # step 2: workspace layout
        parse_params("trainer-aitoolkit", run_config(paths, dataset={"path": "/elsewhere"}), paths)
    assert errors_of(exc) == [("dataset", "path")]
    with pytest.raises(KeyError):
        parse_params("no-such-service", {}, paths)
    assert isinstance(parse_params("vllm", {"model": "org/model"}, paths), VllmParams)
    assert isinstance(parse_params("tensorboard", {}, paths), TensorboardParams)


def test_every_argv_element_is_a_string_and_builders_reject_wrong_params(paths: Paths) -> None:
    samples: dict[str, ServiceParams] = {
        "vllm": VllmParams(model="org/model"),
        "tensorboard": TensorboardParams(),
        "trainer-aitoolkit": RunConfig.model_validate(run_config(paths)),
        "trainer-ltx": LtxRunConfig.model_validate(run_config(paths)),
        "pull-dataset": PullDatasetParams(repo_id="you/faces"),
        "push-lora": PushLoraParams(run_id="nora7-h3-001", repo_id="you/x"),
    }
    for name, params in samples.items():
        argv = CATALOG[name].argv(params, [0], paths)
        assert argv and all(isinstance(item, str) and item for item in argv), name
        assert Path(argv[0]).is_absolute(), name
    with pytest.raises(TypeError):
        CATALOG["vllm"].argv(TensorboardParams(), [0], paths)
    with pytest.raises(TypeError):
        CATALOG["trainer-ltx"].prepare(VllmParams(model="org/model"), paths)
    with pytest.raises(TypeError):
        CATALOG["trainer-ltx"].cwd(VllmParams(model="org/model"), paths)
