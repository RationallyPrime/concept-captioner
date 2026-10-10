# POD-STATUS

Tracks what of `POD-SPEC.md` exists. Updated by whoever lands a work unit; one line per unit.
Last full pass: 2026-10-10, every tree green (commands in "How the numbers were produced").

| unit | id | paths | state | notes |
| --- | --- | --- | --- | --- |
| Spec and skeleton | `arch` | `docs/POD-SPEC.md`, `agent/`, `podctl/`, `images/`, `scripts/` | done 2026-10-10 | layout, pyprojects, settings, auth, error envelope, `__main__` (exits 2 without a usable token); `agent/tests/test_health.py` 5 tests |
| GPU inventory | `gpus` | `agent/src/podagent/gpus.py`, `agent/tests/test_gpus.py` | done 2026-10-10 | `parse_nvidia_smi` on 1/2/4-GPU fixtures, CRLF, `[N/A]` uuid, malformed lines named; `NvidiaSmiBackend` runs a fixed argv with a 10 s timeout and answers `[]` + warning on missing binary / timeout / nonzero exit / bad output; `FakeBackend(n)`; 31 tests. Known limit: a GPU name containing a comma is rejected as malformed (MIG-style names) |
| Topology plan | `plan` | `agent/src/podagent/plan.py`, `agent/tests/test_plan.py` | done 2026-10-10 | the §2.5 table for 0/1/2/4 GPUs × caption/train/both, `gpu_count` override, 400 on zero GPUs or neither side, every cell of the rule asserted; 79 tests (parametrised), route tests included |
| Service catalog | `catalog` | `agent/src/podagent/catalog.py`, `agent/tests/test_catalog.py` | done 2026-10-10 | six `ServiceSpec`s; pydantic params with `extra="forbid"` plus a second workspace-path step (`validate`); argv per §3.1–3.5 element-for-element; secrets only in env, stripped from `run.json` and the fake argv, redacted by `public()`; `fake_argv`; 145 tests |
| Supervisor + fake service | `supervisor` | `agent/src/podagent/supervisor.py`, `fakeservice.py`, `agent/tests/test_supervisor.py` | done 2026-10-10 | real `podagent.fakeservice` children: start/status/logs/stop, `CUDA_VISIBLE_DEVICES` per service (`""` for 0-GPU services), check order of §2.6, double-booking refused, exit-code capture (`exited`/`failed`/`stopped`), SIGTERM → SIGKILL on the process group, log truncated per start, backwards `tail_file`, shutdown hook; 29 tests |
| Events reader | `events` | `agent/src/podagent/events.py`, `agent/tests/test_events.py` | done 2026-10-10 | minimal tfrecord + protobuf reader (`simple_value` and TF2 `tensor`), truncated/corrupt tail tolerated, newest file wins ties, `tensorboard`'s `EventAccumulator` used when importable with fallback; 34 tests, 1 of them (`test_parity_with_tensorboard_reader`) skipped when `tensorboard` is not installed, as in the dev venv |
| API wiring + tests | `api` | `agent/src/podagent/app.py`, `agent/tests/test_api.py` | done 2026-10-10 | every route of §2 over `TestClient`; bearer on every route incl. unmatched paths and non-JSON bodies (401 first, from the headers alone, before the body is read); 1 MiB body cap and chunked bodies → `413 payload_too_large`; `stop` `timeout_s` capped at 90 (proxy cutoff); every error code of §2.2 in the one envelope; topology end-to-end on 1, 2 and 4 fake GPUs incl. the explicit-`gpus` override; `/docs`, `/redoc`, `/openapi.json` off; lifespan shutdown stops children; 134 tests |
| Transfer scripts | `scripts-transfer` | `scripts/pull_dataset.py`, `scripts/push_lora.py`, `scripts/tests/test_pull_dataset.py`, `test_push_lora.py` | done 2026-10-10 (Hub mocked) | imagefolder (`metadata.jsonl`/`.csv`, flattening, collisions, `--split` by folder) and `datasets` paths, atomic `DIR.partial` swap, `manifest.json`, `job.yaml`, `--require-captions`; push: newest `.safetensors` (or all), samples, `run.json`/`config.yaml`, generated model card, `push.json`; `python -I … --help` import-free; 34 + 15 tests. Never run against the real Hub |
| Trainer wrappers | `scripts-trainers` | `scripts/launch_aitoolkit.py`, `scripts/launch_ltx.py`, `scripts/tests/test_launch_wrappers.py` | done 2026-10-10 (trainer mocked) | RunConfig validation copied from §4.1, native config per §4.3 (`--dry-run` writes it), `extra` deep-merge, tee with `\r` redraw splitting, `scraped/loss` + `scraped/lr` scraper, `push_on_finish`, exit-code propagation, LTX preprocess + resume, post-merge check that `extra` cannot point the trainer outside the workspace, tee stops the trainer when the tee itself fails; 153 tests. Every trainer key, entrypoint and flag still carries `# VERIFY` (§4.2); nothing has run against a real checkout |
| Images | `images` | `images/Dockerfile.{base,aitoolkit,ltx,fake}`, `entrypoint.sh`, `compose.fake.yaml`, `images/README.md` | written, not built | base: `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04` by digest, uv 0.12.21, CPython 3.12.14, `/opt/venvs/vllm` (vLLM 0.31.0 +cu129), `/opt/venvs/agent` (`podagent[pod]` + `concept-captioner[hf]`), scripts `--help` checked at build; aitoolkit `f7a1fb9a` (cu130), LTX-2 `9ec55f9f` (cu132) → trainer images need an R580+ driver; every pin dated in `images/README.md`. Docker is not available on the dev machine: reviewed by eye only, zero builds |
| podctl | `podctl` | `podctl/src/podctl/{cli,client}.py`, `podctl/tests/test_cli.py` | done 2026-10-10 | all eleven §8 commands, tables and `--json`, `--wait` and `--follow` loops, exit codes 0/1/2/3/130, gateway 502/503/504 → 3, `MockTransport` only; 95 tests |
| Status doc + pod README | `status-doc` | `docs/POD-STATUS.md`, `README.md` | done 2026-10-10 | this file and `pod/README.md`; spec drift staged below, `POD-SPEC.md` edit pending (see "Spec drift") |

