"""The service catalog: fixed argv builders over validated params (POD-SPEC §3, §4.1).

Six services, one ``ServiceSpec`` each. Everything a client sends arrives as ``params`` and
passes two checks before anything is built:

1. ``spec.params_model.model_validate(raw)``: shape, patterns and ranges. Pure pydantic; raises
   ``pydantic.ValidationError``.
2. ``validate(params, paths)``: the checks that need the workspace layout (``dataset.path`` under
   ``<workspace>/datasets``, ``logdir`` under ``<workspace>``, local model paths under
   ``<workspace>/models``). Pydantic models never see ``Paths``, so this is a separate step; it
   raises the same ``pydantic.ValidationError`` so the supervisor maps both steps to
   ``invalid_params`` with one ``except``. ``parse_params`` runs both.

Argv builders then place every user value as its own argv element; no shell is involved
anywhere. Secrets (``hf_token``, ``api_key``) travel only through ``env``, never argv, are
stripped from ``run.json`` and the fake-mode argv, and are redacted by ``ServiceParams.public()``.
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Any, Literal, TypeVar

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    ValidationInfo,
    field_validator,
    model_validator,
)
from pydantic_core import InitErrorDetails, PydanticCustomError

from .settings import Paths, Settings

RUN_ID_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
NAME_PATTERN = RUN_ID_PATTERN  # dataset folder names follow the run-id rule
REPO_ID_PATTERN = r"^[\w.-]+/[\w.-]+$"
MODEL_ID_PATTERN = r"^[\w.-]+(/[\w.-]+)?$"  # Hub id: "owner/name" or a bare "name"
EXTRA_ARG_PATTERN = r"^--[a-z0-9-]+(=[^\s]*)?$"  # shape only; the allowlist below decides
COLUMN_PATTERN = r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"
CAPTION_EXT_PATTERN = r"^[A-Za-z0-9]{1,16}$"
SECRET_FIELDS: frozenset[str] = frozenset({"hf_token", "api_key"})
ANY = -1  # upper bound meaning "any number of GPUs >= the lower bound"
RUN_JSON = "run.json"
MIN_RESOLUTION = 64
MAX_RESOLUTION = 8192

Port = Annotated[int, Field(ge=1024, le=65535)]
Secret = Annotated[str | None, Field(min_length=1)]
Column = Annotated[str, Field(pattern=COLUMN_PATTERN)]


# --- vLLM extra_args: an allowlist of flags, each with its own value check -------------------
#
# Client strings reach argv only as validated enums or paths under the workspace, and
# ``extra_args`` is no exception: every item is ``--flag`` or ``--flag=value`` for a flag listed
# in ``VLLM_EXTRA_FLAGS``, and the value has to satisfy that flag's check. Flags that would
# override a validated param (--host, --port, --api-key, --served-model-name, --download-dir,
# --max-model-len, ...), make vLLM read local files (--allowed-local-media-path, --chat-template,
# --tokenizer, --hf-overrides, ...) or execute Hub code (--trust-remote-code) are absent on
# purpose; adding a flag here is a reviewable change, not a regex loophole. Each flag may appear
# at most once.

ExtraArgCheck = Callable[[str, str | None], None]


def _switch(flag: str, value: str | None) -> None:
    if value is not None:
        raise ValueError(f"{flag} takes no value")


def _int_arg(low: int, high: int) -> ExtraArgCheck:
    def check(flag: str, value: str | None) -> None:
        if value is None or not re.fullmatch(r"[0-9]{1,12}", value):
            raise ValueError(f"{flag} needs an integer value")
        if not low <= int(value) <= high:
            raise ValueError(f"{flag} must be between {low} and {high}")

    return check


def _float_arg(low: float, high: float) -> ExtraArgCheck:
    def check(flag: str, value: str | None) -> None:
        if value is None or not re.fullmatch(r"[0-9]{1,12}(\.[0-9]{1,6})?", value):
            raise ValueError(f"{flag} needs a number")
        if not low <= float(value) <= high:
            raise ValueError(f"{flag} must be between {low} and {high}")

    return check


def _choice(*options: str) -> ExtraArgCheck:
    allowed = frozenset(options)

    def check(flag: str, value: str | None) -> None:
        if value not in allowed:
            raise ValueError(f"{flag} must be one of {', '.join(sorted(allowed))}")

    return check


def _shaped(pattern: str, description: str) -> ExtraArgCheck:
    def check(flag: str, value: str | None) -> None:
        if value is None or not re.fullmatch(pattern, value):
            raise ValueError(f"{flag} needs {description}")

    return check


VLLM_EXTRA_FLAGS: dict[str, ExtraArgCheck] = {
    # scheduler / memory
    "--enable-prefix-caching": _switch,
    "--no-enable-prefix-caching": _switch,
    "--enable-chunked-prefill": _switch,
    "--no-enable-chunked-prefill": _switch,
    "--enforce-eager": _switch,
    "--async-scheduling": _switch,
    "--disable-custom-all-reduce": _switch,
    "--max-num-batched-tokens": _int_arg(256, 1_048_576),
    "--max-seq-len-to-capture": _int_arg(256, 1_048_576),
    "--max-parallel-loading-workers": _int_arg(1, 64),
    "--swap-space": _float_arg(0, 128),
    "--cpu-offload-gb": _float_arg(0, 512),
    "--block-size": _choice("8", "16", "32", "64", "128"),
    "--kv-cache-dtype": _choice("auto", "fp8", "fp8_e4m3", "fp8_e5m2"),
    # weights (formats that read the model repo only; no loader that takes a path or code)
    "--quantization": _choice(
        "awq", "awq_marlin", "gptq", "gptq_marlin", "fp8", "bitsandbytes", "compressed-tensors"
    ),
    "--load-format": _choice("auto", "safetensors", "pt", "bitsandbytes"),
    "--config-format": _choice("auto", "hf", "mistral"),
    "--tokenizer-mode": _choice("auto", "slow", "mistral"),
    "--generation-config": _choice("auto", "vllm"),
    "--revision": _shaped(r"(?!.*\.\.)[\w.-]+(/[\w.-]+)*", "a Hub revision"),
    # sampling / multimodal
    "--seed": _int_arg(0, 2**31 - 1),
    "--max-logprobs": _int_arg(0, 100),
    "--limit-mm-per-prompt": _shaped(
        r"[a-z]+=[0-9]{1,4}(,[a-z]+=[0-9]{1,4})*", "modality=count[,modality=count]"
    ),
    "--disable-mm-preprocessor-cache": _switch,
    # logging
    "--disable-log-requests": _switch,
    "--disable-log-stats": _switch,
    "--uvicorn-log-level": _choice("debug", "info", "warning", "error", "critical", "trace"),
}

# Switches ``podagent.fakeservice`` understands (exit 3, ignore SIGTERM, leave an orphan). They
# are accepted only when the agent validates in fake mode (``parse_params(..., fake=True)``, i.e.
# validation context ``{"fake": True}``): no real vLLM ever sees them, and a client of a real
# agent gets the same 422 as for any other unknown flag.
FAKE_EXTRA_FLAGS: frozenset[str] = frozenset({"--fail", "--ignore-sigterm", "--orphan"})


def _extra_arg(value: str, info: ValidationInfo) -> str:
    if not re.fullmatch(EXTRA_ARG_PATTERN, value):
        raise ValueError("must look like --flag or --flag=value")
    flag, has_value, raw = value.partition("=")
    check = VLLM_EXTRA_FLAGS.get(flag)
    if check is None and flag in FAKE_EXTRA_FLAGS and bool((info.context or {}).get("fake")):
        check = _switch
    if check is None:
        raise ValueError(f"{flag} is not an allowed vllm flag")
    check(flag, raw if has_value else None)
    return value


ExtraArg = Annotated[str, AfterValidator(_extra_arg)]


# --- value checks shared by the param models --------------------------------------------------


def _token(value: str, field: str) -> str:
    """A single argv-safe token: non-empty, printable, no spaces, not flag-shaped."""
    if not value or not value.isprintable() or " " in value:
        raise ValueError(f"{field} must be a non-empty string without whitespace")
    if value.startswith("-"):
        raise ValueError(f"{field} must not start with '-'")
    return value


def _text(value: str, field: str) -> str:
    """Free text that lands in argv as one element: non-blank, no NUL, not flag-shaped."""
    if not value.strip() or "\x00" in value:
        raise ValueError(f"{field} must be non-blank text")
    if value.startswith("-"):
        raise ValueError(f"{field} must not start with '-'")
    return value


def _abs_path(value: str, field: str) -> str:
    """An absolute path (the workspace check happens in ``validate``)."""
    if not value or not value.isprintable():
        raise ValueError(f"{field} must be a printable path")
    if not value.startswith("/"):
        raise ValueError(f"{field} must be an absolute path")
    return value


def _model_ref(value: str, field: str) -> str:
    """A Hub id (``owner/name`` or ``name``) or an absolute local path."""
    _token(value, field)
    if value.startswith("/"):
        return value
    if not re.fullmatch(MODEL_ID_PATTERN, value) or any(
        segment in {".", ".."} for segment in value.split("/")
    ):
        raise ValueError(
            f"{field} must be a Hub id ('owner/name') or an absolute path under <workspace>/models"
        )
    return value


# --- param models (POD-SPEC §3.1-3.5, §4.1) -----------------------------------------------------


class ServiceParams(BaseModel):
    """Base for every service's params: unknown keys are rejected."""

    model_config = ConfigDict(extra="forbid")

    def public(self) -> dict[str, Any]:
        """The params as the API echoes them: secrets redacted."""
        data = self.model_dump(mode="json")
        for key in SECRET_FIELDS:
            if data.get(key):
                data[key] = "***"
        return data


