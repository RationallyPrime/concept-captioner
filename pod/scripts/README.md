# scripts

Programs the agent runs as child processes (POD-SPEC §3, §4.3, §7). They are copied into the
image at `/opt/pod/scripts/` and must stay standalone: argparse, standard library, plus
`huggingface_hub`/`datasets`/`Pillow` (pull/push) or the trainer's own venv (launch wrappers).
They never import `podagent`, and nothing heavy is imported at module level, so
`python -I <script> --help` works from any interpreter. One exception to "standalone":
`launch_ltx.py` reads the LTX rules it shares with the agent (preprocess allowlist, pinned
LTX-2 Hub revision) from `../agent/src/podagent/ltx_rules.py` at import, by path with runpy.
The image recreates that layout under `/opt/pod`, and the build's `--help` check fails if the
copy is missing. H3 helpers read the single native/pod recipe field-and-asset JSON
resource, copied beside scripts; they also remain stdlib-only at import. `model_table.py`
reads the model table (`/opt/pod/scripts/model-table.json` in an image, the app's file in a
checkout); see "The model table" below.

| script | runs in | purpose |
| --- | --- | --- |
| `pull_dataset.py` | `/opt/venvs/agent` | Hub dataset → `/workspace/datasets/<name>`: images, `<stem>.txt` captions, `metadata.jsonl`, `manifest.json`, `job.yaml` |
| `push_lora.py` | `/opt/venvs/agent` | `/workspace/runs/<id>` → model repo: newest `.safetensors` (not the trainers' caches), samples, `run.json`, `config.yaml`, generated model card |
| `model_table.py` | stdlib | the model table (`model-table.json`): which models exist and what each needs; lookups and hook registry |
| `launch_aitoolkit.py` | `/opt/venvs/aitoolkit` | `run.json` → ai-toolkit YAML → `run.py` for the AI Toolkit models in the table; effective native snapshot, log tee and loss scraper |
| `h3_recipe.py`, `h3_dataset.py` | stdlib admission, then AI Toolkit | canonical H3 quality/initializer contracts, fixed pinned BF16 asset download, exact approved clip grouping |
| `generate_results.py` | selected trainer venv | actual matched base/LoRA inference for each model whose table row names a generator; incremental manifest and private checkpoint cleanup |
| `regularization.py` | `/opt/venvs/aitoolkit` (the `draw-regularization` service runs `draw`; the launcher loads the module) | the regularisation set of an AI Toolkit run: class-only prompts from the subject captions, the drawn pictures in the shared cache `/workspace/regsets`, the run's copy with the app's captions, or a provided folder checked for triggers |
| `launch_ltx.py` | `/opt/venvs/ltx` | `run.json` → preprocess + LTX-2 trainer config → train; same tee and scraper (POD-SPEC §4.3) |

`docs/POD-STATUS.md` says which of these are implemented. The agent builds each argv from the
service catalog (`podagent.catalog`); the flags below are that contract.

## `pull_dataset.py` (POD-SPEC §7.1)

```
pull_dataset.py --repo OWNER/NAME --to DIR [--split train] [--revision R]
                [--image-column image] [--caption-column caption] [--id-column C]
                [--job-path concept-captioner/job.yaml] [--require-captions]
```

Token from `HF_TOKEN` (or `HUGGINGFACE_HUB_TOKEN`). The convention is detected from the repo's
file list:

- **imagefolder** — image files (`.png .jpg .jpeg .webp`, either case) plus `metadata.jsonl`
  (`file_name` and `caption` or `text`; `metadata.csv` is accepted too), or image files with no
  parquet/arrow data at all. The repo is snapshotted into the HF cache (`HF_HOME`, which the agent
  points at `/workspace/models/hf-cache`) and the images are copied into DIR **flat**:
  `file_name` relative to its metadata file with `/` replaced by `__` (`sub/b.jpg` → `sub__b.jpg`).
  Images the metadata does not list are copied too; their caption is a `<stem>.txt` sidecar
  next to the image in the repo, when there is one (the caption field wins when both exist).
  `--caption-column` names the field to read first, then `caption`, then `text`. With several
  metadata files in different folders (`data/train/`, `data/test/`), `--split` keeps the folders
  whose path contains it; otherwise all are used. Two images landing on the same name, or the
  same stem (`a.png` + `a.jpg`), is an error, as is a listed file that is missing or not an image.
- **datasets** — anything else (parquet, arrow, a loading script): `datasets.load_dataset(repo,
  split, revision)`. The sample id follows `concept_captioner.sources.hf._sample_id`
  (`--id-column`, else `file_name`/`filename`/`image_id`/`id`/`name`, else the row index; the rule
  is copied, not imported). Bytes are written untouched with their original suffix — from the
  stored path, else sniffed from the bytes, else `.png`. The caption is `--caption-column` when the
  column exists and the value is non-empty; a `<caption-column>_response` column (what
  `HFDatasetSink` writes) is saved as the `<stem>.json` response record.

Always written in DIR:

- `<stem>.txt` for every captioned image — the stripped caption, no trailing newline, exactly as
  `SidecarSink` writes it; `<stem>.json` when a response record came with the row;
- `metadata.jsonl`, one `{"file_name": ..., "caption": ...}` per image in dataset order,
  `caption` `null` when there is none, so DIR is itself a valid imagefolder;
- `manifest.json`: `repo_id`, `revision` (the resolved commit sha; the requested value when the
  Hub gives none), `requested_revision`, `split`, `convention`, `image_column`, `caption_column`,
  `id_column`, `count`, `with_caption`, `without_caption`, `job_yaml` (`"job.yaml"` or `null`),
  `pulled_at`;
- `job.yaml`, when the repo has the file at `--job-path`, so the launch wrappers and the model card
  can read triggers and profile.

DIR is replaced atomically: everything lands in `DIR.partial`, then `DIR` is renamed to `DIR.old`,
`DIR.partial` to `DIR`, and `DIR.old` deleted. A failed pull leaves the previous dataset exactly as
it was and a re-pull never keeps stale images. The snapshot and the dataset load are pinned to the
resolved sha so the file list and the data cannot drift between calls.

Exit codes: `0` success; `1` with one line on stderr for any error (unreadable repo, broken
metadata, collisions) and, with `--require-captions`, when any image has no caption — in that
case DIR is still swapped in so the client can see which ones (the counts are in
`manifest.json`). Without the flag the counts tell the client.

## `push_lora.py` (POD-SPEC §7.2)

```
push_lora.py --run-dir /workspace/runs/<id> --repo OWNER/NAME [--private] [--no-samples]
             [--all-checkpoints] [--commit-message M]
```

Creates the model repo when missing (`create_repo(exist_ok=True)`; `--private` applies to that
creation), then one `upload_folder` of the run directory with these allow-patterns:

- the newest `*.safetensors` under the run dir by mtime (`preprocessed/` and dot-folders are not
  searched, so LTX latents and caches never count), or every one with `--all-checkpoints`. None
  found → exit `1` before anything touches the Hub;
- `run.json` and `config.yaml` when present;
- `samples/*` and `*/samples/*` (the run's `samples/` and ai-toolkit's `output/<name>/samples/`)
  unless `--no-samples`;
- `README.md`: a model card generated from `run.json` — `base_model` and `instance_prompt`
  (the first trigger) in the front matter, a table with base model, triggers, steps, rank/alpha,
  learning rate, resolution, caption profile (from `run.json`, else `profile:` in the dataset's
  `job.yaml`), dataset name (plus `repo_id @ sha` and counts from the dataset's `manifest.json`
  when readable), the installed `concept-captioner` version, the weight paths, sample prompts.
  It overwrites `<run>/README.md` and the repo's README on every push.

Files keep their run-relative paths in the repo (`output/<name>/<name>.safetensors`); the card
lists them. On success the repo URL is printed last and `<run>/push.json` records `repo_id`,
`url`, `commit`, `run_id`, `files`, `pushed_at`. Token from `HF_TOKEN`.

## `regularization.py` and REPA (POD-SPEC §4.3, §7.5)

```
regularization.py draw --run DIR
```

A generated set is made in two steps. `draw` is the `draw-regularization` service: it plans the
prompts, sizes and keys (the log says `regularisation: N planned, C cached, G to generate`), draws
what `/workspace/regsets/<model-key>/` lacks through `generate_results.render_base`, and copies the
pictures to `<run>/output/<key>.png` for the app, which captions them and starts the run with
`regularization.captions`. When run.json has a `regularization` block, `launch_aitoolkit.py` plans
again and `materialize`s each captioned picture into `<run>/regularization/` (+
`<run>/regularization.json`) before the trainer starts; a `folder` set is `check_folder` instead.
`--dry-run` plans and checks only. Exit codes: 0 done, 2 bad input (a trigger in a caption, no
caption, no prompt derivable, an unsupported model), 1 drawing or copying failed.

The launcher maps run.json's `regularization.weight` to `train.reg_weight`, appends the second
dataset (`is_reg: true`, a copy of the first) and writes run.json's `repa` object as ai-toolkit's
`process.repa`. REPA itself is in the patched trainer image (`pod/images/patches/ai-toolkit/`); the
launcher only logs where the encoder weights come from.

## Launch wrappers: exit codes (POD-SPEC §4.3)

`launch_aitoolkit.py --config <run>/run.json` and `launch_ltx.py --config <run>/run.json`
(`--dry-run` writes the native config and stops; `--reprocess` forces LTX preprocessing).

| code | meaning |
| --- | --- |
| `0` | the trainer finished (and, with `hub.push_on_finish`, the push landed); with `--dry-run`, the config was written |
| `2` | invalid run config, or `extra` tried to leave the workspace; one line says why, nothing is written |
| `69` | `launch_ltx.py` only: preparing `base_model: Lightricks/LTX-2` from the Hub failed (unreachable, gated, licence not accepted, disk full). The line names the exception, the HTTP status when there is one, and its message. Nothing is written to the run directory, so a retry starts clean |
| other | the preprocessor's (LTX), the trainer's or `push_lora.py`'s own code; a signal-killed trainer is `128 + signal` |

`69` is sysexits' `EX_UNAVAILABLE`, chosen because no trainer or Python itself exits with it.
The LTX download is pinned to `LTX_HUB_REVISION` in `ltx_rules.py`; changing it is a reviewed
edit, never the Hub repo's moving `main`.

## Tests

`tests/test_pull_dataset.py` and `tests/test_push_lora.py` load the scripts by path and replace
the one object that talks to the Hub (`Hub` in each script) with a fake, so nothing reaches the
network. Imagefolder normalisation runs on a fixture tree; the datasets path runs on plain dict
rows and, when `datasets` is installed, on an in-memory `datasets.Dataset` (skipped otherwise).
Fixtures use the `NORA7` / `IVAN9` triggers only.

```sh
cd pod/agent && uv sync --extra pod                         # the agent venv
cd ../scripts
../agent/.venv/bin/python -m pytest tests -q
ruff check . && ruff format --check . && ty check            # ty.toml: tests excluded
```

## The model table

`app/Sources/ConceptStudio/Resources/Training/model-table.json` is the one list of supported
models, and `model_table.py` is how the scripts read it; `docs/model-table.md` is the format and
the checklist for adding a model. Both images `COPY` the file to `/opt/pod/scripts/model-table.json`,
and `model_table.py` reads that path when it exists, else the file in the checkout it sits in. The
wrappers run under `python -I`, so they load `model_table.py` with `runpy` as they load the H3
helpers.

Three lookups: the **exact row** (`model_ref` equals `base_model`, on the script's trainer), the
**effective row** (the exact row, else the trainer's default) and, for the AI Toolkit `model`
block only, a **family match** that keeps custom paths such as `/workspace/models/MiniMax-H3`
working. What each script reads:

- `launch_aitoolkit.py`: `model_block` is `model_table.aitoolkit_model_block` (exact row, else
  family match, else `name_or_path` only). `build_native_config` writes an exact row's
  `train.dtype`, `train.gradient_checkpointing`, `train.optimizer`, `save.dtype`,
  `save.max_step_saves_to_keep` and every dataset's `caption_dropout_rate`, then its
  `trainer_options.process` keys, over the skeleton; run.json's trainer settings (POD-SPEC 4.1)
  follow, then `extra` merges (run.json `extra` wins), unless the row names a
  `trainer_config` hook (H3's whole recipe, `minimax_h3_trainer_config`, and its asset download
  before launch).
- `generate_results.py`: the exact row must name a `generator` hook (`aitoolkit_image` is
  `flux_generate`, reading the row's model settings; `aitoolkit_arch_image` is `arch_generate`, for a
  model AI Toolkit registers as its own class, built from the saved native config; `ltx_one_stage`;
  `minimax_h3`), else
  `Generation supports <display names>`. Frame count and rate are checked against the row's
  `video` law and fixed cadence before any model loads.
- `regularization.py` and `launch_aitoolkit.py`: a row's `regularization` and `repa` fields only
  admit run.json's blocks of the same names; the values a run uses are run.json's, copied by the app
  from the row. `generate_results.render_base` draws a set with the exact row's model settings.
- `push_lora.py`: the model card adds the row's licence only when `license.show_notice`, and the row's
  `usage_note` (when it has one) to its `## Use` section.

A model the generic mapping can express is a new row and no code. Hooks are the
only place a model's name appears in code; `model_table.HOOKS` registers them.

## H3 training, initialization and comparison

`Comfy-Org/MiniMax-H3` uses the pinned `minimax_h3` registration, BF16 DiT/Qwen encoder,
frozen image-training adapter and AdamW quality defaults. Component filenames and canonical
quality fields have one source: `app/Sources/ConceptStudio/Resources/Training/h3-recipe-fields.json`.
Both base and fake images copy it to `/opt/pod/scripts/h3-recipe-fields.json`. The four binary
assets are revision-pinned in `h3_recipe.py`; original tokenizer/processor/config resolution
is the pinned upstream model's `MiniMaxAI/MiniMax-H3` path. No model is assumed present at an
old pod path. No global first trigger is injected; saved per-example captions retain their
mapped concepts.

Before model download, `h3_dataset.py` admits complete 24 fps CFR clips, 17n+5 frames from
5 to 243, positive dimensions divisible by 32, and area covered by the training cap squared.
Each private dataset view sets its exact frame count; mixed stills remain separate one-frame
buckets. The source files/audio are unchanged. `h3-inputs.json` records the target facts and
`native-config.json` records actual model/network/train/dataset settings. Image resolution
arrays stay image-resolution arrays; they are never mistaken for width/height. Unsupported
count/cadence/cap combinations refuse before download, rather than trim, crop or retime.

A new external warm start uploads only fixed `initial-lora.safetensors` + canonical
`initial-recipe.json` into a separate confined stage, with the ordinary 2 GiB/file and
20 GiB/stage limits. `initialization: {name,lora_sha256,recipe_sha256}` binds the files; the
agent validates actual Comfy/native H3 PEFT A/B headers/rank, captures them privately in a
NEW run and never installs them as media. `network.pretrained_lora_path` loads those weights
at fresh step 0. Saved same-run Resume retains initializer provenance and uses private files
without its upload stage, restoring its own newer checkpoint's step/state.

H3 generation uses the saved effective model + trained network recipe and selected private
checkpoint snapshot. It attaches an actual pinned `LoRASpecialNetwork` (including rank,
alpha and target selection), relies on upstream Comfy A/B conversion, disables merging, and
uses multiplier 0/1 for matched arms. The frozen training assistant is omitted from BOTH
arms. H3 stills produce PNG; 17n+5 video requests produce MP4 at exactly 24 fps, regardless
of whether training inputs were stills or clips. The exported manifest omits private native
paths. Normal success/errors/SIGTERM clean the selected private checkpoint; forced killing
cannot promise `finally` execution. Every pair must exist before `state: complete`.

This source path has offline/fake-runtime checks only; see POD-STATUS for the separate image,
hosted H3 training/Resume/generation and capacity acceptance gaps.
