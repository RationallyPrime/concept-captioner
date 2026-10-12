#!/usr/bin/env python3
"""run.json -> ostris/ai-toolkit config.yaml -> run.py, with log tee and loss scraping (POD-SPEC §4.3).

    launch_aitoolkit.py --config /workspace/runs/<id>/run.json [--dry-run]

1. Validate run.json: an own copy of the RunConfig rules of POD-SPEC §4.1 (no podagent import).
   ``dataset.path`` must be an existing directory under ``<PODAGENT_WORKSPACE>/datasets``.
2. Write ``<run>/config.yaml``: ai-toolkit ``job: extension`` with one ``sd_trainer`` process,
   ``extra`` deep-merged last. ``--dry-run`` stops here with exit 0.
3. Spawn ``python /opt/ai-toolkit/run.py <run>/config.yaml`` and tee its output to stdout, which
   the agent points at ``<run>/trainer.log``. ``\\r``-separated progress-bar redraws are written
   as separate lines so the agent's line-based ``logs`` endpoint stays usable. While tee'ing,
   ``loss`` / ``lr`` / ``step`` patterns are scraped into ``<run>/tensorboard/`` as
   ``scraped/loss`` and ``scraped/lr`` through ``torch.utils.tensorboard.SummaryWriter`` when
   it is importable; otherwise scraping is skipped with one line in the log.
4. On exit 0 with ``hub.push_on_finish``, run the sibling ``push_lora.py`` (agent venv).
5. Exit with the trainer's code; when the trainer succeeded but the push did not, with the
   push's code, so a nonzero exit always means something did not land.

The run directory is the directory holding run.json. ``extra`` keys ``job``/``config``/``meta``
merge at the document root; every other key merges into ``config.process[0]`` (so
``{"train": {"optimizer": "prodigy"}}`` does what one expects). Mappings merge recursively;
lists and scalars are replaced. ``extra`` cannot take the trainer out of the workspace: after
the merge, ``training_folder``, ``log_dir`` and ``datasets[*].folder_path`` must resolve under
``PODAGENT_WORKSPACE`` (or the run directory), ``model.name_or_path`` must be a Hub id or such
a path, and ``config.name`` must be a plain run id (``check_native_paths``); otherwise exit 2.

Every ai-toolkit key that has not been confirmed against the pinned checkout carries a
``# VERIFY`` comment (POD-SPEC §4.2). Resume: ai-toolkit continues from the newest checkpoint it
finds in ``training_folder/<name>`` on its own (VERIFY), so an existing ``output/`` is left alone.

Environment: ``PODAGENT_WORKSPACE`` (default ``/workspace``), ``AI_TOOLKIT_DIR`` (default
``/opt/ai-toolkit``), ``POD_AGENT_PYTHON`` (interpreter for push_lora.py; default
``/opt/venvs/agent/bin/python``, else this interpreter), ``HF_TOKEN`` (or ``hf_token`` in
run.json, which is passed to children through the environment only).

Standard library only at import time; PyYAML writes config.yaml when importable, else a small
emitter here does. The block between the ``shared`` markers is byte-identical in launch_ltx.py
(tests assert it): the scripts run under ``python -I``, so sibling imports are not available.
"""

from __future__ import annotations

import argparse
import codecs
import contextlib
import json
import math
import os
import re
import runpy
import shlex
import signal
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, TextIO

SCRIPT_NAME = "launch_aitoolkit"

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
        "resume",
        "initialization",
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


def _validate_dataset(
    value: Any, workspace: Path | None, errors: list[str], *, allow_missing: bool = False
) -> dict[str, str]:
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
            elif not resolved.is_dir() and not (allow_missing and not resolved.exists()):
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


def validate_run_config(
    raw: Any, workspace: Path | None = None, *, allow_missing_dataset: bool = False
) -> dict[str, Any]:
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
    cfg["dataset"] = _validate_dataset(
        raw.get("dataset"), workspace, errors, allow_missing=allow_missing_dataset
    )
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
    cfg["initialization"] = raw.get("initialization")
    if cfg["initialization"] is not None:
        helper = runpy.run_path(str(Path(__file__).with_name("h3_recipe.py")))
        try:
            helper["validate_initialization"](cfg["initialization"])
        except ValueError as error:
            errors.append(str(error))
    cfg["resume"] = raw.get("resume", False)
    if not isinstance(cfg["resume"], bool):
        errors.append("resume: must be true or false")
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


