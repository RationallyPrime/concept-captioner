# POD-SPEC — everything that runs on the rented GPU pod

Status: architecture, 2026-10-10. This is the contract the macOS app, `podctl` and the on-pod
code are written against. The app never shells into a pod: everything goes through the
control agent described here. Read `docs/v0.2-plan.md` ("Beyond v0.2") in the repo root for
the product context; `POD-STATUS.md` next to this file tracks what is implemented.

Placeholders throughout use the fixture triggers `NORA7` / `IVAN9`. Nothing here names a real
concept.

## 0. Layout of `pod/`

```
pod/
  agent/        Python package "podagent": FastAPI control agent (port 8800)
  podctl/       Python package "podctl": terminal client over the agent's HTTP API
  images/       Dockerfiles (base, aitoolkit, ltx, fake), entrypoint, compose for fake mode
  scripts/      pull_dataset.py, push_lora.py, launch_aitoolkit.py, launch_ltx.py
  docs/         this spec, POD-STATUS.md
```

Each of `agent/` and `podctl/` is its own `pyproject.toml` (uv-compatible, hatchling,
Python >= 3.11). `scripts/` is copied verbatim into the image at `/opt/pod/scripts/` and is
invoked by the agent through the service catalog; the scripts are plain `python` programs
with argparse and no dependency on `podagent`.

## 1. RunPod conventions this design relies on

Taken from the `runpod` skill's references (`runpod-usage/reference/{networking,pod-workflows,
storage,building-images}.md`). Items marked *verify* were not in those references and must be
checked on a real pod.

| Convention | Value | Consequence |
| --- | --- | --- |
| HTTP ports | declared at pod creation ("Expose HTTP Ports", max 10); cannot be added later without a reset | the app declares `8800/http,8000/http` (agent, vLLM; TensorBoard stays on loopback) when it creates the pod |
| Proxy URL | `https://<pod-id>-<internal-port>.proxy.runpod.net`, HTTPS only, **public and unauthenticated**, **100 s Cloudflare timeout** (`524`) | every agent endpoint starts its answer in well under 100 s; only run-file downloads (2.11) stream a body. The agent, vLLM and TensorBoard must carry their own auth or be treated as public |
| Bind address | public services bind `0.0.0.0`; TensorBoard binds `127.0.0.1` | TensorBoard is reached only through the authenticated agent route |
| Volume | network volume (or pod volume disk) mounted at `/workspace`; survives stop/restart; container disk is wiped | all data, logs and caches live under `/workspace`; the image holds only code and wheels |
| Env vars | `--env` at creation reach **PID 1** (our entrypoint → the agent); not SSH shells | the agent inherits `PODAGENT_TOKEN`, `HF_TOKEN`; every child service inherits the agent's env minus `PODAGENT_TOKEN` / `VLLM_API_KEY` (2.6), plus per-service additions |
| "Running" ≠ ready | proxy returns 502 for the first 30–60 s | the app polls `GET /health` with backoff, up to ~10 min |
| Runtime env (*verify*) | `RUNPOD_POD_ID`, `RUNPOD_PUBLIC_IP`, `RUNPOD_GPU_COUNT`, `RUNPOD_TCP_PORT_22` | reported in `/health` when present; nothing depends on them |
| GPU count | not in the references; the agent reads it from `nvidia-smi` | `/gpus` is the source of truth, not the pod spec |

The app creates pods through RunPod REST v2 `POST /v2/pods`: `image` names
`ghcr.io/<owner>/concept-captioner-pod-<trainer>:<tag>`, `gpu` carries `id`, `count`,
`minCudaVersion: "13.0"` and `minRamPerGpu: 60`; `disk: 50` is the temporary container disk.
`mounts.network` attaches the selected `volumeId` at `/workspace`, `dataCenterIds` selects
that volume's location, and `ports` is `["8800/http", "8000/http"]`. The `env` object carries
a generated `PODAGENT_TOKEN` and the user's `HF_TOKEN`.

