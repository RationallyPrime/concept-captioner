# images

Current public release: `ghcr.io/rationallyprime/concept-captioner-pod-{base,aitoolkit,ltx}:v0.3.0-20261014`,
a **clean build from commit `f784947`** (`model-table`, merged as PR #10: the model table and the Z-Image and
Qwen-Image-2.1 rows): the three Dockerfiles as committed, built on cx53 with `docker buildx build` and no
overlay. The previous release, `v0.2.3-clean-20261011` (from `b7908618`; base `d41b8287…`, aitoolkit `fe09109d…`,
ltx `40a0361f…`), stays published. The images carry no OCI revision label; this table is the record of
which commit they came from.

| image suffix | public manifest digest |
| --- | --- |
| `base` | `sha256:eab5ddb98ad490a95fe8826a7d48e819cb3a57fdd50ff6c258eafcfec4b60302` |
| `aitoolkit` | `sha256:afe466d1b75e8a4398eb8dc099fcb96d591729d757db4d436a2ab483aa272966` |
| `ltx` | `sha256:41a7420463c8bfa7a97d199f3c91ee2d46895cb71a33bd7e57744f6067b2c7d5` |

Checked after the push: each tag resolves anonymously on GHCR to the digest above. The CPU
control smoke described next has not been rerun for this tag; it ran against the pushed `v0.2.3` base image and passed (receipt
`cx53:~/work/cc-clean3-logs/smoke.out`). The paragraph below records the same checks for
`v0.2.2`, including its anonymous pulls by digest. The base build ran
`check_vllm_flags.py` (23 flags found, build passed). The CPU control smoke ran against the
pushed base image: authentication (401 without the bearer), service catalog,
TensorBoard session and its cookie scope, run files with a range read, and planning with two
fake GPUs all passed. The LTX image has TensorBoard 2.21.0, LTX-2 at `9ec55f9f` and
`LTX_HUB_REVISION` `dfcc2108383fe1aaa0584bdf55d368a4bdadd90c`. No real-pod run has used these
images yet; that is the owner's training run. Receipts are on cx53 under
`/home/hive/work/cc-clean2-logs` (the `v0.2.1-clean-20261011` receipts stay under `cc-clean-logs`). Docker is not installed on the Mac; this x86 build host
produces the images.

The previous release, `v0.2.0-overnight20261011-r2` (base `sha256:65e6b5ec…7551e`, aitoolkit
`sha256:e7a84abe…31337`, ltx `sha256:e236160a…1ba66`), stays published and is what every real-pod
run so far used. It was not a clean build: runtime images were built from `017d79f`, and two
source files (the constant-frame-rate gate from `b1d0bef` and the selected-checkpoint custody
repair from `98708207`) were overlaid by exact source hashes onto those layers. The overlay
recipes were never committed. Current actual CUDA checks and historical tiny trainer receipts
are distinguished in [POD-STATUS](../docs/POD-STATUS.md).

| file | purpose |
| --- | --- |
| `Dockerfile.base` | CUDA 12.8 runtime + CPython 3.12 + uv; `/opt/venvs/vllm` (vLLM and its torch), `/opt/venvs/agent` (podagent[pod], concept-captioner[hf], tensorboard, huggingface_hub, datasets, Pillow); `/opt/pod/scripts/*.py` plus `model-table.json` (the model table) and `ltx_rules.py`; entrypoint. The build fails if a flag in the agent's vLLM allowlist is absent from the installed vLLM (`check_vllm_flags.py`) |
| `Dockerfile.aitoolkit` | base + `ostris/ai-toolkit` at a pinned commit in `/opt/ai-toolkit`, venv `/opt/venvs/aitoolkit` with upstream's own torch/flash-attn/NATTEN stack |
| `Dockerfile.ltx` | base + `Lightricks/LTX-2` at a pinned commit in `/opt/ltx-2` (uv workspace), venv `/opt/venvs/ltx` plus TensorBoard 2.21.0 (pinned, with an event write/read check) |
| `Dockerfile.fake` | `python:3.12-slim` + podagent only, for `compose.fake.yaml` (no CUDA, no trainers) |
| `entrypoint.sh` | creates `/workspace/{datasets,runs,models/hf-cache,logs}`, exports `HF_HOME`, execs `tini -s -- python -m podagent --host 0.0.0.0 --port 8800`; nothing else |
| `compose.fake.yaml` | local fake-GPU agent: `PODAGENT_FAKE_GPUS=2`, `PODAGENT_FAKE_HOST=0.0.0.0`, bind mount `./workspace:/workspace`, ports 8800 (agent), 8000 (fake vLLM); fake TensorBoard stays on loopback |

## Layout inside an image

