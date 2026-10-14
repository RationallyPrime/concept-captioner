#!/usr/bin/env python3
"""Regularisation sets for AI Toolkit runs: plan the prompts, draw the images, copy the set.

    regularization.py draw --run RUN_DIR   # the draw-regularization service (GPU)

A regularisation (prior-preservation) set is ordinary pictures of the subject's class ("a person")
trained beside the subject, so the trigger keeps meaning one person while "a person" keeps meaning
any person. ``run.json`` carries a top-level ``regularization`` object (docs/model-table.md; the
launcher's mapping is in POD-SPEC 4.3):

    {"source": "generate", "images": 40, "weight": 1.0, "class_nouns": {"ohwx": "person"},
     "generation": {"steps": 40, "guidance_scale": 3.0, "seed": 0},
     "captions": {"<image key>": "a person stands in a kitchen."}}
    {"source": "folder", "path": "/workspace/datasets/reg-3f2a9c1e7b40", "weight": 1.0}

Generated sets
    The set is made in two steps with the app in between. ``draw`` runs as its own service before
    the run: it plans the prompts, draws the missing images with the base model and copies the
    planned pictures to ``<draw run>/output/<image key>.png``, where the agent's file routes serve
    them. The app captions each picture with the project's captioner (which is never given a
    trigger) and starts the run with the captions in ``regularization.captions``, image key to
    text. The launcher then plans again (same keys) and ``materialize`` copies each captioned
    picture into the run with its caption. A picture the captioner found unusable has no caption
    and is left out.

    The prompts come from the subject captions on this pod (``<dataset>/<stem>.<caption_ext>``,
    image files only, sorted by file name). For each caption, in order:

    1. every exact-token trigger ``T`` followed by ``", "`` and an article (a, an, the; any case)
       loses ``T, `` (``ohwx, a person, sits`` becomes ``a person, sits``);
    2. every remaining exact-token ``T`` becomes ``the <class noun>`` (``ohwx's coat`` becomes
       ``the person's coat``);
    3. a caption that changed has its first letter capitalised, and so has each place where a
       replacement began a sentence (the text start, or after ``". "``, ``"! "`` or ``"? "``);
    4. the result must contain no trigger as an exact token, else the caption is skipped with one
       log line. A caption with no trigger is already class-only and is used unchanged.

    Exact-token matching is ``concept_captioner.stages.exact_trigger_spans`` (NFC, case-sensitive,
    no letter, mark, digit or ``_`` on either side), re-implemented here because the scripts run
    under ``python -I`` without that package.

    With P distinct prompts and N images, prompt j gets floor(N/P) images and the first N mod P
    prompts one more; when N < P, N prompts evenly spaced through the list get one each. Image k
    of a prompt uses seed ``generation.seed + k``. Each image has its source image's aspect at an
    area of about ``max(resolution)**2``, in multiples of 64, so the set fills the same buckets.

    Images are cached per model and per image in ``<workspace>/regsets/<model-key>/<image-key>.png``
    and ``.txt`` (the prompt that drew it), written under temporary names and renamed, so a stopped
    drawing keeps every finished image and the next start draws only the missing ones. The run
    trains on a copy, ``<run>/regularization/``, described by ``<run>/regularization.json``.

Exit codes of the command line: 0 done, 2 bad input (nothing was drawn), 1 drawing failed.

Standard library only at import time (Pillow is read for image sizes when importable); ``draw``
loads ``generate_results.py`` and, through it, ai-toolkit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import runpy
import shutil
import sys
import unicodedata
from collections.abc import Callable
from pathlib import Path
from typing import Any

SCRIPT_NAME = "regularization"
IMAGE_SUFFIXES = frozenset({".jpg", ".jpeg", ".png", ".webp"})
PLAN_VERSION = 1
PLAN_FILE = "regularization-plan.json"
MANIFEST_FILE = "regularization.json"
COPY_DIR = "regularization"
OUTPUT_DIR = "output"  # what the agent serves from a run directory
DRAW_FILE = "regularization-draw.json"  # the draw service's params, written by the agent
SAMPLER = "flowmatch"
SIZE_MULTIPLE = 64
ARTICLES = ("an", "the", "a")  # longest first
SENTENCE_ENDS = (". ", "! ", "? ")

UNSUPPORTED = (
    "Generated regularisation images need a supported model. Provide your own images instead."
)


class InputError(ValueError):
    """Bad input (a trigger in a caption, no prompt derivable, a missing folder): exit code 2."""


class GenerationError(RuntimeError):
    """Drawing or copying the set failed: exit code 1."""


def say(message: str) -> None:
    """One line on stdout, tagged like the launcher's own lines."""
    print(f"[{SCRIPT_NAME}] {message}", flush=True)