class VllmParams(ServiceParams):
    model: str
    port: Port = 8000
    max_model_len: int = Field(default=16384, ge=1024)
    gpu_memory_utilization: float = Field(default=0.9, ge=0.1, le=0.99)
    dtype: Literal["auto", "bfloat16", "float16"] = "auto"
    max_num_seqs: int = Field(default=16, ge=1, le=1024)
    served_model_name: str | None = None
    api_key: Secret = None
    extra_args: list[ExtraArg] = []

    @field_validator("model")
    @classmethod
    def _model(cls, value: str) -> str:
        return _model_ref(value, "model")

    @field_validator("served_model_name")
    @classmethod
    def _served(cls, value: str | None) -> str | None:
        return None if value is None else _token(value, "served_model_name")

    @field_validator("extra_args")
    @classmethod
    def _extra_args_unique(cls, value: list[str]) -> list[str]:
        flags = [item.partition("=")[0] for item in value]
        repeated = sorted({flag for flag in flags if flags.count(flag) > 1})
        if repeated:
            raise ValueError(f"extra_args repeats {', '.join(repeated)}")
        return value


class TensorboardParams(ServiceParams):
    logdir: str | None = None  # default: <workspace>/runs
    port: Port = 6006

    @field_validator("logdir")
    @classmethod
    def _logdir(cls, value: str | None) -> str | None:
        return None if value is None else _abs_path(value, "logdir")