```
/opt/python/cpython-3.12.14-…/      one managed interpreter, shared by every venv
/opt/venvs/agent/                   podagent + concept-captioner; no torch       (freeze.txt = what landed)
/opt/venvs/vllm/                    vllm 0.31.0+cu129, torch 2.13.0+cu129       (freeze.txt)
/opt/venvs/aitoolkit/               ai-toolkit stack, torch 2.13.0+cu130        (aitoolkit image; freeze.txt)
/opt/venvs/ltx/                     LTX-2 workspace, torch 2.13.0+cu132         (ltx image; freeze.txt)
/opt/ai-toolkit/  /opt/ltx-2/       the trainers' checkouts (ltx-2 also holds the uv.lock the build resolved)
/opt/src/{concept-captioner,podagent}  the sources the agent venv was installed from (record only)
/opt/pod/scripts/*.py               pull_dataset.py, push_lora.py, launch_aitoolkit.py, launch_ltx.py, generate_results.py, model_table.py
/opt/pod/scripts/model-table.json    the model table (copied from app/Sources/ConceptStudio/Resources/Training/)
/opt/pod/entrypoint.sh
/workspace                          the network volume (POD-SPEC §6.4); nothing of value lives elsewhere
```

Separate venvs per workload so vLLM's and each trainer's torch never collide (POD-SPEC §6.1). The
agent runs services by absolute path (`/opt/venvs/<name>/bin/…`), so no venv is on `PATH`. The
build context is the repository root (`-f pod/images/Dockerfile.base .`) because the base image
installs `concept-captioner` from `src/` and `podagent` from `pod/agent/`; the trainer images copy
nothing from the context.

## Pins

Every pin was read from its source on 2026-10-10. `date` is when upstream published it.

| what | pin | date | why this one |
| --- | --- | --- | --- |
| base image | `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04@sha256:17e2934e…1202bb` (manifest list; amd64 image `sha256:59e0e437…5010`) | 2025-03-13 | the tag the spec names, by digest. Runtime, not devel: the venvs bring their own CUDA libraries through pip, the system CUDA serves `nvidia-smi` and the optional JIT toolchain |
| uv | `ghcr.io/astral-sh/uv:0.12.21` | 2026-09-29 | more than a week old at pin time; its bundled interpreter registry lists 3.12.14 (checked in `crates/uv-python/download-metadata.json` at that tag) |
| CPython | `3.12.14` (python-build-standalone, via `uv python install`) | — | the newest 3.12 that uv 0.12.21 can install; 3.12.15 was released 2026-09-30, after that uv's registry was cut |
| vLLM | `0.31.0` **`+cu129`** wheel from the GitHub release | 2026-10-05 | the newest release; see "CUDA and drivers" for why cu129 and not cu128 |
| torch for vLLM | `torch==2.13.0+cu129`, `torchvision==0.28.0+cu129`, `torchaudio==2.11.0+cu129`, `torchcodec==0.15.0+cu129` | 2026-07-08 | exactly what the vllm wheel requires (`torch==2.13.0`, `torchvision==0.28.0`, `torchaudio==2.11.0`, `torchcodec>=0.14`), from the cu129 index |
| FlashInfer kernel cache | `flashinfer-jit-cache==0.7.0.post1` from `https://flashinfer.ai/whl/cu129` | — | the FlashInfer version vllm 0.31.0 pins (`flashinfer-python==0.7.0.post1`, and `FLASHINFER_VERSION` in its `docker/Dockerfile`) and the install vLLM's own image performs so FlashInfer needs no `nvcc` for its shipped kernels; optional (`FLASHINFER_JIT_CACHE_VERSION=""` skips it) |
| ai-toolkit | `ostris/ai-toolkit@f7a1fb9a77e5418269b1e9eda4ace6d7c1b7bb47` ("Version bump") | 2026-10-10 | the release commit at the top of `main` at pin time |
| ai-toolkit torch | `torch==2.13.0+cu130`, `torchvision==0.28.0+cu130`, `torchaudio==2.11.0+cu130`, `torchcodec==0.15.0+cu130` | 2026-07-08 (torch) | copied from that commit's `docker/Dockerfile` and `manager/spec.py` (upstream's "linux cu130" spec). cu126 is upstream's only other prebuilt stack and has no Blackwell kernels |
| ai-toolkit extras | `requirements.txt` at the commit (diffusers at `c9438378…`, transformers 5.5.3, peft 0.18.1, …), then `setuptools==69.5.1`, `natten==0.21.7+torch2130cu130` (whl.natten.org), `flash_attn 2.8.3+cu130torch2.13` cp312 (mjun0812/flash-attention-prebuild-wheels v0.9.47) | — | the same files and the same order as upstream's Dockerfile |
| LTX-2 | `Lightricks/LTX-2@9ec55f9f22798a3198d9c923856824821bc3317e` ("Automated PR - 2026-10-02"; packages 1.4.2) | 2026-10-02 | the top of `main` at pin time; `packages/ltx-trainer/scripts/{process_dataset,train}.py` both exist there |
| LTX-2 torch | `torch==2.13.0+cu132` + `natten==0.21.7+torch2130cu132` via ltx-core's `natten` extra; everything else resolved by `uv lock` at build time inside the bounds the packages declare | — | upstream's README installs `uv sync --extra natten`; the extra is the only exact torch pin in the workspace, so the build asserts it landed. The resolved lock is kept at `/opt/ltx-2/uv.lock` |

