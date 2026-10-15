# pod — everything that runs on the rented GPU

The macOS app rents a GPU pod (RunPod first) running one of our container images and talks to
it over one authenticated HTTP API. This directory is that side of the product: the control
agent, the images it ships in, the scripts it launches, and a terminal client for it. The
contract is `docs/POD-SPEC.md`; what is implemented and what has been verified on a real pod
is `docs/POD-STATUS.md`. No real concept names anywhere; fixtures use `NORA7` / `IVAN9`.

```
agent/     podagent: FastAPI control agent on port 8800 (PID 1 in the image). /health, /gpus,
           /plan (the GPU topology rule), /services/{name}/{start,stop,logs}, /runs/{id}/events,
           /runs/{id}/files (the run's outputs), /runs/{id}/log-files (its trainer log and
           TensorBoard event files), /tensorboard/ (proxied, with a session from
           /tensorboard-session). Bearer token from PODAGENT_TOKEN on every call; refuses to
           start without one.
podctl/    podctl: one subcommand per endpoint plus `train`, `caption-up` and `pull`; httpx only.
images/    Dockerfile.base (CUDA + vLLM + agent + concept-captioner), Dockerfile.aitoolkit,
           Dockerfile.ltx (trainers layered on base), Dockerfile.fake + compose.fake.yaml (no GPU),
           entrypoint.sh (starts the agent and nothing else).
scripts/   pull_dataset.py (Hub dataset -> /workspace/datasets/<name>), push_lora.py (run ->
           model repo), launch_aitoolkit.py / launch_ltx.py (run.json -> native trainer config).
docs/      POD-SPEC.md (the contract), POD-STATUS.md (state, test counts, spec drift, pod checks).
```

Services run as child processes of the agent with `CUDA_VISIBLE_DEVICES` set per service; argv
comes from a fixed catalog, never from a shell string. One GPU: vLLM, then stop it, then the
trainer on GPU 0. Two or more: vLLM pinned to GPU 0, trainer on 1..N-1, concurrently. `/plan`
returns that assignment so the app never computes it twice; the agent refuses any start that
would double-book a GPU.

## Run the fake agent and podctl locally (no GPU, no Docker)

```bash
cd pod/agent  && uv sync
cd ../podctl  && uv sync

# terminal 1: two fake GPUs, services replaced by podagent.fakeservice stand-ins
cd pod/agent && PODAGENT_TOKEN=local-dev-token-0123 PODAGENT_FAKE_GPUS=2 \
    PODAGENT_WORKSPACE=/tmp/ws .venv/bin/python -m podagent

# terminal 2
cd pod/podctl && export PODCTL_URL=http://127.0.0.1:8800 PODAGENT_TOKEN=local-dev-token-0123
.venv/bin/podctl health
.venv/bin/podctl plan --caption --train          # 2 GPUs: concurrent, vllm on 0, trainer on 1
.venv/bin/podctl caption-up Qwen/Qwen3-VL-32B-Instruct
.venv/bin/podctl start pull-dataset --params '{"repo_id": "you/nora7-faces"}' --wait
.venv/bin/podctl logs vllm --follow
.venv/bin/podctl start tensorboard && .venv/bin/podctl tensorboard --session
.venv/bin/podctl files nora7-h3-001 && .venv/bin/podctl pull nora7-h3-001 --latest
.venv/bin/podctl stop vllm
```

With Docker: `PODAGENT_TOKEN=local-dev-token-0123 docker compose -f pod/images/compose.fake.yaml up --build`
(run from the repo root; the compose build context is the repo root).

Tests and lint, each tree on its own: `uv run pytest && ruff check . && ruff format --check . &&
ty check` in `agent/` and `podctl/`; `scripts/` is tested from the agent venv with the `pod` extra
(`uv sync --extra pod` in `agent/`, then `../agent/.venv/bin/python -m pytest tests -q` and the same
three checks). Tool versions come from the repository's `mise.toml`. Everything runs without a
GPU, Docker or the network. Counts are in `docs/POD-STATUS.md`.

## How the app creates a pod against these images

1. Build and push from the repo root (BuildKit; `images/README.md` has the exact commands):
   `-f pod/images/Dockerfile.base`, then `Dockerfile.aitoolkit` or `Dockerfile.ltx` with
   `--build-arg BASE_IMAGE=…`, tagged `ghcr.io/<owner>/concept-captioner-pod-<trainer>:<tag>`.
   One pod runs one trainer image; vLLM for captioning is in both.
2. Create the pod with that image, N GPUs, a network volume mounted at `/workspace`, HTTP ports
   `8800,8000` exposed (agent and vLLM; TensorBoard stays internal), env
   `PODAGENT_TOKEN` (16+ characters, generated per pod) and `HF_TOKEN`. The trainer images are
   CUDA 13 stacks: filter the pod to a CUDA 13.0+ host (R580+ driver). A pod created without
   the token exits immediately, visibly. Stopping the pod is the app's job; the pod has no
   self-stop. The app keeps the Mac awake while a pod runs and reconciles its pods on launch.
3. Poll `GET https://<pod-id>-8800.proxy.runpod.net/health` with the bearer until it answers
   (the proxy returns 502 for the first 30–60 s). The proxy is public and has a 100 s request
   timeout; the agent and vLLM carry the token. TensorBoard uses the authenticated agent
   route `/tensorboard/`: `POST /tensorboard-session` with the bearer returns a derived,
   12-hour cookie scoped to `/tensorboard`, which the browser then sends.
4. `POST /plan {"caption": true, "train": true}` → start `pull-dataset`, `vllm` on its GPUs,
   caption through `vllm:<model>` on port 8000 (same bearer as the agent), then
   `trainer-aitoolkit` or `trainer-ltx` with a `run.json` (POD-SPEC §4.1) on the plan's GPUs,
   `tensorboard` (always loopback port 6006), and watch `/services/{name}/logs` and
   `/runs/{id}/events`.
5. Take the LoRA: `push-lora` to a model repo, or, without a Hub account, download it with
   `GET /runs/{id}/files` and `GET /runs/{id}/files/{path}` (size and SHA-256 listed;
   `podctl pull`). Then stop or terminate the pod. Everything of value is on the
   volume; the agent's state is in memory and a container restart is a clean slate.