## Foundation repair, 2026-10-10

The existing vLLM allowlist was verified against its catalog/API tests. LTX preprocess arguments
now use one stdlib validator at the API and in the isolated wrapper, rejecting path, device and
column overrides before a run is prepared or a subprocess starts. The images copy the validator
into the wrapper's source-relative layout. `podctl` classifies proxy Cloudflare 520-526 responses
without an agent error envelope as unreachable (exit 3); actual agent envelopes still exit 1.
Fake scripts: 238 passed; podctl: 113 passed; lint and formatting clean in both trees.
Agent: 557 passed, 1 skipped (TensorBoard absent), with an inherited Starlette/httpx warning;
Ruff and formatting clean. The parent independently accepted the foundation after 15 API
preprocess tests, 33 wrapper preprocessing tests, and 21 proxy tests passed. Published to main
as `52bedeea032aaa08a7923249bc06c127795f00d2` (2026-10-10).
No Docker image or real pod claim is established by this repair.

## How the numbers were produced

2026-10-10, macOS, CPython 3.13.12 in the dev venvs (the images use 3.12.14; both packages
declare `>= 3.11`). No network, no GPU, no Docker.

```bash
cd pod/agent  && uv venv && uv pip install -e ".[dev]" && pytest -q && ruff check . && ruff format --check .
#   461 passed, 1 skipped (tensorboard absent); ruff clean, 21 files formatted
cd pod/podctl && uv venv && uv pip install -e ".[dev]" && pytest -q && ruff check . && ruff format --check .
#   95 passed; ruff clean, 5 files formatted
cd pod/scripts && ../agent/.venv/bin/python -m pytest tests -q        # needs huggingface_hub, datasets, Pillow
             && ../agent/.venv/bin/ruff check . && ../agent/.venv/bin/ruff format --check .
#   202 passed; ruff clean, 8 files formatted
```

Per file: `test_api` 134, `test_catalog` 145, `test_plan` 79, `test_events` 34, `test_gpus` 31,
`test_supervisor` 29, `test_health` 5; `test_cli` 95; `test_launch_wrappers` 121,
`test_pull_dataset` 34, `test_push_lora` 15. `scripts/` has no `pyproject.toml`; it is tested and
linted from the agent venv with `huggingface_hub datasets Pillow` installed on top of `[dev]`
(or `-e ".[dev,pod]"`, which adds `tensorboard` and un-skips the parity test).

## Spec drift found during implementation (2026-10-10)

What the landed code does that `POD-SPEC.md` does not say, or says differently. None of it
contradicts the owner's rules (token required, no shell, topology, no double-booking). Each item
is written so it can be lifted into the spec section it names; the spec file is owned by the
`arch` unit and has **not** been edited yet. Until it is, this list is the contract where the two
disagree.