Stopping a pod is the app's job; the pod side has no self-stop and no terminate-after guard.
The app keeps the Mac awake while a pod runs, and on launch reconciles the pods it created.
Its budget and idle watchdog send `POST /v2/pods/<id>/action` with `{"action":"stop"}` and
confirm a stopped status. Removal is a separate, confirmed DELETE operation.
The temporary disk is cleared on stop/restart; the network volume persists and remains billed.
See [RunPod storage](https://docs.runpod.io/pods/storage/types) and the current
`https://api.runpod.io/v2/openapi.json` schema.

## 2. Control agent: HTTP API

Base URL on a pod: `https://<pod-id>-8800.proxy.runpod.net`. Locally (fake mode):
`http://127.0.0.1:8800`.

### 2.1 Authentication

Every request, `/health` included, carries `Authorization: Bearer <PODAGENT_TOKEN>`.
Comparison is constant-time (`secrets.compare_digest`). Missing or wrong → `401` with the
error envelope below. The agent **refuses to start** when `PODAGENT_TOKEN` is unset, blank, or
shorter than 16 characters (exit 2 with a one-line message on stderr).

The bearer is checked from the headers alone, by a pure-ASGI guard ahead of routing, before a
byte of the request body is read: the proxy URL is public, and FastAPI would otherwise buffer
the whole body in memory before any route dependency ran. The same guard caps request bodies
at **1 MiB** (`Content-Length` above it, or a chunked body with no `Content-Length` → `413
payload_too_large`); the largest legitimate body is a trainer start's `RunConfig`, kilobytes.
The app-level dependency on every route is the second line of defence.

The same token is, by default, the API key vLLM is started with (`VLLM_API_KEY` env of the
vLLM child), so the app's `vllm:` endpoint on port 8000 is not an open proxy either.

One second credential exists, for TensorBoard only (2.9). A browser cannot attach the bearer
to the scripts and XHRs a TensorBoard page loads, so `POST /tensorboard-session` (bearer only)
issues a session cookie. Its value is never the token: it is
`v1.<expires>.<HMAC-SHA256(key, purpose ‖ expires)>`, keyed by 32 random bytes the agent draws
once per process, so a leaked cookie cannot be turned back into the token and every session
dies with the agent. It expires 12 hours after issue. It is accepted only on `/tensorboard`
and below, never on a control route and never on the handshake itself (which is outside that
subtree, so a session cannot renew itself). A request that carries an `Authorization` header is
judged by that header alone.

### 2.2 Errors

All errors, including FastAPI validation errors, use one envelope:

```json
{"error": {"code": "gpu_busy", "message": "GPU 0 is in use by vllm", "detail": {"gpu": 0, "service": "vllm"}}}
```

| HTTP | `code` | when |
| --- | --- | --- |
| 400 | `bad_request` | `/plan` with neither `caption` nor `train`; malformed JSON |
| 401 | `unauthorized` | missing or wrong bearer |
| 404 | `not_found` | unknown service name, unknown run id, no log file yet, no such run output file (2.11) |
| 409 | `already_running` | start of a service that is running |
| 409 | `gpu_busy` | requested GPU is held by a running service |
| 409 | `not_running` | stop of a service that is not running; `/tensorboard/…` while nothing listens on TensorBoard's port |
| 413 | `payload_too_large` | request body above 1 MiB, or sent chunked (2.1); `detail`: `{"content_length": n, "max_bytes": 1048576}` |
| 422 | `invalid_params` | pydantic rejects `params` (detail: pydantic's `errors()`) |
| 422 | `gpu_count` | number of GPUs outside the service's range |
| 422 | `unknown_gpu` | a GPU index not in the inventory |
| 422 | `validation` | request body/query shape (FastAPI `RequestValidationError`); a malformed run id or run file path |
| 503 | `gpu_inventory_unavailable` | nvidia-smi could not answer (timeout, nonzero exit, unparseable); the GPUs may be present and in use. `detail`: `{"last_known_count": 2, "last_known_at": "…"}` (nulls before the first good read). Retry; never "no GPUs" |
| 500 | `internal` | anything else; message is generic, traceback goes to the agent log |

### 2.3 `GET /health`

```json
{
  "status": "ok",
  "version": "0.1.0",
  "workspace": "/workspace",
  "gpu_backend": "fake",
  "gpu_count": 2,
  "runpod": {"pod_id": "abc123xyz", "public_ip": null},
  "time": "2026-10-10T12:00:00Z"
}
```

`gpu_backend` is `nvidia-smi` or `fake`. `gpu_count` is `null` while the inventory is
unavailable (section 5): the agent is still healthy. `runpod` fields are copied from `RUNPOD_*` env vars
when set, else `null`.

### 2.4 `GET /gpus`

```json
{"gpus": [
  {"index": 0, "name": "NVIDIA A100 80GB PCIe", "memory_total_mib": 81920, "memory_used_mib": 61440, "uuid": "GPU-…", "in_use_by": "vllm"},
  {"index": 1, "name": "NVIDIA A100 80GB PCIe", "memory_total_mib": 81920, "memory_used_mib": 0,     "uuid": "GPU-…", "in_use_by": null}
]}
```

`in_use_by` is the agent's own bookkeeping (which service holds that index: `running`, `stuck`,
or survived by its process group, see 2.6), not a reading from the driver. `memory_used_mib` is
the driver's reading (fake backend: `0`). Every child is polled before the answer, so a service
that exited on its own releases its GPU here without a `/services` call in between. `503
gpu_inventory_unavailable` when nvidia-smi does not answer (never an empty list for that).

### 2.5 `POST /plan`

The GPU topology rule, computed once, here, and nowhere else.

Request: `{"caption": true, "train": true, "gpu_count": null}`. `gpu_count` optional (defaults
to the inventory size); the app passes it when planning before the pod exists.

Rule (owner's):

| GPUs | caption only | train only | both |
| --- | --- | --- | --- |
| 0 | `400` `bad_request` ("no GPUs") | same | same |
| 1 | vLLM on `[0]` | trainer on `[0]` | **sequential**: vLLM on `[0]`, stop it, trainer on `[0]` |
| N ≥ 2 | vLLM on `[0]` | trainer on `[1..N-1]` (GPU 0 stays reserved for captioning so a re-caption can run during training) | **concurrent**: vLLM on `[0]`, trainer on `[1..N-1]` |

Response:

```json
{
  "gpu_count": 1,
  "mode": "sequential",
  "caption": {"service": "vllm", "gpus": [0]},
  "train":   {"service": "trainer", "gpus": [0]},
  "order": [
    {"action": "start", "service": "vllm"},
    {"action": "stop",  "service": "vllm"},
    {"action": "start", "service": "trainer"}
  ]
}
```

`mode` ∈ `sequential | concurrent | single` (`single` when only one of the two was requested).
`caption`/`train` are `null` when not requested. `train.service` is the generic `trainer`; the
app substitutes `trainer-aitoolkit` or `trainer-ltx`. The plan is advisory: the supervisor only
enforces no-double-booking, so a user who wants all N GPUs for a train-only run can pass
`gpus: [0..N-1]` to the start call explicitly.

### 2.6 Services

The catalog (section 3) has six names: `vllm`, `tensorboard`, `trainer-aitoolkit`,
`trainer-ltx`, `pull-dataset`, `push-lora`. One instance per name at a time; the name is the
instance key.

Service state object (returned by every service endpoint):

```json
{
  "name": "vllm",
  "state": "running",
  "pid": 4242,
  "gpus": [0],
  "params": {"model": "Qwen/Qwen3-VL-32B-Instruct", "port": 8000, "max_model_len": 16384, "gpu_memory_utilization": 0.9, "dtype": "auto"},
  "exit_code": null,
  "stopped_by_request": false,
  "group_alive": false,
  "started_at": "2026-10-10T12:00:00Z",
  "ended_at": null,
  "log_path": "/workspace/logs/vllm.log",
  "port": 8000,
  "run_id": null
}
```

`state` ∈ `idle` (never started since the agent booted, or status cleared), `running`,
`stopped` (exited after a stop request, any exit code), `failed` (exited on its own with a
nonzero code), `exited` (exited on its own with code 0; what a finished `pull-dataset` or a
completed training run looks like), `stuck` (a stop's SIGKILL did not end the child within 3 s:
uninterruptible sleep in the driver, Xid fault; `pid` is still set, the GPUs stay booked, a later
poll files it as `stopped` once it is gone). `params` never echoes secrets (`hf_token`,
`api_key` are redacted to `"***"`). `run_id` is set for the two trainers and `push-lora`.

`group_alive` is set when the direct child has exited (`failed` / `exited` / `stopped`) but its
process group has not: a trainer whose launch wrapper died, vLLM engine workers after the API
server crashed. The GPUs stay booked (`in_use_by` in 2.4, `gpu_busy` on a start) while it is
set; the agent SIGTERMs the group at the exit, SIGKILLs it 5 s later if it is still there, and
clears the flag once the group is empty. A start of the same service while `group_alive` is
`409 already_running` (detail `{"group_alive": true}`); a `stop` SIGKILLs the group at once.

- `GET /services` → `{"services": [state, …]}` for all six names, idle ones included.
- `GET /services/{name}` → state. `404` for an unknown name.
- `POST /services/{name}/start` → `201` + state. Body:
  `{"gpus": [1, 2], "params": {…}}`. `gpus` defaults to `[]`; services with `gpus: 0` reject a
  non-empty list (`gpu_count`). Checks, in order: name known → params validate against the
  service's pydantic model → GPU count within the service's range → every index exists →
  no service holds any of them (running, stuck, or survived by its group) → service not already
  running (nor stuck, nor survived by its group). Then: `prepare()` (write
  run files), open the log, spawn, return. The call returns as soon as the process is spawned;
  readiness is the client's business (vLLM: poll `GET /v1/models` on port 8000; trainer: watch
  logs/events).
- `POST /services/{name}/stop` → `200` + state. Body optional: `{"timeout_s": 30}` (1–90,
  default 30; `422 validation` above 90). The call blocks for the whole wait, and the RunPod
  proxy cuts every request at 100 s (§1), so the ceiling keeps every stop observable: a client
  never has to guess from a `524` whether the agent accepted it. SIGTERM to the process
  group, wait `timeout_s`, SIGKILL, wait at most 3 s. The
  GPUs are released when the whole group is gone; a child still present after the SIGKILL wait
  is filed `stuck` (see above) and the call returns. `409 not_running` only when there is
  nothing left of the service at all; a `stuck` service or an orphaned group (`group_alive`)
  can be stopped again, which re-sends SIGKILL.
- `GET /services/{name}/logs?tail=200` → `{"name": "vllm", "path": "/workspace/logs/vllm.log",
  "lines": ["…", "…"], "truncated": true}`. `tail` 1–5000, default 200. Lines are the last
  `tail` lines of the file; `truncated` says whether the file had more. For the services whose
  log has a fixed location (`vllm`, `tensorboard`, `pull-dataset`, `push-lora`) the file from an
  earlier agent lifetime is served when the service has not run since boot; the trainers' log
  depends on the run, so use `GET /runs/{id}/log` (2.8) for those. `404` when no such file
  exists.

Child processes: `Popen(argv, cwd=<service cwd>, env=<agent env − control-plane secrets +
CUDA_VISIBLE_DEVICES + CUDA_DEVICE_ORDER + HF_HOME + per-service additions>, stdout=<log file>,
stderr=STDOUT, start_new_session=True)`. The log file is truncated at every start so `tail`
always shows the current run. `CUDA_VISIBLE_DEVICES` is the comma-joined requested indices; for
`gpus: 0` services it is set to the empty string so they see no GPU at all.
`CUDA_DEVICE_ORDER=PCI_BUS_ID` is pinned for every child: nvidia-smi numbers GPUs in PCI bus
order and the agent books by that index; the CUDA runtime's default (`FASTEST_FIRST`) may
enumerate differently, which would put two services on one board despite the double-booking
check. `HF_HOME=/workspace/models/hf-cache` is set for every child.

`PODAGENT_TOKEN` and any `VLLM_API_KEY` in the agent's environment are removed from every
child's environment (vLLM gets its key from its own params, default the agent token, via the
catalog's `env()`); `tensorboard`, a loopback-only listener behind the authenticated agent that never talks to the
Hub, additionally gets no `HF_TOKEN`. None of the children need the control-plane bearer, and
TensorBoard, the trainer stacks and whatever a base model's custom code pulls in can read
`/proc/self/environ`.

No shell is ever involved: argv lists only, built by the catalog from validated params, with
every user-supplied value as its own argv element. Secrets travel in the child's environment,
never in argv (visible in `ps`).

Supervisor state is in memory. If the agent restarts (it is `tini`'s only child, so this means
the container restarted) every service is gone with it and the state is `idle` again; nothing is
persisted. The logs on the volume survive: `GET /services/{name}/logs` (fixed locations) and
`GET /runs/{id}/log` (trainers) read them back.

Agent shutdown (SIGTERM from the runtime, forwarded by `tini`): every running group is sent
SIGTERM at once, trainers first (a checkpoint in progress is the only state worth flushing),
then all are waited on against one shared 8 s deadline, then whatever remains gets SIGKILL and
the 3 s wait. The total stays under the runtime's stop grace (Docker default 10 s), so no
service is ever killed by pid-namespace teardown while the agent is still waiting on another.

### 2.7 `GET /runs/{id}/events`

TensorBoard summary for a training run. `id` matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`
(anything else: `422 validation`); the log directory is `/workspace/runs/<id>/tensorboard/`
(`404` when the run directory does not exist; an existing run without event files yet returns
empty `scalars`).

```json
{
  "run_id": "nora7-h3-001",
  "logdir": "/workspace/runs/nora7-h3-001/tensorboard",
  "files": 1,
  "scalars": {
    "loss":          {"step": 1250, "value": 0.1182, "wall_time": 1760097600.1, "count": 1250},
    "learning_rate": {"step": 1250, "value": 0.0001, "wall_time": 1760097600.1, "count": 1250}
  },
  "last_step": 1250,
  "reader": "minimal"
}
```

Latest value per tag, across every `events.out.tfevents.*` file in the directory and its
subdirectories (ai-toolkit writes its native files to `<log_dir>/<name>_<timestamp>/`, beside
the wrapper's scraped file; newest file wins on ties). `count` is how many scalar points that tag has. Reader selection: if
`tensorboard` is importable, `EventAccumulator` (`reader: "tensorboard"`); else the package's
own minimal tfrecord/protobuf reader (`reader: "minimal"`), which understands `simple_value`
and the TF2 `tensor` (float, single element) encoding. The minimal reader is always present and
is what the tests exercise; it exists so the agent venv does not need TensorFlow-sized
dependencies to answer this endpoint.

Parsing is bounded: files are read sequentially, truncated/corrupt trailing records (a file
being written) are ignored rather than failing the request.

### 2.8 `GET /runs/{id}/log?tail=200`

The trainer log of a run, `/workspace/runs/<id>/trainer.log`, read from the volume: works for a
run that finished before this agent started, which `/services/trainer-*/logs` cannot reach. `id`
as in 2.7 (`422 validation` otherwise); `404 not_found` when the run directory or the log file
does not exist (detail names the path). `tail` 1–5000, default 200.

```json
{"run_id": "nora7-h3-001", "path": "/workspace/runs/nora7-h3-001/trainer.log", "lines": ["…"], "truncated": true}
```

### 2.9 TensorBoard: `POST /tensorboard-session` and `/tensorboard/…`

TensorBoard binds `127.0.0.1` on the catalog's fixed port (6006, 3.2) with `--path_prefix
/tensorboard`, and is shown at `https://<pod-id>-8800.proxy.runpod.net/tensorboard/`. `GET`,
`POST` and `HEAD` on `/tensorboard` and below are proxied to that port, path and query
unchanged. Forwarded request headers: `accept`, `content-type`, `if-none-match`,
`if-modified-since` (never `Authorization` or cookies); returned: `content-type`,
`cache-control`, `etag`, `last-modified`, `location`. Responses are buffered (30 s upstream
timeout). Nothing listening on the port → `409 not_running`; any other upstream failure →
`500`. The route reads no supervisor state.

`POST /tensorboard-session` (bearer required, no body) → `200`:

```json
{
  "cookie": "podagent_tensorboard",
  "value": "v1.1791760000.3f1c…",
  "path": "/tensorboard",
  "max_age_s": 43200,
  "expires_at": "2026-10-11T12:00:00Z",
  "secure": true,
  "http_only": true,
  "same_site": "strict",
  "url": "/tensorboard/"
}
```

plus `Set-Cookie: podagent_tensorboard=<value>; HttpOnly; Max-Age=43200; Path=/tensorboard;
SameSite=strict; Secure`. `Secure` is dropped only in fake mode over plain http (RunPod
terminates TLS before the agent, so a real pod is always https to the browser). Proxied
responses never set a cookie. A client puts the cookie into its browser's cookie store (or
lets the `Set-Cookie` do it), then navigates to `url`; on a `401` (expired, or the agent
restarted) it calls the handshake again.

