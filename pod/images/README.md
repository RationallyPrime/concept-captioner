# images

Container images for the pod (POD-SPEC §6). All three CUDA images have been built and pushed
on cx53 with `docker buildx build --platform=linux/amd64`; the base image has passed an
anonymous pull. Live agent, vLLM and tiny FLUX execution are recorded in
`../docs/POD-STATUS.md`, alongside the pending LTX and publication checks. Docker is not
available on the development Mac, so builds use the existing build host.

| file | purpose |
| --- | --- |
| `Dockerfile.base` | CUDA 12.8 runtime + CPython 3.12 + uv; `/opt/venvs/vllm` (vLLM and its torch), `/opt/venvs/agent` (podagent[pod], concept-captioner[hf], tensorboard, huggingface_hub, datasets, Pillow); `/opt/pod/scripts/*.py`; entrypoint |
| `Dockerfile.aitoolkit` | base + `ostris/ai-toolkit` at a pinned commit in `/opt/ai-toolkit`, venv `/opt/venvs/aitoolkit` with upstream's own torch/flash-attn/NATTEN stack |
| `Dockerfile.ltx` | base + `Lightricks/LTX-2` at a pinned commit in `/opt/ltx-2` (uv workspace), venv `/opt/venvs/ltx` |
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
/opt/pod/scripts/*.py               pull_dataset.py, push_lora.py, launch_aitoolkit.py, launch_ltx.py
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
| `…-pod-aitoolkit`, `…-pod-ltx` | base + CUDA 13.0 / 13.2 | **R580 or newer** | filter the pod's CUDA version to 13.0+ when creating it (`allowedCudaVersions` in the REST v2 pod create; the console's "CUDA version" filter) |

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
published. The browser's first navigation sends the bearer and receives a cookie scoped to
that route for its subresources.

`Dockerfile.fake` installs `pod/agent` alone (no `[pod]` extra, no concept-captioner); it exists to
drive the fake services (POD-SPEC §3, §6.3) and is not a stand-in for the CUDA images.

## Pod creation (the app's side, for reference)

HTTP ports `8800,8000` exposed, `PODAGENT_TOKEN` (16+ characters) and `HF_TOKEN` as env, the
volume at `/workspace`, a trainer image, and a CUDA 13.0+ host for the trainer images. The agent
refuses to start without the token, so a pod created without it exits immediately and visibly.
`nvidia-smi` is not in the image: the NVIDIA container runtime mounts it (the base sets
`NVIDIA_DRIVER_CAPABILITIES=compute,utility`), which is how `/gpus` reads the inventory.

## What to verify on a real pod

Record the pod id, image tag and outcome in `docs/POD-STATUS.md` ("Verified on a real pod").

1. **The builds succeed as written.** Three things were pinned from upstream metadata and never
   executed here: the `+cu129` vLLM wheel resolves with the four `+cu129` torch pins (its own
   metadata may name `nvidia-cutlass-dsl[cu12]` rather than the PyPI wheel's `[cu13]`; either
   installs); `flashinfer-jit-cache` from flashinfer.ai is a real multi-gigabyte wheel (a ranged
   request to the release asset answered a 4.5 KB body on 2026-10-10 — if the install fails, build
   with `FLASHINFER_JIT_CACHE_VERSION=""`); `uv sync --all-packages --all-extras` enables ltx-core's
   `natten` extra from a virtual workspace root (the build asserts torch `2.13.0+cu132` and that
   `natten` is installed, so a wrong assumption fails loudly — fall back to `uv sync --extra natten`
   at the root, the upstream README's form).
2. **Driver floor.** On an R570-class host the base image serves a model with vLLM cu129; on an
   R580+ host both trainer venvs import torch and see the GPU (`torch.cuda.is_available()` from
   `/opt/venvs/aitoolkit/bin/python` and `/opt/venvs/ltx/bin/python`).
3. **vLLM without `nvcc`.** Serve the captioning model (`vllm serve <model> --host 0.0.0.0 --port 8000`
   with `VLLM_API_KEY` set, as the catalog does) on the GPU types the app will offer, including a
   Blackwell card, and caption one image. A log line about FlashInfer compiling a kernel means the
   prebuilt cache did not cover it: rebuild with `CUDA_JIT_TOOLCHAIN=1`, or switch the base to the
   `-devel` tag. `torchcodec` must import against jammy's FFmpeg 4.4 (it supports FFmpeg 4–8).
4. **ai-toolkit on the runtime base.** `run.py` with a FLUX config trains a few steps; `optimum-quanto`
   and Triton JIT paths find `gcc` (installed) and fall back cleanly where they need a CUDA
   compiler (upstream's image is also a runtime image, so this is the configuration upstream ships).
   Then the POD-SPEC §4.2 items that belong to the wrapper: H3 config keys, `trigger_word`,
   native TensorBoard logging.
5. **LTX-2.** `process_dataset.py` and `train.py` run from `/opt/venvs/ltx/bin/python` with the
   arguments the wrapper writes (POD-SPEC §4.3 VERIFY); VRAM needed per config (the trainer README
   says 80 GB for the standard configs, 32 GB with the low-VRAM INT8 config).
6. **`tini` as PID 1.** The entrypoint runs the agent under `tini -s` (apt package on both the
   CUDA base and the fake image). This is load-bearing, not cosmetic: the supervisor keeps a
   service's GPUs booked while anything in its process group is alive (`killpg(pgid, 0)`), and a
   zombie counts as alive, so grandchildren orphaned by a crashed wrapper or vLLM API server must
   be reaped by init or their GPUs would never be released. Verify on a real pod: `ps -o pid,ppid,
   stat,cmd` after killing a vLLM API-server process by hand shows the engine workers gone (not
   `Z`) and `GET /gpus` free within `ORPHAN_KILL_GRACE_S` (5 s).
7. **Sizes and pull time** on RunPod (the base is pre-cached only for `runpod/*` images, not ours).