class DatasetRef(BaseModel):
    model_config = ConfigDict(extra="forbid")

    path: str
    caption_ext: str = Field(default="txt", pattern=CAPTION_EXT_PATTERN)

    @field_validator("path")
    @classmethod
    def _path(cls, value: str) -> str:
        return _abs_path(value, "dataset.path")


class HubTarget(BaseModel):
    model_config = ConfigDict(extra="forbid")

    repo_id: str = Field(pattern=REPO_ID_PATTERN)
    private: bool = True
    push_on_finish: bool = False


class RunConfig(ServiceParams):
    """The trainer run config (POD-SPEC §4.1); params of both trainer services."""

    run_id: str = Field(pattern=RUN_ID_PATTERN)
    dataset: DatasetRef
    triggers: list[str] = Field(min_length=1)
    profile: str | None = None
    base_model: str
    steps: int = Field(default=2000, ge=1)
    learning_rate: float = Field(default=1e-4, gt=0, le=1)
    rank: int = Field(default=16, ge=1)
    alpha: int | None = Field(default=None, ge=1)  # None -> rank
    resolution: int | list[int] = [512, 768, 1024]
    batch_size: int = Field(default=1, ge=1)
    gradient_accumulation: int = Field(default=1, ge=1)
    seed: int = Field(default=42, ge=0)
    save_every: int = Field(default=250, ge=1)
    sample_every: int = Field(default=250, ge=0)  # 0 disables samples
    sample_prompts: list[str] = []
    hub: HubTarget | None = None
    hf_token: Secret = None
    extra: dict[str, Any] = {}

    @field_validator("triggers")
    @classmethod
    def _triggers(cls, value: list[str]) -> list[str]:
        cleaned = [trigger.strip() for trigger in value]
        if any(not trigger for trigger in cleaned):
            raise ValueError("triggers must be non-empty strings")
        return cleaned

    @field_validator("profile")
    @classmethod
    def _profile(cls, value: str | None) -> str | None:
        return None if value is None else _token(value, "profile")

    @field_validator("base_model")
    @classmethod
    def _base_model(cls, value: str) -> str:
        return _model_ref(value, "base_model")

    @field_validator("resolution")
    @classmethod
    def _resolution(cls, value: int | list[int]) -> int | list[int]:
        sizes = [value] if isinstance(value, int) else value
        if not sizes:
            raise ValueError("resolution must be an int or a non-empty list of ints")
        if any(size < MIN_RESOLUTION or size > MAX_RESOLUTION for size in sizes):
            raise ValueError(f"resolution must be between {MIN_RESOLUTION} and {MAX_RESOLUTION}")
        return value

    @field_validator("sample_prompts")
    @classmethod
    def _sample_prompts(cls, value: list[str]) -> list[str]:
        if any(not prompt.strip() for prompt in value):
            raise ValueError("sample_prompts must be non-empty strings")
        return value

    @model_validator(mode="after")
    def _alpha_defaults_to_rank(self) -> RunConfig:
        if self.alpha is None:
            self.alpha = self.rank
        return self