### 2.10 `GET /runs/{id}/files`

The run's output directory, `/workspace/runs/<id>/output/`: both trainers write checkpoints,
final weights and samples there (4.1). This is how a user without a Hub account gets the
trained LoRA. `id` as in 2.7 (`422 validation` otherwise, `404` when the run directory does
not exist). A run without `output/` yet answers an empty `files` list.

```json
{
  "run_id": "nora7-h3-001",
  "root": "/workspace/runs/nora7-h3-001/output",
  "files": [
    {"path": "checkpoints/lora_weights_step_02000.safetensors", "size": 214240000,
     "sha256": "0c0e9492…", "modified_at": "2026-10-10T19:45:17Z"}
  ]
}
```

`path` is relative to `root`, `/`-separated, sorted. Regular files only: the walk never follows
a symlink, and a symlinked file, directory or `output` itself is left out. `size` in bytes,
`sha256` lowercase hex, `modified_at` UTC to the second. Digests are cached per agent process by
path, size, mtime and inode, so the first listing of a large output hashes every file (seconds
per gigabyte) and later ones only what changed.

### 2.11 `GET /runs/{id}/files/{path}`

One file from that listing, streamed: `200`, `Content-Type: application/octet-stream`,
`Content-Length`, `Content-Disposition: attachment; filename="<basename>"`, `ETag` and
`Last-Modified`; `HEAD` answers the headers alone; byte ranges are honoured. `path` is the
listing's `path` with each segment percent-encoded. Refused:

- `422 validation` for a `path` with a `.` or `..` segment, an empty segment (so no leading
  `/` and no `//`), or a NUL;
- `404 not_found` unless the path resolves to a regular file whose real path is exactly
  `<real output root>/<path>`: a symlink anywhere on the way, `output` itself included,
  never matches, wherever it points.

Clients verify `size` and `sha256` from 2.10 after the download (`podctl pull` does). VERIFY on
a pod: that the RunPod proxy's 100 s limit applies to the start of the response and not to a
multi-gigabyte body that is still flowing.

## 3. Service catalog

`podagent.catalog.CATALOG: dict[str, ServiceSpec]`. A `ServiceSpec` has:

```python
@dataclass(frozen=True)
class ServiceSpec:
    name: str
    params_model: type[BaseModel]          # extra="forbid"
    gpus: tuple[int, int]                  # (min, max); max = -1 means "any number >= min"
    port: int | None                       # the service's port (vLLM: default of its param; TensorBoard: fixed)
    def cwd(self, params, paths) -> Path
    def log_path(self, params, paths) -> Path
    def argv(self, params, gpus, paths) -> list[str]
    def env(self, params, settings) -> dict[str, str]       # per-service additions, secrets included
    def prepare(self, params, paths) -> None                 # write run files before spawn
    def run_id(self, params) -> str | None
```

`paths` is `podagent.settings.Paths` (`workspace`, `datasets`, `runs`, `models`, `logs`,
`prefix` for `/opt`). In fake mode (section 5) every spec's argv is replaced by
`[sys.executable, "-m", "podagent.fakeservice", name, "<json params>"]`, a stand-in that logs its
argv/env, binds the service's port when it has one, and sleeps until SIGTERM (`pull-dataset`
and `push-lora` fakes exit 0 after two seconds). This is how the supervisor, the API and
`podctl` are tested end-to-end without a GPU or Docker.

Secrets: `hf_token` (pull/push/trainers) and `api_key` (vLLM) are optional params; when absent
the child inherits the agent's `HF_TOKEN` / `PODAGENT_TOKEN`. They are redacted in every
response and never logged.

### 3.1 `vllm` — GPUs exactly 1, port 8000

Params (`VllmParams`):

| field | type | default | notes |
| --- | --- | --- | --- |
| `model` | str | required | Hub id (`Qwen/Qwen3-VL-32B-Instruct`) or a path under `/workspace/models/` |
| `port` | int 1024–65535 | 8000 | must be the exposed port |
| `max_model_len` | int ≥ 1024 | 16384 | |
| `gpu_memory_utilization` | float 0.1–0.99 | 0.9 | |
| `dtype` | `auto|bfloat16|float16` | `auto` | |
| `max_num_seqs` | int 1–1024 | 16 | captioning is latency-bound, not throughput-bound |
| `served_model_name` | str or null | null | lets the app keep `vllm:<short>` stable |
| `api_key` | str or null | null | → `VLLM_API_KEY` env; default `PODAGENT_TOKEN` |
| `extra_args` | list[str] | `[]` | flags and values must pass `VLLM_EXTRA_FLAGS` in `catalog.py`; each flag appears at most once. Paths, binding, auth, remote code and flags already emitted by the builder are excluded. Fake service switches are accepted only in fake mode |

argv: `[/opt/venvs/vllm/bin/vllm, serve, <model>, --host, 0.0.0.0, --port, <port>, --max-model-len, …,
--gpu-memory-utilization, …, --dtype, …, --max-num-seqs, …, --download-dir, /workspace/models/hf-cache,
(--served-model-name, <name>), *extra_args]`. cwd `/workspace`. log `/workspace/logs/vllm.log`.
Env: `VLLM_API_KEY`. Readiness for the client: `GET http://…:8000/v1/models` with the bearer.

### 3.2 `tensorboard` — GPUs 0, port 6006

