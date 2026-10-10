#!/usr/bin/env python3
"""run.json -> LTX-2 preprocess + trainer config -> train, with log tee and loss scraping (POD-SPEC §4.3).

    launch_ltx.py --config /workspace/runs/<id>/run.json [--dry-run] [--reprocess]

1. Validate run.json: an own copy of the RunConfig rules of POD-SPEC §4.1 (no podagent import).
   ``dataset.path`` must be an existing directory under ``<PODAGENT_WORKSPACE>/datasets``.
2. Write ``<run>/dataset.json`` (one ``{"caption", "media_path"}`` per captioned image or video
   in the dataset folder; media without a ``<stem>.<caption_ext>`` sidecar is skipped and
   counted) and ``<run>/config.yaml`` (the LTX-2 trainer config, ``extra`` deep-merged last).
   ``--dry-run`` stops here with exit 0.
3. Preprocess: ``python <LTX>/scripts/process_dataset.py <run>/dataset.json --resolution-buckets
   <max>x<max>x1 ... --model-path <model.model_path> --text-encoder-path
   <model.text_encoder_path> --output-dir <run>/preprocessed``, skipped when ``preprocessed/``
   is already populated unless ``--reprocess``. A nonzero exit ends the run with that code. The
   model arguments are read back from the merged ``model`` block of the config (``model_args``),
   so whatever ``extra.model`` changes, the preprocessor and the trainer load the same files.
4. Train: ``python <LTX>/scripts/train.py <run>/config.yaml`` (VERIFY), output tee'd to stdout
   (the agent points it at ``<run>/trainer.log``; ``\\r`` redraws become lines) and scraped for
   ``loss`` / ``lr`` / ``step`` into ``<run>/tensorboard/`` as ``scraped/loss`` and
   ``scraped/lr`` through ``torch.utils.tensorboard.SummaryWriter`` when importable.
5. On exit 0 with ``hub.push_on_finish``, run the sibling ``push_lora.py`` (agent venv).
6. Exit with the trainer's code; when the trainer succeeded but the push did not, with the
   push's code, so a nonzero exit always means something did not land.

The run directory is the directory holding run.json. ``extra`` merges into the config document
root (``{"optimization": {"optimizer_type": "adamw"}}``); mappings merge recursively, lists and
scalars are replaced. Inside the ``model`` block a ``null`` in ``extra`` removes the key (the
trainer config forbids unknown keys, so a key the wrapper writes and the user does not want
must be deletable). ``extra.preprocess`` is not a trainer key: ``{"resolution_buckets":
"768x768x49", "args": ["--decode"]}`` overrides the preprocessing bucket (needed for video
datasets; the default ``<max>x<max>x1`` is for stills; several buckets separate with ``;``)
and appends raw arguments to the preprocess command.

Model files. LTX-2 loads only local files (no Hub ids, no URLs): ``base_model`` must be the
checkpoint ``.safetensors`` under the workspace (``/workspace/models/...``) and becomes
``model.model_path``; the Gemma text encoder is a second path the RunConfig has no field for,
so it comes from ``extra.model.text_encoder_path`` (a directory for a unified checkpoint, a
packed ``.safetensors`` for a split pack) and is required. ``extra.model.video_vae_path`` /
``audio_vae_path`` are passed to both phases too when set (split packs). ``extra`` cannot take
the trainer out of the workspace: after the merge, ``output_dir``, ``data.preprocessed_data_root``
and every ``model.*_path`` (plus ``model.load_checkpoint`` when set) must resolve under
``PODAGENT_WORKSPACE`` (or the run directory) (``check_native_paths``); otherwise exit 2.

Checked against ``Lightricks/LTX-2`` at the commit ``images/Dockerfile.ltx`` pins
(``packages/ltx-trainer``: ``scripts/process_dataset.py`` options, ``src/ltx_trainer/config.py``
keys): the preprocess flags, the config keys written here and the ``media_path`` column (the
legacy alias of ``video``). What still carries ``# VERIFY`` (POD-SPEC §4.2) has not run on a
pod: where checkpoints land, that a 1-frame bucket trains from stills, the resume semantics.
Resume: when ``<run>/output`` already holds a ``*.safetensors`` checkpoint, the newest one
becomes ``model.load_checkpoint`` (the trainer restores the saved training state unless
``checkpoints.no_resume``; ``extra.model.load_checkpoint`` overrides).

Environment: ``PODAGENT_WORKSPACE`` (default ``/workspace``), ``LTX_TRAINER_DIR`` (default
``/opt/ltx-2``), ``LTX_PREPROCESS_SCRIPT`` / ``LTX_TRAIN_SCRIPT`` (override the two script
paths), ``POD_AGENT_PYTHON`` (interpreter for push_lora.py; default
``/opt/venvs/agent/bin/python``, else this interpreter), ``HF_TOKEN`` (or ``hf_token`` in
run.json, passed to children through the environment only).

Standard library only at import time; PyYAML writes config.yaml when importable, else a small
emitter here does. The block between the ``shared`` markers is byte-identical in
launch_aitoolkit.py (tests assert it): the scripts run under ``python -I``, so sibling imports
are not available.
"""

from __future__ import annotations

import argparse
import codecs
import contextlib
import json
import math
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, TextIO

