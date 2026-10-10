# scripts

Programs the agent runs as child processes (POD-SPEC §3, §4.3, §7). They are copied into the
image at `/opt/pod/scripts/` and must stay standalone: argparse, standard library, plus
`huggingface_hub`/`datasets`/`Pillow` (pull/push) or the trainer's own venv (launch wrappers).
They never import `podagent`, and nothing heavy is imported at module level, so
`python -I <script> --help` works from any interpreter.

| script | runs in | purpose |
| --- | --- | --- |
| `pull_dataset.py` | `/opt/venvs/agent` | Hub dataset → `/workspace/datasets/<name>`: images, `<stem>.txt` captions, `metadata.jsonl`, `manifest.json`, `job.yaml` |
| `push_lora.py` | `/opt/venvs/agent` | `/workspace/runs/<id>` → model repo: newest `.safetensors`, samples, `run.json`, `config.yaml`, generated model card |
| `launch_aitoolkit.py` | `/opt/venvs/aitoolkit` | `run.json` → ai-toolkit YAML → `run.py`; tees the log; scrapes loss into TensorBoard events (POD-SPEC §4.3) |
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

## Tests

`tests/test_pull_dataset.py` and `tests/test_push_lora.py` load the scripts by path and replace
the one object that talks to the Hub (`Hub` in each script) with a fake, so nothing reaches the
network. Imagefolder normalisation runs on a fixture tree; the datasets path runs on plain dict
rows and, when `datasets` is installed, on an in-memory `datasets.Dataset` (skipped otherwise).
Fixtures use the `NORA7` / `IVAN9` triggers only.

```sh
cd pod/agent
uv venv && uv pip install -e ".[dev]"                      # the agent venv
uv pip install huggingface_hub datasets Pillow             # or: -e ".[dev,pod]" (adds tensorboard)
.venv/bin/python -m pytest ../scripts/tests -q
.venv/bin/ruff check ../scripts && .venv/bin/ruff format --check ../scripts
```