# --- exact-token trigger matching -------------------------------------------------------------


def _is_word_char(char: str) -> bool:
    return char == "_" or unicodedata.category(char)[0] in {"L", "M", "N"}


def exact_trigger_spans(text: str, trigger: str) -> tuple[tuple[int, int], ...]:
    """Whole-token occurrences of ``trigger`` in ``text`` (both NFC; case-sensitive)."""
    spans: list[tuple[int, int]] = []
    start = 0
    while trigger:
        index = text.find(trigger, start)
        if index < 0:
            break
        end = index + len(trigger)
        left = index == 0 or not _is_word_char(text[index - 1])
        right = end == len(text) or not _is_word_char(text[end])
        if left and right:
            spans.append((index, end))
        start = index + 1
    return tuple(spans)


def _nfc(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def first_trigger_in(text: str, triggers: list[str]) -> str | None:
    """The first trigger of ``triggers`` that occurs in ``text`` as an exact token, else None."""
    normalized = _nfc(text)
    for trigger in triggers:
        if exact_trigger_spans(normalized, _nfc(trigger)):
            return trigger
    return None


# --- prompts ----------------------------------------------------------------------------------


def _article_follows(text: str, end: int) -> bool:
    """Whether ``text[end:]`` starts with ``", "`` and then an article as a whole word."""
    if not text.startswith(", ", end):
        return False
    start = end + 2
    for article in ARTICLES:
        stop = start + len(article)
        if text[start:stop].lower() == article and (
            stop == len(text) or not _is_word_char(text[stop])
        ):
            return True
    return False


def derive_prompt(caption: str, class_nouns: dict[str, str]) -> str | None:
    """The class-only prompt for a subject caption, or None when a trigger would remain.

    ``class_nouns`` maps every trigger to its noun. See the module docstring for the rules.
    """
    stripped = caption.strip()
    text = _nfc(stripped)
    nouns = {_nfc(trigger): noun.strip() for trigger, noun in class_nouns.items()}
    edits: list[tuple[int, int, str]] = []  # (start, end, replacement), left to right
    for trigger in nouns:
        for start, end in exact_trigger_spans(text, trigger):
            if _article_follows(text, end):
                edits.append((start, end + 2, ""))
            else:
                edits.append((start, end, f"the {nouns[trigger]}"))
    edits.sort(key=lambda edit: (edit[0], -edit[1]))
    kept: list[tuple[int, int, str]] = []
    for edit in edits:  # overlapping triggers: the earlier span wins, then the longer
        if not kept or edit[0] >= kept[-1][1]:
            kept.append(edit)
    if not kept:
        return stripped  # already class-only
    pieces: list[str] = []
    sites: list[int] = []  # where, in the new text, a replacement began
    cursor = 0
    length = 0
    for start, end, replacement in kept:
        before = text[cursor:start]
        pieces.append(before)
        length += len(before)
        sites.append(length)
        pieces.append(replacement)
        length += len(replacement)
        cursor = end
    pieces.append(text[cursor:])
    result = "".join(pieces)
    chars = list(result)
    for position in {0, *sites}:
        at_start = position == 0 or result[:position].endswith(SENTENCE_ENDS)
        if at_start and position < len(chars) and chars[position].isalpha():
            chars[position] = chars[position].upper()
    result = "".join(chars)
    if first_trigger_in(result, list(nouns)) is not None:
        return None
    return result


def prompt_problem(prompt: str) -> str | None:
    """Why ``prompt`` cannot be drawn exactly as written, else None."""
    if not prompt.strip():
        return "the prompt is empty"
    if "--" in prompt:
        # GenerateImageConfig reads '--' in a prompt as option overrides (the agent refuses it too)
        return "the prompt contains '--', which the generator reads as an option"
    if "\x00" in prompt:
        return "the prompt contains a NUL character"
    return None


# --- sizes, allocation, keys ------------------------------------------------------------------


def image_size(aspect: float, resolution: int) -> tuple[int, int]:
    """(width, height): the multiple of 64 nearest the aspect, at an area of about resolution**2."""
    width = round(math.sqrt(resolution**2 * aspect) / SIZE_MULTIPLE) * SIZE_MULTIPLE
    height = round(math.sqrt(resolution**2 / aspect) / SIZE_MULTIPLE) * SIZE_MULTIPLE
    return max(SIZE_MULTIPLE, width), max(SIZE_MULTIPLE, height)


def image_aspect(path: Path) -> float | None:
    """width / height of an image file from its header (EXIF orientation applied), else None."""
    try:
        from PIL import Image

        with Image.open(path) as image:
            width, height = image.size
            if image.getexif().get(0x0112) in {5, 6, 7, 8}:  # rotated by 90 degrees
                width, height = height, width
    except Exception:
        return None
    return width / height if width > 0 and height > 0 else None


def allocate(prompts: int, images: int) -> list[tuple[int, int]]:
    """``(prompt index, k)`` for each of ``images``: even shares, or evenly spaced prompts."""
    if prompts <= 0 or images <= 0:
        return []
    if images < prompts:
        return [((i * prompts) // images, 0) for i in range(images)]
    share, extra = divmod(images, prompts)
    return [(j, k) for j in range(prompts) for k in range(share + (1 if j < extra else 0))]


def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()[:16]


def resolved_revisions(base_model: str, row: dict[str, Any]) -> dict[str, str]:
    """The commit of every Hub repo the model's weights come from.

    A pinned row names its revision. An unpinned one is resolved now, together with the repos
    ``source.weight_repos`` lists (a repack AI Toolkit downloads from), so a cached picture is
    reused only while every one of them is unchanged. A local model is its own identity.
    """
    source = row["source"]
    if source.get("revision"):
        return {base_model: source["revision"]}
    if Path(base_model).is_absolute():
        return {base_model: "local"}
    from huggingface_hub import HfApi

    api = HfApi()
    revisions = {}
    for repo in dict.fromkeys([base_model, *source.get("weight_repos", [])]):
        try:
            revisions[repo] = api.model_info(repo).sha or ""
        except Exception as error:  # any failure leaves the identity unknown
            raise GenerationError(
                f"Could not read the current revision of {repo} from the Hub ({error}); "
                "regularisation images are only drawn or reused for a known revision"
            ) from error
    return revisions


def model_key(base_model: str, row: dict[str, Any], ai_pin: str, revisions: dict[str, str]) -> str:
    """Everything that changes an image besides its prompt: model commits, trainer pin, arch."""
    return _digest(
        {
            "base_model": base_model,
            "revisions": revisions,
            "ai_toolkit": ai_pin,
            "architecture": row["architecture"],
        }
    )


def image_key(
    prompt: str, seed: int, width: int, height: int, steps: int, guidance_scale: float
) -> str:
    return _digest(
        {
            "prompt": prompt,
            "seed": seed,
            "width": width,
            "height": height,
            "steps": steps,
            "guidance_scale": float(guidance_scale),
            "sampler": SAMPLER,
        }
    )


# --- the neighbours: the model table and generate_results.py ---------------------------------


def _sibling(name: str) -> dict[str, Any]:
    return runpy.run_path(str(Path(__file__).with_name(name)))


def model_table() -> dict[str, Any]:
    return _sibling("model_table.py")


def regsets_root(workspace: Path) -> Path:
    return workspace / "regsets"


# --- planning ---------------------------------------------------------------------------------


def _atomic_write(path: Path, text: str) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


def is_cached(cache: Path, key: str) -> bool:
    """Both halves of an image exist: the picture, then its caption (written last)."""
    png, txt = cache / f"{key}.png", cache / f"{key}.txt"
    try:
        return png.stat().st_size > 0 and bool(txt.read_text(encoding="utf-8").strip())
    except OSError:
        return False


def subject_prompts(
    cfg: dict[str, Any], resolution: int, skip: Callable[[str, str], None]
) -> list[dict[str, Any]]:
    """Distinct class-only prompts, one per usable subject caption, with the size each is drawn at."""
    block = cfg["regularization"]
    dataset = Path(cfg["dataset"]["path"])
    extension = cfg["dataset"]["caption_ext"].lstrip(".")
    nouns = block["class_nouns"]
    images = sorted(
        (p for p in dataset.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES),
        key=lambda p: p.name,
    )
    prompts: list[dict[str, Any]] = []
    seen: set[tuple[str, int, int]] = set()
    for image in images:
        caption_file = dataset / f"{image.stem}.{extension}"
        try:
            caption = caption_file.read_text(encoding="utf-8")
        except OSError:
            skip(image.name, "no caption")
            continue
        if not caption.strip():
            skip(image.name, "the caption is blank")
            continue
        prompt = derive_prompt(caption, nouns)
        if prompt is None:
            skip(image.name, "a trigger would remain in the prompt")
            continue
        problem = prompt_problem(prompt)
        if problem is not None:
            skip(image.name, problem)
            continue
        aspect = image_aspect(image)
        if aspect is None:
            say(f"size of {image.name} is unreadable; drawing its prompt at a square size")
            aspect = 1.0
        width, height = image_size(aspect, resolution)
        if (prompt, width, height) in seen:
            continue  # the same prompt at the same size is the same picture
        seen.add((prompt, width, height))
        prompts.append({"prompt": prompt, "width": width, "height": height, "source": image.name})
    return prompts


def plan_generated(cfg: dict[str, Any], run_dir: Path, workspace: Path) -> dict[str, Any]:
    """Plan a generated set and write ``<run>/regularization-plan.json``; returns the plan.

    Raises InputError when the model cannot draw the set or no prompt can be derived.
    """
    block = cfg["regularization"]
    table = model_table()
    row = table["exact_row"](cfg["base_model"], "aitoolkit")
    if row is None or not row.get("regularization") or table["hook"](row, "trainer_config"):
        raise InputError(UNSUPPORTED)
    ai_pin = _sibling("generate_results.py")["AI_PIN"]
    generation = block["generation"]
    skipped: list[dict[str, str]] = []

    def skip(file: str, reason: str) -> None:
        skipped.append({"file": file, "reason": reason})
        say(f"skipped {file}: {reason}")

    dataset = Path(cfg["dataset"]["path"])
    if not dataset.is_dir():
        raise InputError(f"dataset.path: {dataset} is not a directory")
    prompts = subject_prompts(cfg, max(cfg["resolution"]), skip)
    if not prompts:
        raise InputError(
            f"No regularisation prompts could be derived from the captions in {dataset}"
        )
    key = model_key(cfg["base_model"], row, ai_pin, resolved_revisions(cfg["base_model"], row))
    cache = regsets_root(workspace) / key
    images: list[dict[str, Any]] = []
    for index, k in allocate(len(prompts), block["images"]):
        prompt = prompts[index]
        seed = generation["seed"] + k
        entry = {
            "key": image_key(
                prompt["prompt"],
                seed,
                prompt["width"],
                prompt["height"],
                generation["steps"],
                generation["guidance_scale"],
            ),
            "prompt": prompt["prompt"],
            "seed": seed,
            "width": prompt["width"],
            "height": prompt["height"],
            "steps": generation["steps"],
            "guidance_scale": float(generation["guidance_scale"]),
            "sampler": SAMPLER,
            "source": prompt["source"],
        }
        entry["cached"] = is_cached(cache, entry["key"])
        images.append(entry)
    plan = {
        "version": PLAN_VERSION,
        "run_id": cfg["run_id"],
        "base_model": cfg["base_model"],
        "model_key": key,
        "cache_dir": str(cache),
        "caption_ext": cfg["dataset"]["caption_ext"].lstrip("."),
        "planned": len(images),
        "cached": sum(1 for image in images if image["cached"]),
        "images": images,
        "skipped": skipped,
    }
    run_dir.mkdir(parents=True, exist_ok=True)
    _atomic_write(run_dir / PLAN_FILE, json.dumps(plan, indent=2, ensure_ascii=False) + "\n")
    return plan


def plan_summary(plan: dict[str, Any]) -> str:
    to_draw = plan["planned"] - plan["cached"]
    return (
        f"regularisation: {plan['planned']} planned, {plan['cached']} cached, {to_draw} to generate"
    )


def load_plan(path: Path) -> dict[str, Any]:
    plan = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(plan, dict) or plan.get("version") != PLAN_VERSION:
        raise InputError(f"{path}: not a regularisation plan")
    return plan


# --- drawing ----------------------------------------------------------------------------------


def _sweep(cache: Path) -> None:
    """Remove what a killed drawing left: the work directory and half-written names."""
    shutil.rmtree(cache / ".work", ignore_errors=True)
    for leftover in cache.glob("*.tmp"):
        leftover.unlink(missing_ok=True)


def _commit(cache: Path, work: Path, image: dict[str, Any]) -> None:
    """Move one drawn picture into the cache, then its caption (the caption makes it count)."""
    picture = work / f"{image['key']}.png"
    if not picture.is_file() or picture.stat().st_size == 0:
        raise GenerationError(f"the model wrote no picture for the prompt: {image['prompt']!r}")
    os.replace(picture, cache / f"{image['key']}.png")
    _atomic_write(cache / f"{image['key']}.txt", image["prompt"] + "\n")


def generate(
    plan_path: Path, render: Callable[..., None] | None = None, *, work_root: Path | None = None
) -> int:
    """Draw the images of ``plan_path`` that are not in the cache; returns 0.

    Prints ``[regularization] ready k/N`` per image (k counts the cached ones too), which the app
    shows as progress. ``render`` defaults to ``generate_results.render_base``.
    """
    plan = load_plan(plan_path)
    cache = Path(plan["cache_dir"])
    cache.mkdir(parents=True, exist_ok=True)
    _sweep(cache)
    planned = plan["planned"]
    missing = [image for image in plan["images"] if not is_cached(cache, image["key"])]
    ready = planned - len(missing)
    if not missing:
        say(f"ready {planned}/{planned}")
        return 0
    work = work_root or (cache / ".work")
    work.mkdir(parents=True, exist_ok=True)
    jobs = [
        {
            "prompt": image["prompt"],
            "seed": image["seed"],
            "width": image["width"],
            "height": image["height"],
            "steps": image["steps"],
            "guidance_scale": image["guidance_scale"],
            "path": f"{image['key']}.png",
        }
        for image in missing
    ]
    by_path = {job["path"]: image for job, image in zip(jobs, missing, strict=True)}

    def on_ready(chunk: list[dict[str, Any]]) -> None:
        nonlocal ready
        for job in chunk:
            _commit(cache, work, by_path[job["path"]])
            ready += 1
            say(f"ready {ready}/{planned}")

    if render is None:
        render = _sibling("generate_results.py")["render_base"]
    say(f"drawing {len(missing)} of {planned} images with {plan['base_model']}")
    try:
        render(plan["base_model"], jobs, work, on_ready=on_ready)
    finally:
        shutil.rmtree(work, ignore_errors=True)
        _sweep(cache)
    absent = [image["key"] for image in plan["images"] if not is_cached(cache, image["key"])]
    if absent:
        raise GenerationError(f"{len(absent)} regularisation images were not drawn")
    return 0


def export_images(plan: dict[str, Any], run_dir: Path) -> None:
    """Link the planned pictures to ``<run>/output/<image key>.png``, which the agent serves.

    Hard links, so a drawing's run holds no second copy of the cached set (a copy where the
    filesystem cannot link).
    """
    output = run_dir / OUTPUT_DIR
    output.mkdir(parents=True, exist_ok=True)
    cache = Path(plan["cache_dir"])
    for image in plan["images"]:
        source, target = cache / f"{image['key']}.png", output / f"{image['key']}.png"
        target.unlink(missing_ok=True)
        try:
            os.link(source, target)
        except OSError:
            shutil.copyfile(source, target)


def draw(cfg: dict[str, Any], run_dir: Path, workspace: Path) -> None:
    """The draw-regularization service: plan, draw what the cache lacks, export the pictures."""
    plan = plan_generated(cfg, run_dir, workspace)
    say(plan_summary(plan))
    generate(run_dir / PLAN_FILE)
    export_images(plan, run_dir)
    say(f"{plan['planned']} images ready in {run_dir / OUTPUT_DIR}")


# --- the per-run copy -------------------------------------------------------------------------


def existing_copy(run_dir: Path, block: dict[str, Any]) -> dict[str, Any] | None:
    """The manifest of the copy this run already has, when it is for this block and complete."""
    try:
        manifest = json.loads((run_dir / MANIFEST_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(manifest, dict) or manifest.get("block") != block:
        return None
    folder = run_dir / COPY_DIR
    images = manifest.get("images")
    if not isinstance(images, list) or not images:
        return None
    for entry in images:
        try:
            names = (entry["file"], entry["caption"])
        except (KeyError, TypeError):
            return None  # a manifest this script did not write
        if not all(isinstance(name, str) and (folder / name).is_file() for name in names):
            return None
    return manifest


def _write_copy(
    run_dir: Path, entries: list[tuple[Path, str, str, dict[str, Any]]], manifest: dict[str, Any]
) -> dict[str, Any]:
    """Replace ``<run>/regularization/`` with ``entries`` ((picture, name, caption, extra)) and
    write the manifest last, so a manifest on disk always describes a complete copy."""
    folder = run_dir / COPY_DIR
    (run_dir / MANIFEST_FILE).unlink(missing_ok=True)
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    described = []
    for picture, file, caption, extra in entries:
        shutil.copyfile(picture, folder / file)
        caption_file = f"{Path(file).stem}.{manifest['caption_ext']}"
        (folder / caption_file).write_text(caption, encoding="utf-8")
        described.append({"file": file, "caption": caption_file, **extra})
    manifest = {**manifest, "images": described}
    _atomic_write(
        run_dir / MANIFEST_FILE, json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    )
    return manifest


def materialize(cfg: dict[str, Any], run_dir: Path, plan: dict[str, Any]) -> dict[str, Any]:
    """Copy the captioned planned images into ``<run>/regularization/`` and describe them.

    The captions are ``regularization.captions`` (image key to text, written by the app's
    captioner); a planned image without one is left out. Raises InputError when no image has a
    caption or a caption holds a trigger, GenerationError when the cache lacks a captioned image.
    The copy carries the captions with the dataset's caption extension, because the trainer reads
    the second dataset the same way.
    """
    captions = {
        key: text.strip()
        for key, text in cfg["regularization"].get("captions", {}).items()
        if text.strip()
    }
    kept = [image for image in plan["images"] if image["key"] in captions]
    if not kept:
        raise InputError("No regularisation image has a caption")
    for image in kept:
        trigger = first_trigger_in(captions[image["key"]], cfg["triggers"])
        if trigger is not None:
            raise InputError(
                f"Regularisation caption of image {image['key']} contains the trigger {trigger}"
            )
    cache = Path(plan["cache_dir"])
    absent = [image["key"] for image in kept if not is_cached(cache, image["key"])]
    if absent:
        raise GenerationError(f"{len(absent)} captioned regularisation images are not in the cache")
    entries = [
        (
            cache / f"{image['key']}.png",
            f"{image['key']}.png",
            captions[image["key"]],
            {
                key: image[key]
                for key in ("key", "prompt", "seed", "width", "height", "steps", "guidance_scale")
            },
        )
        for image in kept
    ]
    manifest = {
        "source": "generate",
        "block": cfg["regularization"],
        "model_key": plan["model_key"],
        "base_model": plan["base_model"],
        "caption_ext": plan["caption_ext"],
    }
    return _write_copy(run_dir, entries, manifest)


def check_folder(
    cfg: dict[str, Any], run_dir: Path, workspace: Path, *, copy: bool = True
) -> dict[str, Any]:
    """A provided set: every image has a caption and no caption holds a trigger; then copy it.

    Raises InputError (exit 2) before anything is copied. ``copy=False`` only checks.
    """
    block = cfg["regularization"]
    folder = Path(block["path"]).resolve()
    root = (workspace / "datasets").resolve()
    if not folder.is_relative_to(root) or folder == root:
        raise InputError(f"regularization.path: must resolve under {root}")
    if not folder.is_dir():
        raise InputError(f"regularization.path: {folder} is not a directory")
    dataset = Path(cfg["dataset"]["path"]).resolve()
    if folder == dataset or folder.is_relative_to(dataset) or dataset.is_relative_to(folder):
        raise InputError("regularization.path: must be a different folder from dataset.path")
    extension = cfg["dataset"]["caption_ext"].lstrip(".")
    pictures = sorted(
        (p for p in folder.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES), key=lambda p: p.name
    )
    if not pictures:
        raise InputError(f"Regularisation folder {folder.name} has no images")
    entries: list[tuple[Path, str, str, dict[str, Any]]] = []
    for picture in pictures:
        caption_file = folder / f"{picture.stem}.{extension}"
        if picture.is_symlink() or not picture.is_file() or caption_file.is_symlink():
            raise InputError(f"Regularisation image {picture.name} is not a regular file")
        try:
            caption = caption_file.read_text(encoding="utf-8")
        except OSError:
            raise InputError(f"Regularisation image {picture.name} has no caption") from None
        if not caption.strip():
            raise InputError(f"Regularisation image {picture.name} has a blank caption")
        trigger = first_trigger_in(caption, cfg["triggers"])
        if trigger is not None:
            raise InputError(
                f"Regularisation caption {caption_file.name} contains the trigger {trigger}"
            )
        entries.append((picture, picture.name, caption, {}))
    manifest = {
        "source": "folder",
        "block": block,
        "path": str(folder),
        "caption_ext": extension,
    }
    if not copy:
        return {**manifest, "images": [{"file": name} for _, name, _, _ in entries]}
    return _write_copy(run_dir, entries, manifest)


# --- command line -----------------------------------------------------------------------------


def _load_draw(run_dir: Path) -> dict[str, Any]:
    """The draw service's params as the agent wrote them, with the plan's defaults filled in."""
    cfg = json.loads((run_dir / DRAW_FILE).read_text(encoding="utf-8"))
    cfg["resolution"] = (
        [cfg["resolution"]] if isinstance(cfg["resolution"], int) else cfg["resolution"]
    )
    cfg["dataset"].setdefault("caption_ext", "txt")
    return cfg


def _workspace() -> Path:
    return Path(os.environ.get("PODAGENT_WORKSPACE") or "/workspace").expanduser()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("draw", help="draw the images of a generated set (needs the GPU)")
    command.add_argument("--run", required=True, type=Path, help="the draw run directory")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    run_dir = args.run.expanduser().resolve()
    try:
        draw(_load_draw(run_dir), run_dir, _workspace())
        return 0
    except InputError as error:
        say(str(error))
        return 2
    except (GenerationError, OSError, ValueError) as error:
        say(f"failed: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