SCRIPT_NAME = "launch_ltx"

# --- shared: byte-identical in launch_aitoolkit.py and launch_ltx.py --------------------------

RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
REPO_ID_RE = re.compile(r"^[\w.-]+/[\w.-]+$")
MODEL_ID_RE = re.compile(r"^[\w.-]+(?:/[\w.-]+)?$")  # Hub id: "owner/name" or a bare "name"
CAPTION_EXT_RE = re.compile(r"^\.?[A-Za-z0-9]{1,16}$")
DEFAULT_WORKSPACE = "/workspace"
DEFAULT_AGENT_PYTHON = "/opt/venvs/agent/bin/python"
DEFAULT_RESOLUTION = [512, 768, 1024]
CHILD_GRACE_SECONDS = 5.0  # SIGTERM -> this long -> SIGKILL, when the tee itself fails

_TOP_KEYS = frozenset(
    {
        "run_id",
        "dataset",
        "triggers",
        "profile",
        "base_model",
        "steps",
        "learning_rate",
        "rank",
        "alpha",
        "resolution",
        "batch_size",
        "gradient_accumulation",
        "seed",
        "save_every",
        "sample_every",
        "sample_prompts",
        "hub",
        "hf_token",
        "extra",
    }
)
_REQUIRED_KEYS = ("run_id", "dataset", "triggers", "base_model")
_DATASET_KEYS = frozenset({"path", "caption_ext"})
_HUB_KEYS = frozenset({"repo_id", "private", "push_on_finish"})


def say(message: str) -> None:
    """One line from the wrapper itself, on stdout like the trainer's output."""
    print(f"[{SCRIPT_NAME}] {message}", flush=True)


class ConfigError(ValueError):
    """run.json violates the RunConfig rules; the message lists every problem found."""


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, int | float) and not isinstance(value, bool) and math.isfinite(value)


def _validate_dataset(value: Any, workspace: Path | None, errors: list[str]) -> dict[str, str]:
    out = {"path": "", "caption_ext": "txt"}
    if not isinstance(value, dict):
        errors.append("dataset: must be an object with path and caption_ext")
        return out
    unknown = sorted(set(value) - _DATASET_KEYS)
    if unknown:
        errors.append("dataset: unknown keys: " + ", ".join(unknown))
    path = value.get("path")
    if not isinstance(path, str) or not path.strip():
        errors.append("dataset.path: must be a non-empty string")
    else:
        resolved = Path(path).expanduser().resolve()
        if workspace is not None:
            root = (workspace / "datasets").resolve()
            if not resolved.is_relative_to(root):
                errors.append(f"dataset.path: must resolve under {root}")
            elif not resolved.is_dir():
                errors.append(f"dataset.path: {resolved} is not a directory")
        out["path"] = str(resolved)
    ext = value.get("caption_ext", "txt")
    if not isinstance(ext, str) or not CAPTION_EXT_RE.match(ext):
        errors.append("dataset.caption_ext: must be a short alphanumeric extension")
    else:
        out["caption_ext"] = ext.lstrip(".")
    return out


def _validate_hub(value: Any, errors: list[str]) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        errors.append("hub: must be an object or null")
        return None
    unknown = sorted(set(value) - _HUB_KEYS)
    if unknown:
        errors.append("hub: unknown keys: " + ", ".join(unknown))
    repo_id = value.get("repo_id")
    if not isinstance(repo_id, str) or not REPO_ID_RE.match(repo_id):
        errors.append("hub.repo_id: must look like owner/name")
    out: dict[str, Any] = {"repo_id": repo_id, "private": True, "push_on_finish": False}
    for key in ("private", "push_on_finish"):
        flag = value.get(key, out[key])
        if isinstance(flag, bool):
            out[key] = flag
        else:
            errors.append(f"hub.{key}: must be true or false")
    return out