def load_run(
    config_path: Path, *, restore_missing_dataset: bool = True
) -> tuple[Path, dict[str, Any]]:
    """run.json path -> (run directory, validated config). The run directory holds run.json."""
    config_path = config_path.expanduser().resolve()
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    workspace = workspace_root()
    cfg = validate_run_config(
        raw,
        workspace,
        allow_missing_dataset=restore_missing_dataset
        and isinstance(raw, dict)
        and raw.get("resume") is True,
    )
    run_dir = config_path.parent
    restore = runpy.run_path(str(Path(__file__).with_name("restore_dataset.py")))["restore_dataset"]
    try:
        if restore_missing_dataset:
            restore(cfg, run_dir, workspace)
    except (OSError, ValueError) as error:
        raise ConfigError(str(error)) from error
    cfg = validate_run_config(cfg, workspace)
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

AI_TOOLKIT_DIR_ENV = "AI_TOOLKIT_DIR"
DEFAULT_AI_TOOLKIT_DIR = "/opt/ai-toolkit"
ROOT_KEYS = frozenset({"job", "config", "meta"})
_H3_RE = re.compile(r"(?<![a-z0-9])h3(?![a-z0-9])")
_H3_MARKERS = ("minimax", "hailuo")

YAML_HEADER = (
    "# ai-toolkit config written by launch_aitoolkit.py from run.json (POD-SPEC §4.3).\n"
    '# Regenerated at every start; put overrides in run.json "extra", not here.\n'
    "# Keys marked VERIFY in launch_aitoolkit.py are not yet confirmed against the pinned checkout.\n"
)


def model_block(base_model: str) -> dict[str, Any]:
    """ai-toolkit ``model`` section for a base model id or path (POD-SPEC §4.3)."""
    lowered = base_model.lower()
    block: dict[str, Any] = {"name_or_path": base_model}
    if "flux" in lowered:
        block["arch"] = "flux"  # VERIFY: newer ai-toolkit selects the family by `arch`
        block["is_flux"] = True  # VERIFY: legacy flag, kept for older checkouts
        block["quantize"] = True  # 8-bit mixed precision, as in ai-toolkit's FLUX examples
    elif _H3_RE.search(lowered) or any(marker in lowered for marker in _H3_MARKERS):
        block["arch"] = "minimax_h3"
        block["quantize"] = False
        block["quantize_te"] = False
    # any other family: name_or_path only; set `extra.model.arch` in run.json
    return block