Params: `logdir` (str, default `/workspace/runs`; must resolve under `/workspace`). No `port`:
TensorBoard always listens on the catalog's port 6006, which is where the agent's proxy (2.9)
sends every request; a `port` param is `422 invalid_params`. argv: `[/opt/venvs/agent/bin/tensorboard, --logdir, <logdir>, --host, 127.0.0.1, --port,
6006, --reload_multifile, true, --reload_interval, 15, --path_prefix, /tensorboard]`. log `/workspace/logs/tensorboard.log`.
Pointing it at `/workspace/runs` once shows every run as a TensorBoard "run"
(`<id>/tensorboard`).

### 3.3 `trainer-aitoolkit` and `trainer-ltx` — GPUs 1..N

Params: the **run config** of section 4 (`RunConfig`), identical for both except that
`trainer-ltx` validates with `LtxRunConfig`, which also checks `extra.preprocess` (4.3); `trainer`
is implied by the service name. `prepare()` creates `/workspace/runs/<run_id>/` and writes `run.json` (the
validated config, secrets stripped). argv:
`[/opt/venvs/<trainer>/bin/python, /opt/pod/scripts/launch_<trainer>.py, --config, /workspace/runs/<id>/run.json]`.
cwd `/workspace/runs/<id>`. log `/workspace/runs/<id>/trainer.log`. Env: `HF_TOKEN` (when
`hub` is set), `PYTHONUNBUFFERED=1`. The launch wrapper (section 4.3) turns `run.json` into the
trainer's native config and `exec`s the trainer. A trainer sees only its assigned GPUs, so
inside the process they are `cuda:0..k-1`.

Starting a trainer whose `run_id` directory already contains `output/` is allowed (the wrappers
resume when the trainer supports it; otherwise they overwrite — see 4.3). The client decides.

### 3.4 `pull-dataset` — GPUs 0