- **§0 layout.** `pod/README.md` (one screen: what is here, local fake run, pod creation) and a
  README per directory (`agent/`, `podctl/`, `images/`, `scripts/`) exist beside the spec.
- **§1 pod creation, §6.1 driver floor.** The base image's vLLM is the `+cu129` wheel (vLLM has
  never shipped `+cu128`; torch 2.13 is not on the cu128 index) on the CUDA 12.8 base, fine for
  any CUDA 12.x driver. Both trainer stacks are CUDA 13 upstream (ai-toolkit cu130, LTX-2
  cu132), so **the trainer images need an R580+ host driver**: the app must filter the pod's
  CUDA version to 13.0+ when creating a pod from `…-pod-aitoolkit` / `…-pod-ltx`
  (`allowedCudaVersions` in the REST v2 pod create). Add to the §1 table and the pod-creation
  paragraph.
- **§1 proxy timeout vs §2.6 `stop`.** Resolved in the spec: `timeout_s` is capped at 90
  (`StopRequest`, `podctl stop --timeout`), so a stop always answers inside the proxy's 100 s
  cutoff instead of finishing unobserved behind a `524`.
- **§2.1 body guard.** The bearer is checked by a pure-ASGI middleware (`EdgeGuard`) before
  the body is read, and bodies above 1 MiB or sent chunked are `413 payload_too_large`: with
  only the route dependency, an anonymous client on the public proxy URL could make FastAPI
  buffer arbitrarily large bodies before the 401. Added to §2.1 and the §2.2 table.
- **§2.2 errors.** Two cases the router answers before any dependency runs are folded into the
  envelope: unmatched path → `404 not_found`, wrong method → `405` with code `bad_request` and
  an `Allow` header; both answer `401` first when the bearer is missing, as does a body that is
  not JSON (`400 bad_request` once authenticated). `invalid_params` detail is pydantic's
  `errors()` with any secret `input` replaced by `"***"`. A spawn failure (binary missing) is
  `500` with code `internal` but a specific message (`could not spawn <name>: …`) and files the
  service as `failed`; the generic-message rule applies to unexpected exceptions only. The
  OpenAPI routes (`/docs`, `/redoc`, `/openapi.json`) are disabled.
- **§2.6 start.** `gpus` must be distinct indices (`422 gpu_count` otherwise). `prepare()` for
  the trainers also creates `<run>/tensorboard/` and writes `run.json` atomically
  (`run.json.tmp` + rename). `started_at`/`ended_at` are ISO 8601 with microseconds.
- **§3 fake mode.** Extra knobs, all optional: `PODAGENT_FAKE_TRANSFER_S` (seconds the fake
  `pull-dataset`/`push-lora` take; default 2), `PODAGENT_FAKE_HOST` (bind address of the fake
  vLLM/TensorBoard responder; default `127.0.0.1`), and failure switches for tests (`extra:
  {"fail": true}`, `extra_args: ["--fail"]`, `ignore_sigterm`). The fake vLLM answers
  `/v1/models` with vLLM-shaped JSON so a readiness poll works.
- **§3.1–3.5, §4.1 validation bounds not in the spec.** `model`/`base_model`: a Hub id
  (`owner/name` or bare `name`, no `.`/`..` segments) or an absolute path that must resolve
  under `<workspace>/models/`; `served_model_name`, `split`, `revision`, `profile`: one printable
  token, no whitespace, not starting with `-`; `commit_message`: non-blank, not starting with
  `-`; `caption_ext` `^[A-Za-z0-9]{1,16}$`; `learning_rate` in (0, 1]; each `resolution` in
  [64, 8192]; `steps`, `rank`, `batch_size`, `gradient_accumulation`, `save_every` ≥ 1;
  `sample_every`, `seed` ≥ 0; `triggers` and `sample_prompts` non-blank; `pull-dataset.name`
  defaults to the repo name and is an error when that name does not match the run-id pattern.