def build_native_config(cfg: dict[str, Any], run_dir: Path) -> dict[str, Any]:
    """The ai-toolkit document for a validated run config: the mapping table of POD-SPEC §4.3."""
    size = max(cfg["resolution"])
    sampling = cfg["sample_every"] > 0 and bool(cfg["sample_prompts"])
    process: dict[str, Any] = {
        "type": "sd_trainer",
        "training_folder": str(run_dir / "output"),  # ai-toolkit writes output/<run_id>/ inside
        "device": "cuda:0",  # the agent sets CUDA_VISIBLE_DEVICES; the trainer sees cuda:0..k-1
        # Captions already contain their mapped concepts; no global trigger is injected.
        "log_dir": str(run_dir / "tensorboard"),  # VERIFY: native TensorBoard logging; ai-toolkit
        # creates <log_dir>/<name>_<timestamp>/ next to the scraper's own file. The agent's
        # events reader scans <run>/tensorboard recursively, so both reach /runs/{id}/events.
        "network": {"type": "lora", "linear": cfg["rank"], "linear_alpha": cfg["alpha"]},
        "save": {
            "dtype": "float16",
            "save_every": cfg["save_every"],
            "max_step_saves_to_keep": 4,
            "push_to_hub": False,  # pushing is push_lora.py's job
        },
        "datasets": [
            {
                "folder_path": cfg["dataset"]["path"],
                "caption_ext": cfg["dataset"]["caption_ext"],
                "resolution": list(cfg["resolution"]),
                "cache_latents_to_disk": True,
                "caption_dropout_rate": 0.05,
            }
        ],
        "train": {
            "batch_size": cfg["batch_size"],
            "steps": cfg["steps"],
            "gradient_accumulation_steps": cfg["gradient_accumulation"],
            "lr": cfg["learning_rate"],
            "dtype": "bf16",
            "optimizer": "adamw8bit",
            "noise_scheduler": "flowmatch",
            "gradient_checkpointing": True,
            "train_text_encoder": False,
            "disable_sampling": not sampling,
        },
        "model": model_block(cfg["base_model"]),
        "sample": {
            "sampler": "flowmatch",
            # ai-toolkit takes step % sample_every, so 0 must not reach it; disable_sampling does
            "sample_every": cfg["sample_every"] if sampling else cfg["steps"],
            "width": size,
            "height": size,
            "prompts": list(cfg["sample_prompts"]),
            "seed": cfg["seed"],
            "guidance_scale": 4,
            "sample_steps": 20,
        },
    }
    # VERIFY: resume. ai-toolkit continues from the newest checkpoint in training_folder/<name>
    # by itself; nothing is deleted here, so a restart with an existing output/ resumes.
    extra = cfg["extra"]
    process = deep_merge(process, {k: v for k, v in extra.items() if k not in ROOT_KEYS})
    document: dict[str, Any] = {
        "job": "extension",
        "config": {"name": cfg["run_id"], "process": [process]},
        "meta": {"name": "[name]", "version": "1.0"},
    }
    document = deep_merge(document, {k: v for k, v in extra.items() if k in ROOT_KEYS})
    if cfg["base_model"] == "Comfy-Org/MiniMax-H3":
        rules = runpy.run_path(str(Path(__file__).with_name("h3_recipe.py")))
        groups = runpy.run_path(str(Path(__file__).with_name("h3_dataset.py")))["dataset_groups"](
            cfg, run_dir
        )
        quality = rules["quality_settings"](video=any(d["num_frames"] > 1 for d in groups))
        if cfg.get("initialization"):
            quality = deep_merge(
                quality, rules["read_initialization"](run_dir, cfg["initialization"], cfg["rank"])
            )
        quality = deep_merge(quality, extra)
        rules["validate_guidance"](quality)
        process = document["config"]["process"][0]
        process.pop("dataset", None)
        process.pop("trigger_word", None)
        process["training_folder"] = str(run_dir / "output")
        process["log_dir"] = str(run_dir / "tensorboard")
        process["device"] = "cuda:0"
        document["job"] = "extension"
        document["config"]["name"] = cfg["run_id"]
        document["config"]["process"] = [process]
        model = quality["model"].copy()
        adapter = model.pop("use_training_adapter", True)
        process["model"] = deep_merge(
            rules["model_config"](workspace_root(), training_adapter=adapter), model
        )
        process["network"] = deep_merge(process["network"], quality["network"])
        process["network"].update(linear=cfg["rank"], linear_alpha=cfg["alpha"])
        process["save"] = deep_merge(process["save"], quality["save"])
        process["save"]["save_every"] = cfg["save_every"]
        process["train"] = deep_merge(process["train"], quality["train"])
        process["train"].update(
            steps=cfg["steps"],
            lr=cfg["learning_rate"],
            batch_size=cfg["batch_size"],
            gradient_accumulation=cfg["gradient_accumulation"],
        )
        process["train"].pop("gradient_accumulation_steps", None)
        process["datasets"] = [deep_merge(quality["dataset"], row) for row in groups]
        if cfg.get("initialization"):
            process["network"]["pretrained_lora_path"] = str(run_dir / "initial-lora.safetensors")
            rules["validate_weights"](
                run_dir / "initial-lora.safetensors",
                cfg["rank"],
                process["network"].get("network_kwargs"),
            )
            if not cfg["resume"]:
                if any((run_dir / "output").rglob("*.safetensors")):
                    raise ConfigError(
                        "External initial weights require a new run without old outputs"
                    )
                process["train"]["start_step"] = 0
            else:
                # A real same-run Resume restores the newest checkpoint's saved step.
                process["train"].pop("start_step", None)
        process["sample"].update(num_frames=1, fps=24)
    check_native_paths(document, run_dir)
    return document