apt packages (`git curl ca-certificates build-essential ffmpeg libgl1 libglib2.0-0`) are not
version-pinned on purpose: Ubuntu's archive keeps only the current security build, so an exact pin
breaks at the next security update. The base digest pins the layer beneath them.

To bump a pin: `curl -s https://pypi.org/pypi/vllm/json | jq .info.version` and the release's
asset list on GitHub for vLLM (look for the `+cu129` wheel), `git ls-remote <repo> HEAD` for the
trainers (then re-read their `requirements`/`pyproject` for the torch stack and copy it), Docker
Hub's tag page for the CUDA digest, `uv python list --all-versions` for the interpreter.

## CUDA and drivers

The contract says "vLLM with its cu128 torch". That no longer exists upstream: vLLM has never
published a `+cu128` wheel (its CUDA 12 variant has been `+cu129` since 0.20, with CUDA 13 as the
PyPI default since torch 2.13), and torch 2.13 is not on the cu128 index. The closest faithful
choice is the `+cu129` build on the CUDA 12.8 base: pip-installed CUDA libraries do not care what
`/usr/local/cuda` is, only the host driver matters, and CUDA 12.9 wheels run on any CUDA 12.x driver
(R570 is the 12.8 line RunPod hosts commonly report; minor-version compatibility covers 12.9). The
alternative, vLLM's PyPI default (CUDA 13), would make the *base* image need an R580+ driver too.

Both trainers are on CUDA 13 upstream and there is no supported way around it: ai-toolkit's own
Dockerfile pins torch cu130 with cu130-built flash-attn and NATTEN; LTX-2's packages pin the cu132
index and NATTEN cu132. So:

| image | wheels | host driver | RunPod |
| --- | --- | --- | --- |
| `…-pod-base` | vLLM cu129 | CUDA 12.x driver (R570+; R525+ via minor-version compatibility, unverified) | any GPU host |
| `…-pod-aitoolkit`, `…-pod-ltx` | base + CUDA 13.0 / 13.2 | **R580 or newer** | filter the pod's CUDA version to 13.0+ when creating it (`gpu.minCudaVersion` in the REST v2 pod create; the console's "CUDA version" filter) |

Mixing cu129 and cu13x venvs in one image is fine: each venv has its own `nvidia-*` libraries, and
one driver that satisfies the strictest (13.2) satisfies all. The base's `NVIDIA_REQUIRE_CUDA`
(cuda>=12.8) only gates container start, which an R580 driver passes.

## Building

```bash
# from the repo root; BuildKit is required (COPY --chmod), which is the default since Docker 23
docker buildx build --platform=linux/amd64 -f pod/images/Dockerfile.base      -t concept-captioner-pod-base:dev .
docker buildx build --platform=linux/amd64 -f pod/images/Dockerfile.aitoolkit -t concept-captioner-pod-aitoolkit:dev \
    --build-arg BASE_IMAGE=concept-captioner-pod-base:dev .
docker buildx build --platform=linux/amd64 -f pod/images/Dockerfile.ltx       -t concept-captioner-pod-ltx:dev \
    --build-arg BASE_IMAGE=concept-captioner-pod-base:dev .

# push for RunPod (the app references ghcr.io/<owner>/concept-captioner-pod-<trainer>:<tag>)
docker tag concept-captioner-pod-aitoolkit:dev ghcr.io/<owner>/concept-captioner-pod-aitoolkit:<tag>
docker push ghcr.io/<owner>/concept-captioner-pod-aitoolkit:<tag>
```

Build args worth knowing: `CUDA_JIT_TOOLCHAIN=1` on the base adds the CUDA 12.9 compiler (`cuda-nvcc-12-9`
and the `-dev` packages vLLM's own image installs, about a gigabyte) and repoints `/usr/local/cuda`
at 12.9 for FlashInfer kernels missing from the prebuilt cache; `FLASHINFER_JIT_CACHE_VERSION=""`
skips the cache; `VLLM_VERSION`, `AI_TOOLKIT_COMMIT`, `LTX2_COMMIT` and the torch versions are all
args so a bump is a one-line change plus an updated comment. The platform is fixed on every `FROM`,
so a build on Apple Silicon works without `--platform` too (but is emulated and slow; build on x86).

Every venv's build ends with an import check that needs no GPU (vLLM: torch build string and
package versions; ai-toolkit: `import flash_attn, natten, torchcodec, diffusers, transformers`,
the same check upstream's Dockerfile runs; LTX-2: the exact torch build and that the `natten` extra
landed) and writes `/opt/venvs/<name>/freeze.txt`, so a broken pin fails the build rather than the
first service start. Expect the base to be around 10 GB and each trainer image a few GB more; the
builds download several gigabytes of wheels.