Params (`PullDatasetParams`): `repo_id` (str, `^[\w.-]+/[\w.-]+$`), `name` (str, dataset folder
name, `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; default: repo name), `split` (`train`), `revision`
(null), `image_column` (`image`), `caption_column` (`caption`), `id_column` (null),
`hf_token` (null). argv:
`[/opt/venvs/agent/bin/python, /opt/pod/scripts/pull_dataset.py, --repo, <repo_id>, --to, /workspace/datasets/<name>,
--split, …, --image-column, …, --caption-column, …, (--revision, …), (--id-column, …)]`.
log `/workspace/logs/pull-dataset.log`. Exit 0 = dataset ready at `/workspace/datasets/<name>`.

### 3.5 `push-lora` — GPUs 0

Params (`PushLoraParams`): `run_id`, `repo_id`, `private` (true), `include_samples` (true),
`all_checkpoints` (false), `commit_message` (null), `hf_token` (null). argv:
`[/opt/venvs/agent/bin/python, /opt/pod/scripts/push_lora.py, --run-dir, /workspace/runs/<id>, --repo, <repo_id>,
(--private), (--no-samples), (--all-checkpoints), (--commit-message, …)]`.
log `/workspace/logs/push-lora.log`. Exit 0 = the model repo has the LoRA.

## 4. Run config and the launch wrappers

### 4.1 `RunConfig` (JSON; the body of a trainer start's `params`)

```json
{
  "run_id": "nora7-h3-001",
  "dataset": {"path": "/workspace/datasets/faces", "caption_ext": "txt"},
  "triggers": ["NORA7"],
  "profile": "h3-still",
  "base_model": "black-forest-labs/FLUX.1-dev",
  "steps": 2000,
  "learning_rate": 0.0001,
  "rank": 16,
  "alpha": null,
  "resolution": [512, 768, 1024],
  "batch_size": 1,
  "gradient_accumulation": 1,
  "seed": 42,
  "save_every": 250,
  "sample_every": 250,
  "sample_prompts": ["NORA7 woman, studio portrait, soft key light"],
  "hub": {"repo_id": "you/nora7-h3-lora", "private": true, "push_on_finish": false},
  "hf_token": null,
  "extra": {}
}
```

| field | required | default | meaning |
| --- | --- | --- | --- |
| `run_id` | yes | | `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; names `/workspace/runs/<id>` |
| `dataset.path` | yes | | must resolve under `/workspace/datasets/`; images + `<stem>.<caption_ext>` sidecars (what `pull_dataset.py` produces) |
| `dataset.caption_ext` | no | `txt` | |
| `triggers` | yes | | ≥ 1; the first is the trainer's "trigger word" where the trainer has one |
| `profile` | no | null | informational: which caption profile produced the captions; stored in `run.json` and the model card |
| `base_model` | yes | | Hub id or `/workspace/models/<dir>`. No default: the H3 vs FLUX vs LTX choice is the user's |
| `steps` | no | 2000 | |
| `learning_rate` | no | 1e-4 | |
| `rank` | no | 16 | LoRA rank; `alpha` defaults to `rank` |
| `resolution` | no | `[512, 768, 1024]` | int or list; LTX takes the largest as its bucket |
| `batch_size` | no | 1 | |
| `gradient_accumulation` | no | 1 | |
| `seed` | no | 42 | |
| `save_every` / `sample_every` | no | 250 / 250 | 0 disables samples |
| `sample_prompts` | no | `[]` | each should contain a trigger; the wrapper does not enforce it |
| `hub` | no | null | `repo_id`, `private` (true), `push_on_finish` (false → push is a separate `push-lora` start) |
| `hf_token` | no | null | secret; env only |
| `extra` | no | `{}` | deep-merged into the native config last; the escape hatch for trainer options not modelled here. It cannot move the trainer out of the workspace: output/data paths (`training_folder`, `log_dir`, `folder_path`, `output_dir`, `preprocessed_data_root`) must resolve under `/workspace`. Model references follow the rule below. The agent refuses invalid values (`422`) and the wrapper re-checks the merged config |

**Model references in `extra`: a Hub id where the trainer itself downloads, a workspace path
where it opens files.** AI Toolkit's `name_or_path` (and `model_source`) take a Hub id or an
absolute path under `/workspace`: ai-toolkit resolves an id through `huggingface_hub` into
`HF_HOME`, which the agent points at `/workspace/models/hf-cache`, so an id can only ever land
inside the workspace. LTX's `model.model_path`, `model.text_encoder_path`,
`model.video_vae_path`, `model.audio_vae_path` and `model.load_checkpoint` must be absolute
paths under `/workspace`: the LTX-2 trainer opens them as local files and has no Hub
resolution, so a Hub id there could only fail at load time, after the GPUs were reserved. LTX's
one Hub source, `base_model: Lightricks/LTX-2`, is downloaded by the wrapper itself at a pinned
revision into `/workspace/models/ltx-2` (4.3) and reaches the trainer as those local paths.

Output layout, both trainers: `/workspace/runs/<id>/run.json`, `config.yaml` (native config as
written by the wrapper), `trainer.log`, `tensorboard/` (event files), `output/` (checkpoints and
the final LoRA), `samples/`.

### 4.2 Defaults vs user-supplied, and what is uncertain

User-supplied: `run_id`, `dataset.path`, `triggers`, `base_model`, `hub.repo_id` (if pushing).
Everything else has a default a first-time user can accept. The defaults above are the
conventional FLUX-LoRA starting point from ai-toolkit's example configs; they are not tuned for
H3 or LTX and the wrappers must not pretend otherwise.

**Live evidence and remaining uncertainty** (full receipts and exact image revisions are in
`POD-STATUS.md`):

- ai-toolkit: the config keys for the MiniMax H3 model family (`model.arch`/`name_or_path`,
  quantization flags) and semantic treatment of `trigger_word` remain unverified. The tiny
  FLUX run produced native and scraped TensorBoard events and valid checkpoints.
- LTX-2: the pinned trainer's entrypoints, `caption`/`media_path` preparation, one-frame
  buckets, mapped training keys, nested checkpoints and scraped TensorBoard events ran on
  real hardware. A 512-pixel/rank-16 run passed on one visible 32 GB GPU in a 125 GB host.
  The trainer venv requires TensorBoard explicitly; the image tests an actual event write/read.
- Wider resolutions, other models, video inputs, generated validation samples and training
  quality remain unverified. These tiny functional checks do not establish universal memory
  capacity. Resume evidence and its exact scope are recorded separately in `POD-STATUS.md`.

### 4.3 Launch wrappers (`scripts/launch_aitoolkit.py`, `scripts/launch_ltx.py`)

Both: `--config <run.json>` → validate (a copy of the `RunConfig` rules, no `podagent` import)
→ write the native config to `<run>/config.yaml` → start the trainer as a child with
stdout/stderr tee'd to the wrapper's stdout (which is `trainer.log`) → on exit, if
`hub.push_on_finish`, run `push_lora.py` → exit with the trainer's code.

**Log scraper.** While tee'ing, the wrapper matches `loss` / `lr` / `step` patterns in trainer
output and writes them as scalars with `torch.utils.tensorboard.SummaryWriter` into
`<run>/tensorboard/` (tag `scraped/loss`, `scraped/lr`) so `/runs/{id}/events` and TensorBoard
have data even when the trainer does not log natively. Native event files, when the trainer
writes them to the same directory or a subdirectory of it (ai-toolkit: `<log_dir>/<name>_<timestamp>/`),
are read by `/runs/{id}/events` too and take precedence in the UI by tag name. If the tee
itself fails (the volume fills up, say), the wrapper stops the trainer (SIGTERM, then SIGKILL)
before exiting, so the supervisor never frees GPUs a trainer still holds.

`launch_aitoolkit.py` mapping (`job: extension`, one `sd_trainer` process):

| run.json | native |
| --- | --- |
| `run_id` | `config.name` |
| `<run>/output` | `process[0].training_folder` |
| `triggers[0]` | `process[0].trigger_word` (VERIFY) |
| `rank`, `alpha` | `network.{type: lora, linear, linear_alpha}` |
| `save_every` | `save.save_every` (+ `dtype: float16`, `max_step_saves_to_keep: 4`) |
| `dataset.path`, `caption_ext`, `resolution` | `datasets[0].{folder_path, caption_ext, resolution, cache_latents_to_disk: true, caption_dropout_rate: 0.05}` |
| `steps`, `learning_rate`, `batch_size`, `gradient_accumulation` | `train.{steps, lr, batch_size, gradient_accumulation_steps}` + `dtype: bf16`, `optimizer: adamw8bit`, `noise_scheduler: flowmatch`, `gradient_checkpointing: true`, `train_text_encoder: false` |
| `base_model` | `model.name_or_path` (+ `is_flux: true, quantize: true` for FLUX ids; H3 keys VERIFY) |
| `sample_every`, `sample_prompts`, `seed` | `sample.{sample_every, prompts, seed, width/height = max(resolution), sampler: flowmatch, guidance_scale: 4, sample_steps: 20}` |
| `extra` | deep-merged last |

Command: `/opt/venvs/aitoolkit/bin/python /opt/ai-toolkit/run.py <run>/config.yaml`.

`extra.preprocess.args` is checked both at the start API and by the standalone wrapper. At the
API the check belongs to `trainer-ltx`'s params model, `LtxRunConfig` (`422 invalid_params`,
`loc` `["extra", "preprocess"]`, type `preprocess_args`, before any run directory exists).
Both read one stdlib file, `agent/src/podagent/ltx_rules.py`, which the image copies into a
`/opt/pod/agent/src/podagent/` layout for the isolated wrapper; the wrapper loads it at import,
so the image build's `--help` check fails if the copy is missing. Supported switches are
`--vae-tiling`, `--decode`, `--remove-llm-prefixes`, `--skip-audio`,
`--load-text-encoder-in-8bit`, and `--overwrite`. Supported integer options are
`--batch-size`, `--reference-downscale-factor`, and `--reference-temporal-scale-factor`,
using `--flag=value` with values 1 through 64. Duplicates, unknown flags and values on switches
are rejected. Model paths, output paths, device and column names remain wrapper-owned.

For LTX's first run, `base_model: Lightricks/LTX-2` prepares the unified
`ltx-2-19b-dev.safetensors` checkpoint and its mirrored Gemma model/tokenizer assets from that
Hub repository into `/workspace/models/ltx-2`, at revision
`dfcc2108383fe1aaa0584bdf55d368a4bdadd90c` (`LTX_HUB_REVISION` in `ltx_rules.py`, also
`LtxRunConfig.hub_source` in the catalog): the repository's head since 2026-08-04 and what the
verified 2026-10-10 run downloaded, 22 files. Moving it is a reviewed edit; the download never
follows the repository's `main`. The wrapper uses only its declared file patterns and the fixed
destination, then supplies local checkpoint and text encoder paths to upstream. No SSH or
separate model path is needed. Existing files are reused. The download runs after validation
and before any run file is written; a failure (unreachable, gated, licence not accepted, disk
full) exits **69** with the exception, HTTP status and message on one line, and leaves the run
directory as the agent created it. `--dry-run` writes the planned config without downloading.
Other LTX sources require explicit local component paths. Wrapper exit codes: `2` invalid
config, `69` model preparation, otherwise the preprocessor's, trainer's or push's own
(`scripts/README.md`).

`launch_ltx.py` runs `/opt/venvs/ltx/bin/python` against the entrypoints under
`/opt/ltx-2/packages/ltx-trainer/scripts/`. `process_dataset.py` consumes dataset JSON with
`caption`/`media_path`, a `<max>x<max>x1` still-image bucket and explicit model/encoder paths,
writing `<run>/preprocessed/`. `train.py <run>/config.yaml` consumes:

- `model.model_path`: the prepared or supplied local checkpoint, `model.text_encoder_path`,
  `model.training_mode: lora`, and the newest nested checkpoint as `model.load_checkpoint`
  when present; explicit model overrides still apply.
- `lora.{rank, alpha}` and `optimization.{learning_rate, steps, batch_size,
  gradient_accumulation_steps, enable_gradient_checkpointing: true}`.
- `data.preprocessed_data_root`, root `seed`, and `validation.{prompts, interval, seed,
  video_dims: [max(resolution), max(resolution), 1]}`. Validation is disabled with a null
  interval when sampling is off or no prompts are supplied.
- `checkpoints.{interval: save_every, keep_last_n: 4}`, `output_dir: <run>/output`, and
  `acceleration.mixed_precision_mode: bf16`.

The wrapper deep-merges `extra` last; `extra.preprocess` configures preparation only and is
omitted from the native training config. Actual checkpoints were written under
`<run>/output/checkpoints/`; the wrapper's event scraper writes `<run>/tensorboard/`.

## 5. GPU inventory backend

```python
class GpuInfo(BaseModel):
    index: int; name: str; memory_total_mib: int; memory_used_mib: int; uuid: str | None

class GpuBackend(Protocol):
    kind: str                                   # "nvidia-smi" | "fake"
    def list_gpus(self) -> list[GpuInfo]: ...
```

- `NvidiaSmiBackend`: runs
  `nvidia-smi --query-gpu=index,name,memory.total,memory.used,uuid --format=csv,noheader,nounits`
  (argv list, 10 s timeout) and parses the CSV. A missing binary, timeout, nonzero exit or
  unparseable output raises `InventoryUnavailable` (plus a logged warning); an empty list is only
  ever a successful query of a pod without GPUs. The supervisor maps the exception to
  `503 gpu_inventory_unavailable` on `/gpus`, `/plan` (unless `gpu_count` is given) and a start
  that names GPUs, and reports the last good inventory's size and time in the detail; `/health`
  answers with `gpu_count: null`. nvidia-smi can stall past its timeout while a driver is busy
  loading a 32B model, and that must never read as "this pod has no GPU".
  The parser is a pure function `parse_nvidia_smi(text) -> list[GpuInfo]`, tested on fixtures.
- `FakeBackend(n)`: `n` entries, `name="FAKE GPU"`, 81920 MiB total, 0 used,
  `uuid="GPU-FAKE-<i>"`.
- Selection (`podagent.settings`): `PODAGENT_FAKE_GPUS` set (any integer ≥ 0) → fake, and
  **fake mode** for the catalog (section 3); unset → nvidia-smi. The inventory is read on every
  `/gpus` and `/plan` call (cheap; nvidia-smi is fast), not cached.

## 6. Images, entrypoint, compose, volume

### 6.1 Layering

```
images/Dockerfile.base       nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04
                             + python3.12, uv
                             + /opt/venvs/agent   : podagent, concept-captioner (from this repo), tensorboard,
                                                    huggingface_hub, datasets, Pillow
                             + /opt/venvs/vllm    : vllm (pinned), its torch; build fails unless every
                                                    VLLM_EXTRA_FLAGS flag is in its source
                                                    (images/check_vllm_flags.py)
                             + /opt/pod/scripts/*, /opt/pod/entrypoint.sh
                             EXPOSE 8800 8000; ENTRYPOINT /opt/pod/entrypoint.sh
images/Dockerfile.aitoolkit  FROM base; git clone ostris/ai-toolkit @ pinned commit → /opt/ai-toolkit;
                             /opt/venvs/aitoolkit with its requirements (own torch)
images/Dockerfile.ltx        FROM base; git clone Lightricks/LTX-2 @ pinned commit → /opt/ltx-2;
                             /opt/venvs/ltx with the trainer's requirements + TensorBoard 2.21.0 (pinned)
                             and its event-write/read check
images/Dockerfile.fake       python:3.12-slim + podagent only; for compose (no CUDA, no trainers)
```

Separate venvs per workload so vLLM's and each trainer's torch pins never collide; the agent's
venv has no torch at all except what `tensorboard` needs (none). Image tags carry the trainer:
`concept-captioner-pod-aitoolkit:<tag>`, `concept-captioner-pod-ltx:<tag>`. A pod runs one
trainer image; captioning (vLLM) is in both.

Build hygiene: `--platform=linux/amd64`, pinned base digests where possible, `pip`/`uv` caches
off, no secrets at build time, `HF_HOME` not baked (it points into `/workspace` at run time).

### 6.2 Entrypoint (`images/entrypoint.sh`)

1. `mkdir -p /workspace/{datasets,runs,models/hf-cache,logs}`
2. `export HF_HOME=/workspace/models/hf-cache`
3. `exec tini -s -- /opt/venvs/agent/bin/python -m podagent --host 0.0.0.0 --port 8800`

Nothing else: no sshd, no Jupyter, no service autostart. The agent refuses to start without
`PODAGENT_TOKEN`, so a pod created without the env var exits immediately, visibly.