def validate_run_config(raw: Any, workspace: Path | None = None) -> dict[str, Any]:
    """Validate a decoded run.json (POD-SPEC §4.1) and return it with defaults applied.

    ``alpha`` defaults to ``rank``; ``resolution`` is always a list; ``dataset.path`` is resolved
    and, when ``workspace`` is given, must be an existing directory under ``<workspace>/datasets``.
    Unknown keys are rejected, as the agent's pydantic model does. Raises ConfigError listing every
    violation at once.
    """
    if not isinstance(raw, dict):
        raise ConfigError("run config must be a JSON object")
    errors: list[str] = []
    unknown = sorted(set(raw) - _TOP_KEYS)
    if unknown:
        errors.append("unknown keys: " + ", ".join(unknown))
    for key in _REQUIRED_KEYS:
        if key not in raw:
            errors.append(f"{key}: required")

    def get_int(key: str, default: int, minimum: int) -> int:
        value = raw.get(key, default)
        if not _is_int(value) or value < minimum:
            errors.append(f"{key}: must be an integer >= {minimum}")
            return default
        return value

    def get_str_list(key: str, required: bool) -> list[str]:
        value = raw.get(key, [])
        if not isinstance(value, list) or not all(isinstance(v, str) and v.strip() for v in value):
            errors.append(f"{key}: must be a list of non-empty strings")
            return []
        if required and not value:
            errors.append(f"{key}: must not be empty")
        return list(value)

    cfg: dict[str, Any] = {}
    run_id = raw.get("run_id")
    if not isinstance(run_id, str) or not RUN_ID_RE.match(run_id):
        errors.append("run_id: must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
    cfg["run_id"] = run_id
    cfg["dataset"] = _validate_dataset(raw.get("dataset"), workspace, errors)
    cfg["triggers"] = get_str_list("triggers", required=True)
    profile = raw.get("profile")
    if profile is not None and not isinstance(profile, str):
        errors.append("profile: must be a string or null")
    cfg["profile"] = profile
    base_model = raw.get("base_model")
    if not isinstance(base_model, str) or not base_model.strip():
        errors.append("base_model: must be a non-empty string")
    cfg["base_model"] = base_model
    cfg["steps"] = get_int("steps", 2000, 1)
    learning_rate = raw.get("learning_rate", 1e-4)
    if not _is_number(learning_rate) or learning_rate <= 0:
        errors.append("learning_rate: must be a number > 0")
        learning_rate = 1e-4
    cfg["learning_rate"] = float(learning_rate)
    cfg["rank"] = get_int("rank", 16, 1)
    alpha = raw.get("alpha")
    if alpha is None:
        alpha = cfg["rank"]
    elif not _is_int(alpha) or alpha < 1:
        errors.append("alpha: must be an integer >= 1 or null")
        alpha = cfg["rank"]
    cfg["alpha"] = alpha
    resolution = raw.get("resolution", DEFAULT_RESOLUTION)
    if _is_int(resolution):
        resolution = [resolution]
    if (
        not isinstance(resolution, list)
        or not resolution
        or not all(_is_int(r) and r > 0 for r in resolution)
    ):
        errors.append("resolution: must be a positive integer or a non-empty list of them")
        resolution = DEFAULT_RESOLUTION
    cfg["resolution"] = list(resolution)
    cfg["batch_size"] = get_int("batch_size", 1, 1)
    cfg["gradient_accumulation"] = get_int("gradient_accumulation", 1, 1)
    cfg["seed"] = get_int("seed", 42, 0)
    cfg["save_every"] = get_int("save_every", 250, 1)
    cfg["sample_every"] = get_int("sample_every", 250, 0)
    cfg["sample_prompts"] = get_str_list("sample_prompts", required=False)
    cfg["hub"] = _validate_hub(raw.get("hub"), errors)
    token = raw.get("hf_token")
    if token is not None and (not isinstance(token, str) or not token):
        errors.append("hf_token: must be a non-empty string or null")
        token = None
    cfg["hf_token"] = token
    extra = raw.get("extra", {})
    if not isinstance(extra, dict):
        errors.append("extra: must be an object")
        extra = {}
    cfg["extra"] = extra
    if errors:
        raise ConfigError("; ".join(errors))
    return cfg


def workspace_root() -> Path:
    """``PODAGENT_WORKSPACE`` (default ``/workspace``): where every trainer path has to live."""
    return Path(os.environ.get("PODAGENT_WORKSPACE") or DEFAULT_WORKSPACE).expanduser()


def is_under(value: Any, roots: tuple[Path, ...]) -> bool:
    """True when ``value`` is an absolute path string that resolves under one of ``roots``."""
    if not isinstance(value, str) or not value.startswith("/"):
        return False
    resolved = Path(value).resolve()
    return any(resolved.is_relative_to(root.resolve()) for root in roots)


def is_model_ref(value: Any, roots: tuple[Path, ...]) -> bool:
    """A Hub id (``owner/name`` or ``name``) or an absolute path under one of ``roots``."""
    if not isinstance(value, str) or not value:
        return False
    if value.startswith("/"):
        return is_under(value, roots)
    return bool(MODEL_ID_RE.match(value)) and all(
        segment not in {".", ".."} for segment in value.split("/")
    )


def _roots_text(roots: tuple[Path, ...]) -> str:
    return " or ".join(str(root) for root in roots)


def require_path(errors: list[str], label: str, value: Any, roots: tuple[Path, ...]) -> None:
    """Record an error unless ``value`` is an absolute path under one of ``roots``."""
    if not is_under(value, roots):
        errors.append(
            f"{label}: must be an absolute path under {_roots_text(roots)}, got {value!r}"
        )


def require_model_ref(errors: list[str], label: str, value: Any, roots: tuple[Path, ...]) -> None:
    """Record an error unless ``value`` is a Hub id or an absolute path under one of ``roots``."""
    if not is_model_ref(value, roots):
        errors.append(
            f"{label}: must be a Hub id ('owner/name') or an absolute path under "
            f"{_roots_text(roots)}, got {value!r}"
        )


def load_run(config_path: Path) -> tuple[Path, dict[str, Any]]:
    """run.json path -> (run directory, validated config). The run directory holds run.json."""
    config_path = config_path.expanduser().resolve()
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    cfg = validate_run_config(raw, workspace_root())
    run_dir = config_path.parent
    if run_dir.name != cfg["run_id"]:
        say(f"note: run directory {run_dir} is not named after run_id {cfg['run_id']!r}")
    return run_dir, cfg


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """``base`` updated by ``override``: mappings merge recursively, anything else is replaced."""
    merged = dict(base)
    for key, value in override.items():
        current = merged.get(key)
        if isinstance(current, dict) and isinstance(value, dict):
            merged[key] = deep_merge(current, value)
        else:
            merged[key] = value
    return merged


# YAML: PyYAML when importable (the trainer venvs have it), else the emitter below. The emitter
# writes block style only, quotes every string (JSON escaping is a subset of YAML's double-quoted
# escaping) and formats floats so PyYAML reads them back as floats (``1.0e-05``, never ``1e-05``).

_PLAIN_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")
_RESERVED_KEYS = frozenset({"true", "false", "null", "yes", "no", "on", "off", "y", "n", "~"})


def _yaml_float(value: float) -> str:
    if math.isnan(value):
        return ".nan"
    if math.isinf(value):
        return ".inf" if value > 0 else "-.inf"
    text = repr(value)
    if "e" in text or "E" in text:
        mantissa, _, exponent = text.lower().partition("e")
        if "." not in mantissa:
            mantissa += ".0"
        if exponent[0] not in "+-":
            exponent = "+" + exponent
        return f"{mantissa}e{exponent}"
    if "." not in text:
        text += ".0"
    return text


def _yaml_scalar(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _yaml_float(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    raise TypeError(f"cannot write {type(value).__name__} to YAML")


def _yaml_key(key: Any) -> str:
    text = str(key)
    if _PLAIN_KEY_RE.match(text) and text.lower() not in _RESERVED_KEYS:
        return text
    return json.dumps(text, ensure_ascii=False)


def _emit_mapping(node: dict[str, Any], indent: int, lines: list[str]) -> None:
    pad = "  " * indent
    for key, value in node.items():
        label = _yaml_key(key)
        if isinstance(value, dict):
            if value:
                lines.append(f"{pad}{label}:")
                _emit_mapping(value, indent + 1, lines)
            else:
                lines.append(f"{pad}{label}: {{}}")
        elif isinstance(value, list | tuple):
            if value:
                lines.append(f"{pad}{label}:")
                _emit_sequence(list(value), indent + 1, lines)
            else:
                lines.append(f"{pad}{label}: []")
        else:
            lines.append(f"{pad}{label}: {_yaml_scalar(value)}")


def _emit_sequence(node: list[Any], indent: int, lines: list[str]) -> None:
    pad = "  " * indent
    for item in node:
        if isinstance(item, dict | list | tuple):
            if not item:
                lines.append(f"{pad}- {{}}" if isinstance(item, dict) else f"{pad}- []")
                continue
            nested: list[str] = []
            if isinstance(item, dict):
                _emit_mapping(item, indent + 1, nested)
            else:
                _emit_sequence(list(item), indent + 1, nested)
            # the first nested line carries the dash in place of its indentation
            lines.append(f"{pad}- {nested[0][len(pad) + 2 :]}")
            lines.extend(nested[1:])
        else:
            lines.append(f"{pad}- {_yaml_scalar(item)}")


def dump_yaml(data: dict[str, Any]) -> str:
    """Serialise a JSON-shaped mapping as YAML; PyYAML when importable, else the emitter here."""
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        return yaml.safe_dump(
            data, sort_keys=False, default_flow_style=False, allow_unicode=True, width=1_000_000
        )
    lines: list[str] = []
    _emit_mapping(data, 0, lines)
    return "\n".join(lines) + "\n"


def write_yaml(path: Path, data: dict[str, Any], header: str) -> None:
    path.write_text(header + dump_yaml(data), encoding="utf-8")


# Log scraper. A line (or a \r-separated progress-bar redraw) yields scalars only when a step is
# known: from the same line, or from an earlier one. Lines before the first step (config echoes
# such as ``lr: 0.0001``) are ignored. One value per tag per step.

_NUM = r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"
_SEP = r"[\"']?(?:\s*[=:]\s*|\s+)"
_STEP_TQDM_RE = re.compile(r"(?<![\w/.])(\d+)(?:/\d+|it)\s*\[")
_STEP_WORD_RE = re.compile(r"(?<![\w/])(?:global_)?step[\"']?\s*[=:]?\s*(\d+)\b", re.IGNORECASE)
_LOSS_RE = re.compile(r"(?<!\w)loss" + _SEP + "(" + _NUM + ")", re.IGNORECASE)
_LR_RE = re.compile(r"(?<!\w)(?:lr|learning[_ ]rate)" + _SEP + "(" + _NUM + ")", re.IGNORECASE)
_SCRAPED_TAGS = (("scraped/loss", _LOSS_RE), ("scraped/lr", _LR_RE))
_LINE_SPLIT_RE = re.compile(r"\r\n|\r|\n")


def find_step(line: str) -> int | None:
    """The training step a log line reports: tqdm ``N/M [`` / ``Nit [`` first, then ``step N``."""
    match = _STEP_TQDM_RE.search(line) or _STEP_WORD_RE.search(line)
    return int(match.group(1)) if match else None


class LogScraper:
    """Turns trainer output lines into ``(tag, step, value)`` scalars."""

    def __init__(self) -> None:
        self.last_step: int | None = None
        self.written = 0
        self._last_written: dict[str, int] = {}

    def feed(self, line: str) -> list[tuple[str, int, float]]:
        step = find_step(line)
        if step is not None:
            self.last_step = step
        if self.last_step is None:
            return []
        found: list[tuple[str, int, float]] = []
        for tag, pattern in _SCRAPED_TAGS:
            match = pattern.search(line)
            if match is None or self._last_written.get(tag) == self.last_step:
                continue
            try:
                value = float(match.group(1))
            except ValueError:
                continue
            self._last_written[tag] = self.last_step
            found.append((tag, self.last_step, value))
        self.written += len(found)
        return found


def open_writer(logdir: Path) -> Any | None:
    """A ``torch.utils.tensorboard.SummaryWriter`` on ``logdir``, or None when not importable."""
    try:
        from torch.utils.tensorboard import SummaryWriter
    except Exception as exc:  # ImportError, or torch present without tensorboard
        say(f"log scraper: torch.utils.tensorboard not importable ({exc}); scalars not written")
        return None
    logdir.mkdir(parents=True, exist_ok=True)
    return SummaryWriter(log_dir=str(logdir), filename_suffix=".scraped")


def _forward_sigterm(proc: subprocess.Popen[bytes]) -> Any:
    """Make SIGTERM to the wrapper terminate the child too; returns the previous handler."""
    if threading.current_thread() is not threading.main_thread():
        return None

    def handler(_signum: int, _frame: Any) -> None:
        with contextlib.suppress(ProcessLookupError):
            proc.terminate()

    return signal.signal(signal.SIGTERM, handler)


def _stop_child(proc: subprocess.Popen[bytes]) -> None:
    """End ``proc`` if it still runs: SIGTERM, ``CHILD_GRACE_SECONDS`` of patience, then SIGKILL."""
    if proc.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        proc.terminate()
    try:
        proc.wait(timeout=CHILD_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            proc.kill()


def tee(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    out: TextIO,
    scraper: LogScraper | None = None,
    writer: Any | None = None,
) -> int:
    """Run ``argv``, copy its stdout+stderr to ``out`` line by line, scrape, return its exit code.

    ``\\r\\n``, ``\\r`` and ``\\n`` all end a line in the copy. A child killed by signal N
    returns 128+N. When the tee itself fails (``out`` or the event writer raising, say ENOSPC
    on the volume, or an interrupt) the child is stopped before the exception propagates:
    the supervisor files the wrapper's exit as the run's end and frees its GPUs, so a trainer
    must never outlive the wrapper. The child is always reaped.
    """
    proc = subprocess.Popen(
        argv,
        cwd=str(cwd),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert proc.stdout is not None
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    pending = ""

    def emit(segment: str) -> bool:
        out.write(segment + "\n")
        if scraper is None:
            return False
        scalars = scraper.feed(segment)
        if writer is not None:
            for tag, step, value in scalars:
                writer.add_scalar(tag, value, step)
        return bool(scalars)

    previous = _forward_sigterm(proc)
    try:
        fd = proc.stdout.fileno()
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            pending += decoder.decode(chunk)
            parts = _LINE_SPLIT_RE.split(pending)
            pending = parts.pop()
            added = False
            for segment in parts:
                added = emit(segment) or added
            out.flush()
            if added and writer is not None:
                writer.flush()
        pending += decoder.decode(b"", final=True)
        if pending:
            emit(pending)
        out.flush()
        if writer is not None:
            writer.flush()
    except BaseException:
        _stop_child(proc)
        raise
    finally:
        if previous is not None:
            signal.signal(signal.SIGTERM, previous)
        proc.stdout.close()
        code = proc.wait()
    return 128 - code if code < 0 else code


def child_env(cfg: dict[str, Any]) -> dict[str, str]:
    """The agent's environment plus PYTHONUNBUFFERED and, from run.json, HF_TOKEN. Never argv."""
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"
    if cfg.get("hf_token"):
        env["HF_TOKEN"] = cfg["hf_token"]
    return env


def agent_python() -> str:
    """Interpreter for push_lora.py: POD_AGENT_PYTHON, else the agent venv, else this one."""
    candidate = os.environ.get("POD_AGENT_PYTHON") or DEFAULT_AGENT_PYTHON
    return candidate if Path(candidate).exists() else sys.executable


def push_lora_argv(run_dir: Path, cfg: dict[str, Any]) -> list[str]:
    """``push_lora.py --run-dir <run> --repo <id> [--private]`` (POD-SPEC §7.2), sibling script."""
    hub = cfg["hub"]
    script = Path(__file__).resolve().with_name("push_lora.py")
    argv = [agent_python(), str(script), "--run-dir", str(run_dir), "--repo", hub["repo_id"]]
    if hub["private"]:
        argv.append("--private")
    return argv


def run_trainer(cmd: list[str], run_dir: Path, cfg: dict[str, Any], out: TextIO) -> int:
    """Spawn the trainer with tee + scraper into ``<run>/tensorboard``; return its exit code."""
    (run_dir / "output").mkdir(exist_ok=True)
    logdir = run_dir / "tensorboard"
    logdir.mkdir(exist_ok=True)
    scraper = LogScraper()
    writer = open_writer(logdir)
    try:
        code = tee(cmd, cwd=run_dir, env=child_env(cfg), out=out, scraper=scraper, writer=writer)
    finally:
        if writer is not None:
            writer.close()
    say(f"trainer exited with code {code}; scraped {scraper.written} scalars")
    return code


def finish(run_dir: Path, cfg: dict[str, Any], code: int, out: TextIO) -> int:
    """After the trainer: push when asked and the run succeeded; pick the exit code."""
    hub = cfg["hub"]
    if hub is None or not hub["push_on_finish"]:
        return code
    if code != 0:
        say(f"not pushing to {hub['repo_id']}: trainer exited with {code}")
        return code
    cmd = push_lora_argv(run_dir, cfg)
    say(f"pushing to {hub['repo_id']}: {shlex.join(cmd)}")
    push_code = tee(cmd, cwd=run_dir, env=child_env(cfg), out=out)
    if push_code != 0:
        say(f"push_lora.py exited with {push_code}")
    return push_code


# --- end shared ----------------------------------------------------------------------------------

LTX_DIR_ENV = "LTX_TRAINER_DIR"
DEFAULT_LTX_DIR = "/opt/ltx-2"
LTX_PREPROCESS_ENV = "LTX_PREPROCESS_SCRIPT"
LTX_TRAIN_ENV = "LTX_TRAIN_SCRIPT"
MEDIA_SUFFIXES = frozenset(
    {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff", ".mp4", ".mov", ".webm", ".mkv"}
)
VIDEO_SUFFIXES = frozenset({".mp4", ".mov", ".webm", ".mkv"})
PREPROCESS_KEY = "preprocess"  # the one `extra` key that is not a trainer config key
# Buckets are WxHxF, several separated by ";" (process_dataset.py splits on ";", not ",").
BUCKET_RE = re.compile(r"\d+x\d+x\d+(?:;\d+x\d+x\d+)*")
# model.<key> -> process_dataset.py flag. The preprocessor loads the same files as the trainer
# (text embeddings and latents), so both phases read them from the merged `model` block.
MODEL_PATH_FLAGS = (
    ("model_path", "--model-path", True),
    ("text_encoder_path", "--text-encoder-path", True),
    ("video_vae_path", "--video-vae-path", False),
    ("audio_vae_path", "--audio-vae-path", False),
)
TEXT_ENCODER_HINT = (
    "LTX-2 needs the Gemma text encoder as a second path (a directory for a unified checkpoint, "
    "a packed .safetensors for a split pack); set extra.model.text_encoder_path"
)

YAML_HEADER = (
    "# LTX-2 trainer config written by launch_ltx.py from run.json (POD-SPEC §4.3).\n"
    '# Regenerated at every start; put overrides in run.json "extra", not here.\n'
    "# Keys follow packages/ltx-trainer/src/ltx_trainer/config.py at the pinned LTX-2 commit;\n"
    "# what launch_ltx.py still marks VERIFY has not been exercised on a pod.\n"
)


def ltx_root() -> Path:
    return Path(os.environ.get(LTX_DIR_ENV) or DEFAULT_LTX_DIR)


def preprocess_script() -> Path:
    override = os.environ.get(LTX_PREPROCESS_ENV)
    # VERIFY: location and name of the preprocessing entrypoint in Lightricks/LTX-2
    return Path(override) if override else ltx_root() / "scripts" / "process_dataset.py"


def train_script() -> Path:
    override = os.environ.get(LTX_TRAIN_ENV)
    # VERIFY: location and name of the training entrypoint in Lightricks/LTX-2
    return Path(override) if override else ltx_root() / "scripts" / "train.py"


def build_dataset_entries(dataset_dir: Path, caption_ext: str) -> tuple[list[dict[str, str]], int]:
    """``(entries, skipped)``: one entry per media file with a non-empty caption sidecar."""
    entries: list[dict[str, str]] = []
    skipped = 0
    for media in sorted(p for p in dataset_dir.rglob("*") if p.is_file()):
        if media.suffix.lower() not in MEDIA_SUFFIXES:
            continue
        sidecar = media.with_suffix("." + caption_ext)
        caption = sidecar.read_text(encoding="utf-8").strip() if sidecar.is_file() else ""
        if not caption:
            skipped += 1
            continue
        # `caption` is the preprocessor's caption column; `media_path` its legacy alias of the
        # `video` column (stills go through the same column with a 1-frame bucket; VERIFY on a pod)
        entries.append({"caption": caption, "media_path": str(media)})
    return entries, skipped


def preprocess_options(cfg: dict[str, Any]) -> tuple[str, list[str]]:
    """``(resolution bucket, extra preprocess args)`` from the config and ``extra.preprocess``."""
    size = max(cfg["resolution"])
    bucket = f"{size}x{size}x1"  # WxHxF; F=1 for still images (W, H multiples of 32; F % 8 == 1)
    args: list[str] = []
    options = cfg["extra"].get(PREPROCESS_KEY)
    if options is None:
        return bucket, args
    if not isinstance(options, dict):
        raise ConfigError("extra.preprocess: must be an object")
    override = options.get("resolution_buckets")
    if override is not None:
        if not isinstance(override, str) or not BUCKET_RE.fullmatch(override):
            raise ConfigError("extra.preprocess.resolution_buckets: must look like WxHxF[;WxHxF]")
        bucket = override
    raw_args = options.get("args", [])
    if not isinstance(raw_args, list) or not all(isinstance(a, str) for a in raw_args):
        raise ConfigError("extra.preprocess.args: must be a list of strings")
    args = list(raw_args)
    unknown = sorted(set(options) - {"resolution_buckets", "args"})
    if unknown:
        raise ConfigError("extra.preprocess: unknown keys: " + ", ".join(unknown))
    return bucket, args


def explicit_bucket(cfg: dict[str, Any]) -> bool:
    options = cfg["extra"].get(PREPROCESS_KEY)
    return isinstance(options, dict) and options.get("resolution_buckets") is not None


def model_args(model: dict[str, Any]) -> list[str]:
    """The ``--model-path``/``--text-encoder-path`` (and VAE) flags for a checked ``model`` block.

    Read from the merged config document, never from ``base_model`` directly, so an
    ``extra.model`` override reaches the preprocessor as well as the trainer.
    """
    args: list[str] = []
    for key, flag, required in MODEL_PATH_FLAGS:
        value = model.get(key)
        if value is None:
            if required:
                raise ConfigError(f"model.{key}: required")
            continue
        args += [flag, str(value)]
    return args


def preprocess_argv(run_dir: Path, cfg: dict[str, Any]) -> list[str]:
    """``process_dataset.py <run>/dataset.json ...`` in this (the ltx) venv.

    The model flags come from the merged, checked ``model`` block (``build_native_config``).
    """
    bucket, extra_args = preprocess_options(cfg)
    model = build_native_config(cfg, run_dir)["model"]
    return [
        sys.executable,
        str(preprocess_script()),
        str(run_dir / "dataset.json"),
        "--resolution-buckets",
        bucket,
        "--caption-column",
        "caption",
        "--video-column",  # stills go through the same column (1-frame bucket; VERIFY on a pod)
        "media_path",
        *model_args(model),
        "--output-dir",
        str(run_dir / "preprocessed"),
        *extra_args,
    ]


def find_latest_checkpoint(output_dir: Path) -> Path | None:
    """The newest ``*.safetensors`` under ``output_dir`` by mtime, or None."""
    if not output_dir.is_dir():
        return None
    found = [p for p in output_dir.rglob("*.safetensors") if p.is_file()]
    if not found:
        return None
    return max(found, key=lambda p: (p.stat().st_mtime_ns, str(p)))


def build_native_config(cfg: dict[str, Any], run_dir: Path) -> dict[str, Any]:
    """The LTX-2 trainer config for a validated run config: the mapping of POD-SPEC §4.3."""
    size = max(cfg["resolution"])
    sampling = cfg["sample_every"] > 0 and bool(cfg["sample_prompts"])
    resume = find_latest_checkpoint(run_dir / "output")
    document: dict[str, Any] = {
        "model": {
            # the checkpoint .safetensors (unified, or the transformer of a split pack); the
            # trainer accepts local files only, so check_native_paths refuses a Hub id
            "model_path": cfg["base_model"],
            # Gemma: a directory (unified) or packed .safetensors (split); no RunConfig field,
            # so extra.model.text_encoder_path has to supply it (required, checked below)
            "text_encoder_path": None,
            "training_mode": "lora",
            # a checkpoint file; the saved training state is restored unless
            # checkpoints.no_resume (VERIFY on a pod that the step counter continues)
            "load_checkpoint": str(resume) if resume else None,
        },
        "lora": {"rank": cfg["rank"], "alpha": cfg["alpha"]},
        "optimization": {
            "learning_rate": cfg["learning_rate"],
            "steps": cfg["steps"],
            "batch_size": cfg["batch_size"],
            "gradient_accumulation_steps": cfg["gradient_accumulation"],
            "enable_gradient_checkpointing": True,
        },
        "acceleration": {"mixed_precision_mode": "bf16"},
        "data": {"preprocessed_data_root": str(run_dir / "preprocessed")},
        "validation": {
            # `prompts` is the deprecated spelling the trainer still converts to `samples`
            "prompts": list(cfg["sample_prompts"]),
            "interval": cfg["sample_every"] if sampling else None,  # null disables validation
            "seed": cfg["seed"],
            "video_dims": [size, size, 1],  # [W, H, F]: W, H % 32 == 0; F % 8 == 1 (VERIFY F=1)
        },
        "checkpoints": {"interval": cfg["save_every"], "keep_last_n": 4},
        "seed": cfg["seed"],
        "output_dir": str(run_dir / "output"),  # VERIFY: where checkpoints and samples land;
        # VERIFY: whether the trainer logs to TensorBoard natively (and where); the scraper covers
        # <run>/tensorboard either way
    }
    extra = {k: v for k, v in cfg["extra"].items() if k != PREPROCESS_KEY}
    document = deep_merge(document, extra)
    prune_model_nulls(document, extra)
    check_native_paths(document, run_dir)
    return document


def prune_model_nulls(document: dict[str, Any], extra: dict[str, Any]) -> None:
    """A ``null`` under ``extra.model`` deletes that key from the merged ``model`` block.

    The trainer config forbids unknown keys, so a key the wrapper writes and a user does not
    want (say ``load_checkpoint``) must be removable, not just overridable. Only the ``model``
    block: elsewhere ``null`` is a value (``validation.interval: null`` disables validation).
    """
    overrides = extra.get("model")
    model = document.get("model")
    if not isinstance(overrides, dict) or not isinstance(model, dict):
        return
    for key, value in overrides.items():
        if value is None:
            model.pop(key, None)


def check_native_paths(document: dict[str, Any], run_dir: Path) -> None:
    """Every path the merged document hands the LTX-2 trainer must stay inside the workspace.

    ``extra`` merges last and may name anything, so the check runs on the final document:
    ``output_dir`` and ``data.preprocessed_data_root`` (written to), ``model.model_path`` and
    ``model.text_encoder_path`` (required: the trainer loads local files only, never a Hub id),
    ``model.video_vae_path`` / ``audio_vae_path`` and ``model.load_checkpoint`` (when set).
    Allowed roots: ``PODAGENT_WORKSPACE`` and the run directory. Raises ConfigError listing
    every violation.
    """
    roots = (workspace_root(), run_dir)
    errors: list[str] = []
    require_path(errors, "output_dir", document.get("output_dir"), roots)
    data = document.get("data")
    if not isinstance(data, dict):
        errors.append("data: must be a mapping")
    else:
        require_path(
            errors, "data.preprocessed_data_root", data.get("preprocessed_data_root"), roots
        )
    model = document.get("model")
    if not isinstance(model, dict):
        errors.append("model: must be a mapping")
    else:
        for key, _flag, required in MODEL_PATH_FLAGS:
            value = model.get(key)
            if value is None and not required:
                continue
            if key == "text_encoder_path" and value is None:
                errors.append(f"model.text_encoder_path: required; {TEXT_ENCODER_HINT}")
                continue
            if key == "model_path" and not is_under(value, roots):
                errors.append(
                    "model.model_path (base_model): LTX-2 loads local checkpoint files only, "
                    f"not Hub ids; must be an absolute path under {_roots_text(roots)}, "
                    f"got {value!r}"
                )
                continue
            require_path(errors, f"model.{key}", value, roots)
        if model.get("load_checkpoint") is not None:
            require_path(errors, "model.load_checkpoint", model.get("load_checkpoint"), roots)
    if errors:
        raise ConfigError("; ".join(errors))


def trainer_argv(run_dir: Path, cfg: dict[str, Any]) -> list[str]:
    """``python <LTX>/scripts/train.py <run>/config.yaml`` in this (the ltx) venv."""
    del cfg  # the command does not depend on the config; tests replace this function
    return [sys.executable, str(train_script()), str(run_dir / "config.yaml")]  # VERIFY: CLI


def needs_preprocess(run_dir: Path, *, force: bool) -> bool:
    preprocessed = run_dir / "preprocessed"
    return force or not preprocessed.is_dir() or not any(preprocessed.iterdir())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--config", required=True, help="path to run.json (its directory is the run)"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="write dataset.json and config.yaml, then exit"
    )
    parser.add_argument(
        "--reprocess", action="store_true", help="run preprocessing even if preprocessed/ exists"
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        run_dir, cfg = load_run(Path(args.config))
        entries, skipped = build_dataset_entries(
            Path(cfg["dataset"]["path"]), cfg["dataset"]["caption_ext"]
        )
        if not entries:
            raise ConfigError(f"no captioned media in {cfg['dataset']['path']}")
        native = build_native_config(cfg, run_dir)
        pre_cmd = preprocess_argv(run_dir, cfg)
    except (OSError, ValueError) as exc:
        say(f"invalid run config {args.config}: {exc}")
        return 2
    dataset_json = run_dir / "dataset.json"
    dataset_json.write_text(
        json.dumps(entries, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    say(f"wrote {dataset_json}: {len(entries)} items, {skipped} without a caption skipped")
    videos = sum(Path(e["media_path"]).suffix.lower() in VIDEO_SUFFIXES for e in entries)
    if videos and not explicit_bucket(cfg):
        say(
            f"warning: {videos} video item(s) but the resolution bucket is the stills default "
            f"({preprocess_options(cfg)[0]}); set extra.preprocess.resolution_buckets to WxHxF"
        )
    config_yaml = run_dir / "config.yaml"
    write_yaml(config_yaml, native, YAML_HEADER)
    say(f"wrote {config_yaml}")
    cmd = trainer_argv(run_dir, cfg)
    say(f"preprocess command: {shlex.join(pre_cmd)}")
    say(f"trainer command: {shlex.join(cmd)}")
    if cfg["hub"] is not None and cfg["hub"]["push_on_finish"]:
        say(f"push on finish: {shlex.join(push_lora_argv(run_dir, cfg))}")
    if args.dry_run:
        say("dry run: nothing started")
        return 0
    if needs_preprocess(run_dir, force=args.reprocess):
        (run_dir / "preprocessed").mkdir(exist_ok=True)
        code = tee(pre_cmd, cwd=run_dir, env=child_env(cfg), out=sys.stdout)
        if code != 0:
            say(f"preprocessing exited with code {code}; trainer not started")
            return code
    else:
        say("preprocessed/ already populated; skipping preprocessing (--reprocess to redo)")
    code = run_trainer(cmd, run_dir, cfg, sys.stdout)
    return finish(run_dir, cfg, code, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