There is no `.dockerignore` in the repository root yet, so the build context carries `.git`, the
local `.venv`s and `app/`. The Dockerfiles only `COPY` what they need, so this costs upload time, not
image size. Adding one is the repo owner's call; this content would do:

```
.git
**/.venv
**/__pycache__
**/.pytest_cache
**/.ruff_cache
app/
pod/images/workspace/
```

### Local fake mode

```bash
PODAGENT_TOKEN=local-dev-token-0123 docker compose -f pod/images/compose.fake.yaml up --build
podctl --url http://127.0.0.1:8800 health
```

The compose file publishes 8000 beside 8800 and sets `PODAGENT_FAKE_HOST=0.0.0.0`, so
vLLM's fake readiness endpoint is reachable from the host. Fake and real TensorBoard both bind
loopback and are shown through the authenticated agent at `/tensorboard/`; port6006 is never
published. The app first calls authenticated `POST /tensorboard-session`, installs its derived HMAC
cookie scoped to `/tensorboard`, then loads the page and its subresources. The cookie cannot
authenticate other agent API routes; the bearer is not a browser cookie.

`Dockerfile.fake` installs `pod/agent` alone (no `[pod]` extra, no concept-captioner); it exists to
drive the fake services (POD-SPEC §3, §6.3) and is not a stand-in for the CUDA images.

## Pod creation (the app's side, for reference)

HTTP ports `8800,8000` exposed, `PODAGENT_TOKEN` (16+ characters) and `HF_TOKEN` as env, the
volume at `/workspace`, a trainer image, and a CUDA 13.0+ host for the trainer images. The agent
refuses to start without the token, so a pod created without it exits immediately and visibly.
`nvidia-smi` is not in the image: the NVIDIA container runtime mounts it (the base sets
`NVIDIA_DRIVER_CAPABILITIES=compute,utility`), which is how `/gpus` reads the inventory.

## Verification record and remaining coverage

Actual builds, anonymous pulls, runtime receipts and their exact scope are recorded in
[POD-STATUS](../docs/POD-STATUS.md). The three repository Dockerfiles built successfully on
cx53 with the pinned vLLM cu129 stack, FlashInfer cache, AI Toolkit stack and LTX workspace, and
`v0.2.3-clean-20261011` is that build from `main` with nothing overlaid.

On the real CUDA 13.0 Blackwell hosts used for this project, vLLM returned structured captions,
both trainers produced checkpoints and loss curves, FLUX generation/Resume completed, and the
r2 LTX image trained the approved clip, resumed it and generated a matched 49-frame
base/LoRA video pair on a 32 GB GPU/62 GB host. Actual native checksum-verified collection
and stopped-pod receipts are recorded separately in that status.
These are functional infrastructure checks with synthetic inputs and tiny checkpoints, not
training-quality measurements.

Coverage that remains open:

- Base-image inference on an R570-class driver; observed trainer hosts used CUDA 13.0 drivers.
- New H3 training/clip/warm-start/generation code is source-verified with CPU/fake-runtime
  controls; it is not included in the current clean tag and has no hosted H3 acceptance.
- Parquet datasets and GPU configurations beyond those recorded.
- Recovery after a real agent or vLLM-worker crash. `tini -s` is installed and supervisor
  process-group ownership is tested, but actual crash/reaping recovery has not been forced.
- Fresh empty-cache LTX Hub download through the revision-pinned wrapper. This round reused
  the existing network-volume model cache; the source validation and download-failure paths
  have focused tests.

### H3 source addition (not yet built/published)

The next image must include the H3 helpers and the shared recipe/asset JSON COPY from the
native resource. AI Toolkit remains pinned to `f7a1fb9a77e5418269b1e9eda4ace6d7c1b7bb47`;
no dependency/toolchain pin changed in this round. H3 model binaries download at runtime
from `Comfy-Org/MiniMax-H3` revision `e5eb578a89295337b8ff433a035929ce0279e0b6`, and its
frozen training adapter from `circlestone-labs/MiniMax-H3-Image-Training-Adapter` revision
`7c6c04f75ba597232d4ce2bb4a14709948ec723a`. Filename choices are defined once in the shared
resource. These are BF16 quality assets, not a small-memory H3 recipe. No H3 GPU/RAM fit or
new image deployment has been measured in this source-only phase.