class PullDatasetParams(ServiceParams):
    repo_id: str = Field(pattern=REPO_ID_PATTERN)
    name: str | None = Field(default=None, pattern=NAME_PATTERN)  # default: the repo name
    split: str = "train"
    revision: str | None = None
    image_column: Column = "image"
    caption_column: Column = "caption"
    id_column: Column | None = None
    hf_token: Secret = None

    @field_validator("split")
    @classmethod
    def _split(cls, value: str) -> str:
        return _token(value, "split")

    @field_validator("revision")
    @classmethod
    def _revision(cls, value: str | None) -> str | None:
        return None if value is None else _token(value, "revision")

    @model_validator(mode="after")
    def _name_defaults_to_repo_name(self) -> PullDatasetParams:
        if self.name is None:
            candidate = self.repo_id.rsplit("/", 1)[1]
            if not re.fullmatch(NAME_PATTERN, candidate):
                raise ValueError(
                    f"repo name {candidate!r} is not a valid dataset folder name; pass 'name'"
                )
            self.name = candidate
        return self


class PushLoraParams(ServiceParams):
    run_id: str = Field(pattern=RUN_ID_PATTERN)
    repo_id: str = Field(pattern=REPO_ID_PATTERN)
    private: bool = True
    include_samples: bool = True
    all_checkpoints: bool = False
    commit_message: str | None = None
    hf_token: Secret = None

    @field_validator("commit_message")
    @classmethod
    def _commit_message(cls, value: str | None) -> str | None:
        return None if value is None else _text(value, "commit_message")


# --- the second validation step: checks that need the workspace layout --------------------------


def _check_under(
    errors: list[InitErrorDetails],
    loc: tuple[str, ...],
    value: str,
    root: Path,
    *,
    strict: bool,
) -> None:
    """Record an error unless ``value`` resolves under ``root`` (strictly below when ``strict``)."""
    resolved = Path(value).resolve()
    root_resolved = root.resolve()
    inside = resolved.is_relative_to(root_resolved) and (not strict or resolved != root_resolved)
    if not inside:
        errors.append(
            {
                "type": PydanticCustomError(
                    "path_outside_workspace",
                    "{path} must resolve under {root}",
                    {"path": value, "root": str(root)},
                ),
                "loc": loc,
                "input": value,
            }
        )