`tini` (apt package, on the fake image too) is PID 1 and a subreaper (`-s`); the agent is its
only child. The supervisor's GPU bookkeeping follows process groups and probes them with
`killpg(pgid, 0)`, which stays true while any member exists, zombies included: the orphans a
crashed launch wrapper or vLLM API server leaves behind must be reaped by init, or their GPUs
would stay booked until the container restarts. The agent does not reap with `waitpid(-1)`
itself (that would make `Popen` lose its children's exit codes). `tini` forwards SIGTERM.

### 6.3 Compose (`images/compose.fake.yaml`)

One service `agent`: build `Dockerfile.fake` with context `..` (so it can install `agent/`),
`PODAGENT_FAKE_GPUS=2`, `PODAGENT_FAKE_HOST=0.0.0.0`, `PODAGENT_TOKEN=${PODAGENT_TOKEN:?set
PODAGENT_TOKEN}`, `PODAGENT_WORKSPACE=/workspace`, bind mount `./workspace:/workspace`, ports
`8800:8800`, `8000:8000` (the same two the app exposes on a real pod). `podctl
--url http://127.0.0.1:8800` then drives the fake services, and the fake vLLM's `/v1/models` on
`http://127.0.0.1:8000` is reachable from the host because
`PODAGENT_FAKE_HOST` moves the responders off the container's loopback. The same thing without Docker:
`PODAGENT_FAKE_GPUS=2 PODAGENT_TOKEN=… PODAGENT_WORKSPACE=/tmp/ws python -m podagent`.

### 6.4 Volume layout (`/workspace`)

```
/workspace/
  datasets/<name>/        images, <stem>.txt captions, metadata.jsonl, manifest.json, job.yaml (if the repo had one)
  runs/<id>/              run.json, config.yaml, trainer.log, tensorboard/, output/, samples/, preprocessed/ (ltx)
  models/hf-cache/        HF_HOME for every child (vLLM weights, base models)
  models/<dir>/           user-placed local models
  logs/                   vllm.log, tensorboard.log, pull-dataset.log, push-lora.log, podagent.log
```

`PODAGENT_WORKSPACE` overrides `/workspace` (tests, local runs). Every path a client supplies
(`dataset.path`, `logdir`) must resolve under the workspace; the catalog rejects anything else
(`invalid_params`).

## 7. Scripts

### 7.1 `pull_dataset.py`

`--repo ID --to DIR [--split train] [--revision R] [--image-column image] [--caption-column caption]
[--id-column C] [--job-path concept-captioner/job.yaml]`. Token from `HF_TOKEN`.

Two conventions, detected from the repo's file list (`HfApi.list_repo_files`):

1. **imagefolder**: image files plus `metadata.jsonl` (`file_name`, `caption` or `text`).
   `snapshot_download`, then copy images into `DIR` flat (subfolders flattened with `__`
   separators; collisions are an error) and write `<stem>.txt` from the caption field.
2. **parquet / arrow**: `datasets.load_dataset(repo, split=…, revision=…)`; sample id per
   `concept_captioner.sources.hf._sample_id` rules (`--id-column`, else `file_name`/`filename`/
   `image_id`/`id`/`name`, else the row index); image bytes written with their original suffix
   (PNG when unknown); caption from `--caption-column` when present and non-empty.

Always written: `metadata.jsonl` (`file_name`, `caption`) regenerated from what landed, and
`manifest.json` (`repo_id`, `revision`, `convention`, `count`, `with_caption`, `without_caption`,
`job_yaml`). `job.yaml` is fetched from `--job-path` when the repo has it (so the trainer wrapper
and the model card can read triggers and profile). Exit 1 and a message on any image without a
caption when `--require-captions` is passed; otherwise the counts tell the client.

### 7.2 `push_lora.py`

`--run-dir DIR --repo ID [--private] [--no-samples] [--all-checkpoints] [--commit-message M]`.
Creates the model repo if needed (`HfApi.create_repo(exist_ok=True)`), uploads with
`upload_folder` and `allow_patterns`: the final `*.safetensors` (newest when there are several,
unless `--all-checkpoints`), `run.json`, `config.yaml`, `samples/*` (unless `--no-samples`), and a
generated `README.md` model card (base model, triggers, steps, rank, profile, dataset name, the
`concept-captioner` version). Prints the repo URL. Exit 1 when no `.safetensors` is found.

### 7.3 Launch wrappers

Section 4.3.

## 8. `podctl`

`podctl [--url URL] [--token T] [--json] <command>`; `URL` from `PODCTL_URL`, token from
`PODAGENT_TOKEN`. Exit 0 on 2xx, 1 on an agent error (the envelope is printed) or a pulled file that fails
its checksum, 2 on usage, 3 on connection failure. `--json` prints the raw response; the default is a compact table.

| command | API |
| --- | --- |
| `health` | `GET /health` |
| `gpus` | `GET /gpus` |
| `plan [--caption] [--train] [--gpu-count N]` | `POST /plan` |
| `services` | `GET /services` |
| `status NAME` | `GET /services/NAME` |
| `start NAME [--gpus 0,1] (--params '{…}' | --params-file F) [--wait]` | `POST /services/NAME/start`; `--wait` polls status until not `running` (pull/push) |
| `stop NAME [--timeout 30]` | `POST /services/NAME/stop` |
| `logs NAME [--tail N] [--follow]` | `GET /services/NAME/logs`; `--follow` re-polls every 2 s and prints new lines |
| `events RUN_ID` | `GET /runs/RUN_ID/events` |
| `files RUN_ID` | `GET /runs/RUN_ID/files` |
| `pull RUN_ID [--to DIR] [--latest \| --include GLOB]` | `GET /runs/RUN_ID/files`, then `GET /runs/RUN_ID/files/PATH` per file; keeps a file only when size and SHA-256 match; never writes outside DIR (default `./RUN_ID`). `--latest`: the newest `*.safetensors` |
| `tensorboard [PATH] [--session]` | `GET /tensorboard/PATH` (default `data/runs`) with the bearer; `--session` does `POST /tensorboard-session` and then sends only the cookie |
| `train aitoolkit|ltx --config run.json --gpus 1,2` | sugar for `start trainer-<x>` with the file as params |
| `caption-up MODEL [--gpus 0]` | sugar for `start vllm` |

Dependencies: `httpx` only. Tests use `httpx.MockTransport` (no network, no agent).

## 9. Testing without a GPU

- `agent/tests/`: pydantic param models and argv builders (pure); `parse_nvidia_smi` on fixture
  text; `plan()` for GPU counts 0, 1, 2, 4 × {caption, train, both}; supervisor with
  `FakeBackend(2)` and fake mode (real subprocesses of `podagent.fakeservice`): start, status,
  logs, stop, double-booking refusal, exit-code capture, orphaned process groups (the fake's
  `orphan` switch leaves a grandchild behind), the `stuck` path and the one-deadline shutdown
  (SIGKILL swallowed by a monkeypatch), the child environment (secrets dropped,
  `CUDA_DEVICE_ORDER`), the inventory-unavailable 503; the minimal events reader on a
  synthetic event file written by a test helper (hand-encoded protobuf; no tensorboard
  dependency); the API with `fastapi.testclient.TestClient` including auth and every error code.
- `podctl/tests/`: argument parsing and output formatting against `MockTransport`.
- Dockerfiles: reviewed by eye; `docker build` is not part of the test suite.

## 10. Decisions taken here (for the owner to veto)

1. `/health` is authenticated like everything else; the proxy is public and the app sends the
   token on its readiness poll anyway.
2. vLLM's API key defaults to `PODAGENT_TOKEN` so port 8000 is never an open endpoint.
3. Train-only on N ≥ 2 GPUs leaves GPU 0 free (the rule's "pinned for the whole session"), with
   an explicit `gpus` list as the override.
4. One instance per service name; the service name is the instance key. Two concurrent training
   runs on one pod are out of scope.
5. Supervisor state is in-memory; a container restart is a clean slate. The volume holds all
   artefacts, so nothing of value is lost.
6. Separate venvs per workload in one image, rather than one venv or sidecar containers.
7. The minimal events reader is the tested baseline; `tensorboard`'s reader is used when
   importable.