- **§4.3 `launch_aitoolkit.py`.** Adds to the mapping: `model.arch` (`flux` or `h3`, chosen
  from the base-model id; VERIFY), `model.is_flux` kept for older checkouts, `process[0].log_dir
  = <run>/tensorboard` (native TensorBoard logging; VERIFY), `device: cuda:0`,
  `save.push_to_hub: false`; sampling is disabled when `sample_prompts` is empty or
  `sample_every` is 0. `extra` keys `job`/`config`/`meta` merge at the document root, everything
  else into `process[0]`. `--dry-run` writes `config.yaml` and exits 0. Resume: an existing
  `output/` is left alone (ai-toolkit resumes from its newest checkpoint on its own; VERIFY).
  Env: `AI_TOOLKIT_DIR` (default `/opt/ai-toolkit`), `POD_AGENT_PYTHON` (interpreter for the
  finishing `push_lora.py`; default `/opt/venvs/agent/bin/python`). Exit code: the trainer's,
  or the push's when the trainer succeeded and the push did not.
- **§4.3 `launch_ltx.py`.** Writes `<run>/dataset.json` (`caption`, `media_path`; media without
  a sidecar caption is skipped and counted); preprocessing is skipped when `preprocessed/` is
  already populated unless `--reprocess`; `extra.preprocess` (`resolution_buckets`, `args`) is
  consumed by the wrapper, not passed to the trainer. Config adds `model.training_mode: lora`,
  `validation.video_dims = [max, max, 1]`, and `model.load_checkpoint` = the newest
  `output/*.safetensors` when one exists (resume semantics VERIFY). Env: `LTX_TRAINER_DIR`
  (default `/opt/ltx-2`), `LTX_PREPROCESS_SCRIPT`, `LTX_TRAIN_SCRIPT`, `POD_AGENT_PYTHON`.
  The trainer entrypoints the image checks for are
  `packages/ltx-trainer/scripts/{process_dataset,train}.py`.
- **§4.3 log scraper, both wrappers.** `\r`-separated progress redraws are written as separate
  lines so `logs` stays line-based. Scalars go to `<run>/tensorboard/` with filename suffix
  `.scraped`; when `torch.utils.tensorboard` is not importable the scraper is skipped with one
  log line, not an error. That import needs the `tensorboard` package inside the **trainer**
  venv (VERIFY for both images; if absent, `/runs/{id}/events` is empty unless the trainer logs
  natively).
- **§6.1 images.** All three CUDA Dockerfiles take the repository root as build context
  (`-f pod/images/Dockerfile.base .`); the agent venv is `podagent[pod]` (a new extra in
  `agent/pyproject.toml`: tensorboard, huggingface_hub, datasets, Pillow) plus
  `concept-captioner[hf]`, both non-editable from `/opt/src/`; CPython is uv-managed 3.12.14
  under `/opt/python` (`POD_PYTHON` env for the trainer images); each venv writes
  `freeze.txt`; build args `VLLM_VERSION`, `AI_TOOLKIT_COMMIT`, `LTX2_COMMIT`, the torch
  versions, `FLASHINFER_JIT_CACHE_VERSION` (`""` skips the kernel cache) and
  `CUDA_JIT_TOOLCHAIN=1` (adds `nvcc` 12.9). The LTX-2 venv is a uv workspace sync
  (`uv lock` + `uv sync --all-packages --all-extras --no-dev`), lock kept at
  `/opt/ltx-2/uv.lock`. `nvidia-smi` comes from the container runtime
  (`NVIDIA_DRIVER_CAPABILITIES=compute,utility`), not the image. No `.dockerignore` at the
  repo root yet (`images/README.md` has the suggested content).
- **§6.2 entrypoint.** Honours `PODAGENT_WORKSPACE` and a pre-set `HF_HOME`.
- **§6.3 compose.** Build context is `../..` (the repo root) with
  `dockerfile: pod/images/Dockerfile.fake`, not `..`: `Dockerfile.fake` copies `pod/agent`,
  `pod/images/entrypoint.sh` and `pod/scripts/`. It installs `podagent` without `[pod]` and
  symlinks `/opt/venvs/agent/bin/python` to the system interpreter so the entrypoint's path
  works; it is a fake-mode agent only, never a stand-in for the CUDA images. The compose file
  publishes `8000` and `6006` beside `8800` and sets `PODAGENT_FAKE_HOST=0.0.0.0`: the fake
  responders default to `127.0.0.1`, which inside the container is unreachable through a
  published port, so the app's vLLM readiness poll and TensorBoard link could not be exercised
  against the compose stack without it. `tests/test_compose_fake.py` pins that contract.