# Keys the launch wrappers write into the native trainer config from the run directory and the
# dataset. ``extra`` is deep-merged last and could redirect them; the wrappers re-check the
# merged document, and this walk refuses the same values at the API (422) before run.json is
# written. Any value under these names, at any depth of ``extra``, must be an absolute path
# under the workspace (a Hub id is fine for the model keys).
EXTRA_PATH_KEYS: frozenset[str] = frozenset(
    {
        "training_folder",  # ai-toolkit: checkpoints
        "log_dir",  # ai-toolkit: native event files
        "folder_path",  # ai-toolkit: datasets[*]
        "output_dir",  # ltx
        "preprocessed_data_root",  # ltx: data
        "load_checkpoint",  # ltx: model (resume)
    }
)
EXTRA_MODEL_KEYS: frozenset[str] = frozenset({"name_or_path", "model_source"})


def _check_extra_path(
    errors: list[InitErrorDetails], loc: tuple[str | int, ...], value: Any, root: Path
) -> None:
    if isinstance(value, str) and value.startswith("/"):
        _check_under(errors, loc, value, root, strict=False)
        return
    errors.append(
        {
            "type": PydanticCustomError(
                "path_outside_workspace",
                "{path} must be an absolute path under {root}",
                {"path": value, "root": str(root)},
            ),
            "loc": loc,
            "input": value,
        }
    )


def _check_extra_model_ref(
    errors: list[InitErrorDetails], loc: tuple[str | int, ...], value: Any, root: Path
) -> None:
    if isinstance(value, str) and value.startswith("/"):
        _check_under(errors, loc, value, root, strict=False)
        return
    try:
        if not isinstance(value, str):
            raise ValueError("model reference must be a string")
        _model_ref(value, ".".join(str(part) for part in loc))
    except ValueError as error:
        errors.append(
            {
                "type": PydanticCustomError("model_ref", "{reason}", {"reason": str(error)}),
                "loc": loc,
                "input": value,
            }
        )


def _check_extra_paths(
    errors: list[InitErrorDetails], node: Any, loc: tuple[str | int, ...], root: Path
) -> None:
    """Walk ``extra`` and check every path-bearing key it sets (see ``EXTRA_PATH_KEYS``)."""
    if isinstance(node, dict):
        for key, value in node.items():
            here = (*loc, key)
            if key in EXTRA_PATH_KEYS and value is not None:
                _check_extra_path(errors, here, value, root)
            elif key in EXTRA_MODEL_KEYS:
                _check_extra_model_ref(errors, here, value, root)
            _check_extra_paths(errors, value, here, root)
    elif isinstance(node, list):
        for index, item in enumerate(node):
            _check_extra_paths(errors, item, (*loc, index), root)


def validate(params: ServiceParams, paths: Paths) -> None:
    """Path checks against the workspace; raises ``pydantic.ValidationError`` like step 1."""
    errors: list[InitErrorDetails] = []
    if isinstance(params, RunConfig):
        _check_under(errors, ("dataset", "path"), params.dataset.path, paths.datasets, strict=True)
        if params.base_model.startswith("/"):
            _check_under(errors, ("base_model",), params.base_model, paths.models, strict=True)
        _check_extra_paths(errors, params.extra, ("extra",), paths.workspace)
    elif isinstance(params, TensorboardParams):
        if params.logdir is not None:
            _check_under(errors, ("logdir",), params.logdir, paths.workspace, strict=False)
    elif isinstance(params, VllmParams) and params.model.startswith("/"):
        _check_under(errors, ("model",), params.model, paths.models, strict=True)
    if errors:
        raise ValidationError.from_exception_data(type(params).__name__, errors)


def parse_params(
    name: str, raw: Mapping[str, Any], paths: Paths, *, fake: bool = False
) -> ServiceParams:
    """Both validation steps for service ``name``; ``KeyError`` for an unknown name.

    ``fake`` is the agent's fake mode: it only unlocks ``FAKE_EXTRA_FLAGS`` for vllm.
    """
    model = CATALOG[name].params_model
    params = model.model_validate(dict(raw), context={"fake": fake})
    validate(params, paths)
    return params


# --- the spec and its builders ---------------------------------------------------------------


@dataclass(frozen=True)
class ServiceSpec:
    name: str
    params_model: type[ServiceParams]
    gpus: tuple[int, int]  # (min, max); max == ANY means unbounded
    port: int | None
    argv: Callable[[ServiceParams, list[int], Paths], list[str]]
    cwd: Callable[[ServiceParams, Paths], Path]
    log_path: Callable[[ServiceParams, Paths], Path]
    env: Callable[[ServiceParams, Settings], dict[str, str]]
    prepare: Callable[[ServiceParams, Paths], None]
    run_id: Callable[[ServiceParams], str | None]

    def gpu_count_ok(self, count: int) -> bool:
        low, high = self.gpus
        return count >= low and (high == ANY or count <= high)