def check_native_paths(document: dict[str, Any], run_dir: Path) -> None:
    """Every path the merged document hands ai-toolkit must stay inside the workspace.

    ``extra`` merges last and may name anything, so the check runs on the final document
    rather than on ``extra``: ``training_folder`` and ``log_dir`` (written to), every
    ``datasets[*].folder_path`` (read), ``model.name_or_path`` (a Hub id or a local path) and
    ``config.name`` (a folder created under ``training_folder``, so it must be a plain run id).
    Allowed roots: ``PODAGENT_WORKSPACE`` and the run directory. Raises ConfigError listing
    every violation.
    """
    roots = (workspace_root(), run_dir)
    errors: list[str] = []
    config = document.get("config")
    if not isinstance(config, dict):
        raise ConfigError("config: must be a mapping")
    name = config.get("name")
    if not isinstance(name, str) or not RUN_ID_RE.match(name):
        errors.append(
            "config.name: must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ "
            f"(it names a folder under training_folder), got {name!r}"
        )
    processes = config.get("process")
    if not isinstance(processes, list) or not processes:
        raise ConfigError("config.process: must be a non-empty list")
    for index, process in enumerate(processes):
        label = f"config.process[{index}]"
        if not isinstance(process, dict):
            errors.append(f"{label}: must be a mapping")
            continue
        require_path(errors, f"{label}.training_folder", process.get("training_folder"), roots)
        if process.get("log_dir") is not None:  # null: no native logging, nothing to check
            require_path(errors, f"{label}.log_dir", process.get("log_dir"), roots)
        model = process.get("model")
        if not isinstance(model, dict):
            errors.append(f"{label}.model: must be a mapping")
        else:
            require_model_ref(
                errors, f"{label}.model.name_or_path", model.get("name_or_path"), roots
            )
        datasets = process.get("datasets")
        if not isinstance(datasets, list):
            errors.append(f"{label}.datasets: must be a list")
            continue
        for j, dataset in enumerate(datasets):
            if not isinstance(dataset, dict):
                errors.append(f"{label}.datasets[{j}]: must be a mapping")
                continue
            require_path(
                errors, f"{label}.datasets[{j}].folder_path", dataset.get("folder_path"), roots
            )
    if errors:
        raise ConfigError("; ".join(errors))


def trainer_argv(run_dir: Path, cfg: dict[str, Any]) -> list[str]:
    """``python /opt/ai-toolkit/run.py <run>/config.yaml`` in this (the aitoolkit) venv."""
    del cfg  # the command does not depend on the config; tests replace this function
    root = Path(os.environ.get(AI_TOOLKIT_DIR_ENV) or DEFAULT_AI_TOOLKIT_DIR)
    return [sys.executable, str(root / "run.py"), str(run_dir / "config.yaml")]  # VERIFY: CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--config", required=True, help="path to run.json (its directory is the run)"
    )
    parser.add_argument("--dry-run", action="store_true", help="write config.yaml and exit")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        run_dir, cfg = load_run(Path(args.config), restore_missing_dataset=not args.dry_run)
        native = build_native_config(cfg, run_dir)
    except (OSError, ValueError) as exc:
        say(f"invalid run config {args.config}: {exc}")
        return 2
    config_yaml = run_dir / "config.yaml"
    write_yaml(config_yaml, native, YAML_HEADER)
    native_snapshot = run_dir / "native-config.json.tmp"
    native_snapshot.write_text(json.dumps(native, indent=2) + "\n")
    os.replace(native_snapshot, run_dir / "native-config.json")
    say(f"wrote {config_yaml}")
    cmd = trainer_argv(run_dir, cfg)
    say(f"trainer command: {shlex.join(cmd)}")
    if cfg["hub"] is not None and cfg["hub"]["push_on_finish"]:
        say(f"push on finish: {shlex.join(push_lora_argv(run_dir, cfg))}")
    if args.dry_run:
        say("dry run: trainer not started")
        return 0
    if cfg["base_model"] == "Comfy-Org/MiniMax-H3":
        rules = runpy.run_path(str(Path(__file__).with_name("h3_recipe.py")))
        model = native["config"]["process"][0]["model"]
        rules["download_assets"](
            workspace_root(), training_adapter=bool(model.get("assistant_lora_path"))
        )
    code = run_trainer(cmd, run_dir, cfg, sys.stdout)
    return finish(run_dir, cfg, code, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