- **§7.1 `pull_dataset.py`.** `metadata.csv` is accepted beside `metadata.jsonl`; images the
  metadata does not list are copied too, with a `<stem>.txt` sidecar from the repo as caption
  when present (the metadata field wins); `--split` selects among metadata files in different
  folders; `--caption-column` is read before `caption`/`text`; a `<caption-column>_response`
  column (what `HFDatasetSink` writes) lands as `<stem>.json`; `metadata.jsonl` carries
  `caption: null` for uncaptioned images; `manifest.json` also has `requested_revision`,
  `split`, `image_column`, `caption_column`, `id_column`, `pulled_at`, and `revision` is the
  resolved sha the snapshot and `load_dataset` were pinned to. DIR is replaced atomically
  (`DIR.partial` → `DIR`, old `DIR` removed); with `--require-captions` the folder is still
  swapped in before exit 1. Token also from `HUGGINGFACE_HUB_TOKEN`.
- **§7.2 `push_lora.py`.** `*/samples/*` is uploaded as well as `samples/*` (ai-toolkit writes
  `output/<name>/samples/`); `preprocessed/` and dot-folders are never searched for weights;
  the model card overwrites `<run>/README.md` and the repo's README on every push and reads
  the dataset's `manifest.json`/`job.yaml` for dataset name, sha and profile; `<run>/push.json`
  records `repo_id`, `url`, `commit`, `run_id`, `files`, `pushed_at`; files keep their
  run-relative paths in the repo.
- **§8 podctl.** `--follow` reads the service state before every fetch and ends on its own
  after the last fetch once the service is not `running`; a window that moved by more than
  `--tail` lines is noted on stderr. `train` also takes `--wait`; a `--wait` that ends in
  `failed` exits 1. `caption-up` takes `--params`/`--params-file` merged under `model`;
  `--params-file -` and `--config -` read stdin. Exit 130 on Ctrl-C; a 502/503/504 that is
  not the agent's envelope (the proxy while the pod boots) is exit 3. `--gpus` rejects
  duplicates. `--json` prints one document per line (two for `--wait`, one per poll with new
  lines for `--follow`); errors and notes go to stderr.
- **§9 testing.** Also covered: `__main__` (exit 2 without a token; serving the configured
  app), the lifespan shutdown hook, 404/405 envelopes, `--help` of every script under
  `python -I`, and the scripts themselves (wrappers with the trainer spawn mocked, pull/push
  with a fake `Hub` object). The `tensorboard` reader parity test runs only when the package is
  installed.

## Verified on a real pod

Nothing yet. No image has been built, no pod created, no trainer or vLLM started outside fake
mode. When it happens, record the pod id, image tag and outcome here, and close the items below.

What to check, in one place (details in `images/README.md` "What to verify on a real pod" and
POD-SPEC §4.2):

1. The three builds succeed as written (vLLM `+cu129` wheel + four `+cu129` torch pins;
   `flashinfer-jit-cache` from flashinfer.ai is real; the LTX-2 workspace sync picks up the
   `natten` extra).
2. Driver floor: base serves vLLM on an R570-class host; both trainer venvs see the GPU on
   R580+.
3. vLLM captions one image without a JIT compile; `torchcodec` imports against jammy's FFmpeg.
4. `RUNPOD_POD_ID` / `RUNPOD_PUBLIC_IP` are the env names the pod exposes (`/health` copies
   them; nothing depends on them).
5. ai-toolkit: `run.py` trains a few FLUX steps from the wrapper's `config.yaml`; the H3
   `arch`/quantization keys, `trigger_word`, `log_dir`, and resume-from-`output/`.
6. LTX-2: `process_dataset.py` and `train.py` accept the wrapper's arguments and keys; where
   checkpoints land; `load_checkpoint` resume semantics; VRAM per config.
7. `tensorboard` is importable from `/opt/venvs/aitoolkit/bin/python` and
   `/opt/venvs/ltx/bin/python` (else the log scraper is a no-op).
8. `push_on_finish` reaches `push_lora.py` through `/opt/venvs/agent/bin/python` and lands a
   model repo; `pull_dataset.py` against a real imagefolder repo and a real parquet repo.
9. PID 1 behaviour: the agent runs under `tini -s`; after killing a vLLM API-server process by
   hand the engine workers must be reaped (not `Z` in `ps`) and `/services/vllm` must go from
   `failed` + `group_alive: true` to `group_alive: false` with GPU 0 free. `stop` with
   `timeout_s` near the proxy's 100 s cutoff; a child that survives SIGKILL (Xid fault) is filed
   `stuck` after `SIGKILL_WAIT_S` (3 s).
10. Image sizes and pull time on RunPod.