def fake_argv(name: str, params: ServiceParams) -> list[str]:
    """What the supervisor runs instead of the real argv in fake mode (POD-SPEC §3)."""
    payload = params.model_dump_json(exclude=set(SECRET_FIELDS))
    return [sys.executable, "-m", "podagent.fakeservice", name, payload]


P = TypeVar("P", bound=ServiceParams)


def _as(params: ServiceParams, kind: type[P]) -> P:
    if not isinstance(params, kind):
        raise TypeError(f"expected {kind.__name__}, got {type(params).__name__}")
    return params


def _no_run_id(_: ServiceParams) -> str | None:
    return None


def _params_run_id(params: ServiceParams) -> str | None:
    run_id = getattr(params, "run_id", None)
    return run_id if isinstance(run_id, str) else None


def _noop_prepare(_: ServiceParams, __: Paths) -> None:
    return None


def _logs(name: str) -> Callable[[ServiceParams, Paths], Path]:
    return lambda _params, paths: paths.logs / f"{name}.log"


def _workspace(_: ServiceParams, paths: Paths) -> Path:
    return paths.workspace


def _run_dir(params: ServiceParams, paths: Paths) -> Path:
    run_id = _params_run_id(params)
    if run_id is None:
        raise TypeError(f"{type(params).__name__} carries no run_id")
    return paths.run_dir(run_id)


def _trainer_log(params: ServiceParams, paths: Paths) -> Path:
    return _run_dir(params, paths) / "trainer.log"


def _no_env(_: ServiceParams, __: Settings) -> dict[str, str]:
    return {}


def _hf_env(params: ServiceParams, _: Settings) -> dict[str, str]:
    """``HF_TOKEN`` from the ``hf_token`` param; absent, the child inherits the agent's."""
    token = getattr(params, "hf_token", None)
    return {"HF_TOKEN": token} if token else {}


def _vllm_argv(params: ServiceParams, _gpus: list[int], paths: Paths) -> list[str]:
    p = _as(params, VllmParams)
    argv = [
        paths.venv_bin("vllm", "vllm"),
        "serve",
        p.model,
        "--host",
        "0.0.0.0",
        "--port",
        str(p.port),
        "--max-model-len",
        str(p.max_model_len),
        "--gpu-memory-utilization",
        str(p.gpu_memory_utilization),
        "--dtype",
        p.dtype,
        "--max-num-seqs",
        str(p.max_num_seqs),
        "--download-dir",
        str(paths.hf_cache),
    ]
    if p.served_model_name is not None:
        argv += ["--served-model-name", p.served_model_name]
    return argv + list(p.extra_args)


def _vllm_env(params: ServiceParams, settings: Settings) -> dict[str, str]:
    p = _as(params, VllmParams)
    return {"VLLM_API_KEY": p.api_key or settings.token}


def _tensorboard_argv(params: ServiceParams, _gpus: list[int], paths: Paths) -> list[str]:
    p = _as(params, TensorboardParams)
    return [
        paths.venv_bin("agent", "tensorboard"),
        "--logdir",
        p.logdir if p.logdir is not None else str(paths.runs),
        "--host",
        "0.0.0.0",
        "--port",
        str(p.port),
        "--reload_multifile",
        "true",
        "--reload_interval",
        "15",
    ]


def _trainer_argv(trainer: str) -> Callable[[ServiceParams, list[int], Paths], list[str]]:
    def build(params: ServiceParams, _gpus: list[int], paths: Paths) -> list[str]:
        cfg = _as(params, RunConfig)
        return [
            paths.venv_bin(trainer, "python"),
            str(paths.scripts / f"launch_{trainer}.py"),
            "--config",
            str(paths.run_dir(cfg.run_id) / RUN_JSON),
        ]

    return build


def _trainer_env(params: ServiceParams, settings: Settings) -> dict[str, str]:
    return {"PYTHONUNBUFFERED": "1", **_hf_env(params, settings)}


def _trainer_prepare(params: ServiceParams, paths: Paths) -> None:
    """Create ``<runs>/<id>/`` (with ``tensorboard/``) and write ``run.json``, secrets stripped."""
    cfg = _as(params, RunConfig)
    run_dir = paths.run_dir(cfg.run_id)
    (run_dir / "tensorboard").mkdir(parents=True, exist_ok=True)
    payload = cfg.model_dump(mode="json", exclude=set(SECRET_FIELDS))
    tmp = run_dir / f"{RUN_JSON}.tmp"
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(tmp, run_dir / RUN_JSON)


def _pull_dataset_argv(params: ServiceParams, _gpus: list[int], paths: Paths) -> list[str]:
    p = _as(params, PullDatasetParams)
    if p.name is None:  # the model validator fills it in; guard the type all the same
        raise TypeError("PullDatasetParams.name is unset")
    argv = [
        paths.venv_bin("agent", "python"),
        str(paths.scripts / "pull_dataset.py"),
        "--repo",
        p.repo_id,
        "--to",
        str(paths.datasets / p.name),
        "--split",
        p.split,
        "--image-column",
        p.image_column,
        "--caption-column",
        p.caption_column,
    ]
    if p.revision is not None:
        argv += ["--revision", p.revision]
    if p.id_column is not None:
        argv += ["--id-column", p.id_column]
    return argv


def _push_lora_argv(params: ServiceParams, _gpus: list[int], paths: Paths) -> list[str]:
    p = _as(params, PushLoraParams)
    argv = [
        paths.venv_bin("agent", "python"),
        str(paths.scripts / "push_lora.py"),
        "--run-dir",
        str(paths.run_dir(p.run_id)),
        "--repo",
        p.repo_id,
    ]
    if p.private:
        argv.append("--private")
    if not p.include_samples:
        argv.append("--no-samples")
    if p.all_checkpoints:
        argv.append("--all-checkpoints")
    if p.commit_message is not None:
        argv += ["--commit-message", p.commit_message]
    return argv


CATALOG: dict[str, ServiceSpec] = {
    "vllm": ServiceSpec(
        name="vllm",
        params_model=VllmParams,
        gpus=(1, 1),
        port=8000,
        argv=_vllm_argv,
        cwd=_workspace,
        log_path=_logs("vllm"),
        env=_vllm_env,
        prepare=_noop_prepare,
        run_id=_no_run_id,
    ),
    "tensorboard": ServiceSpec(
        name="tensorboard",
        params_model=TensorboardParams,
        gpus=(0, 0),
        port=6006,
        argv=_tensorboard_argv,
        cwd=_workspace,
        log_path=_logs("tensorboard"),
        env=_no_env,
        prepare=_noop_prepare,
        run_id=_no_run_id,
    ),
    "trainer-aitoolkit": ServiceSpec(
        name="trainer-aitoolkit",
        params_model=RunConfig,
        gpus=(1, ANY),
        port=None,
        argv=_trainer_argv("aitoolkit"),
        cwd=_run_dir,
        log_path=_trainer_log,
        env=_trainer_env,
        prepare=_trainer_prepare,
        run_id=_params_run_id,
    ),
    "trainer-ltx": ServiceSpec(
        name="trainer-ltx",
        params_model=RunConfig,
        gpus=(1, ANY),
        port=None,
        argv=_trainer_argv("ltx"),
        cwd=_run_dir,
        log_path=_trainer_log,
        env=_trainer_env,
        prepare=_trainer_prepare,
        run_id=_params_run_id,
    ),
    "pull-dataset": ServiceSpec(
        name="pull-dataset",
        params_model=PullDatasetParams,
        gpus=(0, 0),
        port=None,
        argv=_pull_dataset_argv,
        cwd=_workspace,
        log_path=_logs("pull-dataset"),
        env=_hf_env,
        prepare=_noop_prepare,
        run_id=_no_run_id,
    ),
    "push-lora": ServiceSpec(
        name="push-lora",
        params_model=PushLoraParams,
        gpus=(0, 0),
        port=None,
        argv=_push_lora_argv,
        cwd=_workspace,
        log_path=_logs("push-lora"),
        env=_hf_env,
        prepare=_noop_prepare,
        run_id=_params_run_id,
    ),
}

SERVICE_NAMES: tuple[str, ...] = tuple(CATALOG)
