# POD-SPEC — everything that runs on the rented GPU pod

Status: source-aligned contract, 2026-10-11 review repairs. This is the contract the
macOS app, `podctl` and the on-pod code are written against. The app never shells into a pod: everything goes through the
control agent described here. Read `docs/v0.2-plan.md` ("Beyond v0.2") in the repo root for
the product context; `POD-STATUS.md` next to this file tracks what is implemented.

Placeholders throughout use the fixture triggers `NORA7` / `IVAN9`. Nothing here names a real
concept.

The owner's review repairs, including direct dataset upload without a Hub account, are
implemented in source and included in the published `v0.2.3-clean-20261011` image. Earlier r2
images predate these repairs. The owner/Claude's H3 still-image run on v0.2.3 is recorded in
[POD-STATUS](POD-STATUS.md); it does not verify H3 clips, external warm-start, same-run Resume
or matched generation.

## 0. Layout of `pod/`

```
pod/
  agent/        Python package "podagent": FastAPI control agent (port 8800)
  podctl/       Python package "podctl": terminal client over the agent's HTTP API
  images/       Dockerfiles (base, aitoolkit, ltx, fake), entrypoint, compose for fake mode
  scripts/      pull_dataset.py, restore_dataset.py, push_lora.py, launch_aitoolkit.py, launch_ltx.py, generate_results.py,
                model_table.py (reads the model table, 4.4)
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
With saved storage, `mounts.network` attaches the selected `volumeId` at `/workspace` and
`dataCenterIds` selects that volume's location. Without saved storage, `mounts.persistent`
creates a 300 GB pod disk at `/workspace`; placement is not tied to a network-volume data
center. `ports` is `["8800/http", "8000/http"]`. The `env` object carries
`PODAGENT_TOKEN` and, when the user has a Hub token, `HF_TOKEN`, both as RunPod secret
references rather than values: the app writes the Hub token to the account secret
`conceptstudio_hf_token` before every creation (so a rotated token takes effect) and the pod's
generated agent bearer to a per-pod secret `conceptstudio_agent_<random>`, then passes
`{{ RUNPOD_SECRET_<name> }}` placeholders that RunPod substitutes when the container boots
(`account/secrets` in the v2 schema; a secret's value can never be read back). A pod listing
therefore never shows a token. The app deletes the agent secret when it removes the pod and,
at launch, any `conceptstudio_agent_*` secret that no pod references; the Hub secret stays.

Stopping a pod is the app's job; the pod side has no self-stop and no terminate-after guard.
The app keeps the Mac awake while a pod runs; its launch-discovery limits are recorded in
APP-STATUS and ADR-0003.
Its budget and idle watchdog send `POST /v2/pods/<id>/action` with `{"action":"stop"}` and
confirm a stopped status. Removal is a separate, confirmed DELETE operation.
The temporary container disk is cleared on stop/restart. Both network storage and the pod
disk retain `/workspace` files and remain billed while stopped; only the pod disk is deleted
with the pod. Pending results, run history and comparisons use the network volume ID or
`pod:<id>` as their storage identity. A replacement pod cannot recover a different pod's disk.
The app blocks removal while a pod disk holds undelivered training/generated outputs, offers
starting the original stopped computer for retrieval, and retains result metadata across budget
stops. A lost start acknowledgement retains the local training/generation record until
service and file inspection settles its outcome. Failed comparisons with downloaded partial
files release custody only after all available files pass their checksum checks; pending
JPG/WebP outputs are preserved along with PNG/video. Restart preserves accrued GPU spend,
updates its rate from the provider's positive returned cost, excludes stopped time, and applies the selected
whole-computer cap. A paused trainer's run cap becomes active again when training continues.
The catalog request uses `include=AVAILABILITY&product=POD&cloud=SECURE`, requested GPU count
and minimum CUDA; its per-data-center `dataCenters` entries are the stock source. Offers
attached to saved storage must have `LOW`, `MEDIUM` or `HIGH` stock in that storage's data center.
Missing/unknown/NONE stock is not offered. The current v2 schema has no data-center query
parameter on `catalog/gpus`; the screen and creation request apply the exact location.
RunPod `application/problem+json` detail and validation errors are shown with the status.
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

The current catalog (section 3) has nine names: `vllm`, `tensorboard`, `trainer-aitoolkit`,
`trainer-ltx`, `pull-dataset`, `push-lora`, `generate-aitoolkit`, `generate-ltx`, `cleanup-datasets`.
The upload route is not a GPU service. One instance per name at a time; the name is the
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
`api_key` are redacted to `"***"`). `run_id` is set for the trainers, generators and `push-lora`.

`group_alive` is set when the direct child has exited (`failed` / `exited` / `stopped`) but its
process group has not: a trainer whose launch wrapper died, vLLM engine workers after the API
server crashed. The GPUs stay booked (`in_use_by` in 2.4, `gpu_busy` on a start) while it is
set; the agent SIGTERMs the group at the exit, SIGKILLs it 5 s later if it is still there, and
clears the flag once the group is empty. A start of the same service while `group_alive` is
`409 already_running` (detail `{"group_alive": true}`); a `stop` SIGKILLs the group at once.

- `GET /services` → `{"services": [state, …]}` for all catalog names, idle ones included.
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
the bounded 3 s wait. These are agent-side waits, not a guarantee against an earlier runtime
stop deadline or pid-namespace teardown. Forced termination can prevent child cleanup even
when the agent sent SIGTERM first.

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

### 2.12 `GET /runs/{id}/config`

Authenticated run snapshot: `{"run_id": "…", "config": {…}, "dataset": {"repo_id": "…",
"revision": "<resolved commit>", "count": 4}}`. `config` is the saved `run.json` with
top-level `hf_token` and `api_key` removed. `dataset` comes from the captured dataset
manifest. A missing manifest gives an empty dataset object; this is not an invented revision.
The native app stores this snapshot, curves, checkpoint listing, result destination and
available cost estimates in the project's private `.conceptstudio/training.json`.

### 2.13 `GET /storage`

Bearer-authenticated, read-only usage of the filesystem mounted at `PODAGENT_WORKSPACE`:

```json
{"total_bytes": 214748364800, "used_bytes": 68719476736, "free_bytes": 146028888064,
 "datasets_bytes": 10737418240, "reclaimable_dataset_bytes": 2147483648}
```

All values are integer bytes. Filesystem totals include other data on this volume;
`datasets_bytes` counts confined dataset files, not model caches or checkpoints.
`reclaimable_dataset_bytes` uses exactly the cleanup eligibility/retention policy in 3.7.
The app labels usage as storage, separately from its estimated GPU spend, and offers the
explicit `cleanup-datasets` service action. This read never removes anything.

### 2.14 `PUT /uploads/{name}/{file_name}`

For training without a Hub account, the app streams each approved media file, caption/response
sidecar, `metadata.jsonl` and `job.yaml` as a binary body. The agent checks the bearer before
reading the body, just as for existing routes. `name` uses the dataset-name pattern in 3.4;
`file_name` is a single basename, never an absolute path or a path with separators, NUL or dot
segments. Allowed names are supported media suffixes from 7.1, their `.txt`/`.json` sidecars,
and the two named dataset files. The exact initializer slots `initial-lora.safetensors` and
`initial-recipe.json` are also admitted, in a separate stage as described in 4.3. Other
`.safetensors` upload names are refused. The destination is only `/workspace/uploads/<name>/`;
symlinks and resolved paths outside that staging directory are refused. It cannot overwrite
run files, models, logs or another arbitrary workspace path.

Require an accurate `Content-Length`, enforce the count while streaming, and limit each file
to **2 GiB (2,147,483,648 bytes)** and the staged dataset to **20 GiB (21,474,836,480 bytes)**.
This authenticated route is the explicit exception to the ordinary 1 MiB body limit in 2.1;
no JSON/base64 wrapper or whole-file buffering is used. Missing length, a body over either
limit, or a declared/received size mismatch is refused; an incomplete temporary file is
removed. Successful replacement of one staged file is atomic and counted by its final size.
The response is `{"name":"…","file_name":"…","size":123}`. A failed upload leaves other
successfully staged files available for retry.

Uploading does not make the dataset ready. The existing `pull-dataset` service's local mode
(3.4, 7.1) validates the complete metadata-listed set and atomically installs the usual
`datasets/<name>/` layout. Only after that service exits 0 may training start. The finalized
upload staging directory is removed; local inputs carry no invented Hub commit or credentials.
The catalog claims the stage before launching its installer; another upload to that name is
refused until installation settles. Failed installation releases the claim and retains the
staged files for correction/retry.

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
and `push-lora` fakes exit 0 after two seconds; `cleanup-datasets` also finishes). This is how the supervisor, the API and
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
trainer's native config and starts the pinned trainer as a child process. A trainer sees only
its assigned GPUs, so inside the process they are `cuda:0..k-1`.

Starting a trainer whose `run_id` directory already contains `output/` is allowed (the wrappers
resume when the trainer supports it; otherwise they overwrite — see 4.3). The client decides.

### 3.4 `pull-dataset` — GPUs 0

Params (`PullDatasetParams`): `repo_id` (optional str, `^[\w.-]+/[\w.-]+$`), `local_name`
(optional str, dataset-name pattern below), `name` (str, dataset folder
name, `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; default: repo name), `split` (`train`), `revision`
(null), `image_column` (`image`), `caption_column` (`caption`), `id_column` (null),
`hf_token` (null), `only_metadata` (false). argv:
`[/opt/venvs/agent/bin/python, /opt/pod/scripts/pull_dataset.py, --repo, <repo_id>, --to, /workspace/datasets/<name>,
--split, …, --image-column, …, --caption-column, …, (--revision, …), (--id-column, …)]`.
`only_metadata: true` adds `--only-metadata`.
log `/workspace/logs/pull-dataset.log`. Exit 0 = dataset ready at `/workspace/datasets/<name>`.

The native app sends `only_metadata: true` and its last published commit revision for its
imagefolder publication. This requires metadata (`metadata.jsonl`, or the accepted CSV form)
and copies exactly its listed media and matching `.txt`/`.json`
sidecars, including approved MP4 clips. Unlisted repository media is not a training target.
The generic CLI default remains false. The dataset manifest records the resolved Hub commit;
the trainer copies that manifest into its run folder for later run-history reads.

**Local mode.** The same typed catalog entry accepts `local_name` (dataset-name pattern).
Exactly one of `repo_id` and `local_name` is
required; `name` defaults to the repo basename or `local_name`. Local mode derives its source
from `/workspace/uploads/<local_name>/`, not a client-supplied filesystem path, and requires
`only_metadata: true`. It neither accepts a Hub `revision`/token nor makes a Hub call. The
script receives `--local-dir <derived source>` instead of `--repo`; other layout/caption
validation is shared with the Hub imagefolder path. After a successful atomic install it
removes that upload stage. The local manifest has `source: "local"`, `repo_id: null`,
`revision: null`, `requested_revision: null`; counts and `only_metadata: true` remain meaningful.
Hub manifests identify `source: "hub"`. Local manifests also record `input_digest`: SHA-256
over entries sorted by filename UTF-8 bytes, each encoded as
`filename + NUL + decimal byte size + NUL + lowercase file SHA-256 + newline`. All uploaded
files, including metadata, sidecars and the job, participate. The app records this digest
privately in its run history; it is not a shared job field or a synthetic Hub revision.
A local Resume reuploads the exact saved inputs and checks this digest on both sides. Edited
inputs require Repeat as a new run. A pruned local dataset cannot be re-pulled from the Hub.
This avoids a Hub account for training-data transfer; base-model acquisition and its access
requirements remain unchanged.

### 3.5 `push-lora` — GPUs 0

Params (`PushLoraParams`): `run_id`, `repo_id`, `private` (true), `include_samples` (true),
`all_checkpoints` (false), `commit_message` (null), `hf_token` (null). argv:
`[/opt/venvs/agent/bin/python, /opt/pod/scripts/push_lora.py, --run-dir, /workspace/runs/<id>, --repo, <repo_id>,
(--private), (--no-samples), (--all-checkpoints), (--commit-message, …)]`.
log `/workspace/logs/push-lora.log`. Exit 0 = the model repo has the LoRA.

### 3.6 `generate-aitoolkit` and `generate-ltx` — GPUs 1

These fixed services run `generate_results.py` in the corresponding trainer interpreter;
they expose no port and use the same supervisor/GPU reservation as training. The typed
`GenerationParams` model forbids extra fields:

| field | type / bounds | default |
| --- | --- | --- |
| `run_id` | new run ID, `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; distinct from `source_run_id` | required |
| `source_run_id` | existing run ID, same pattern | required |
| `checkpoint` | nonempty relative path under the source run's `output/`; regular `.safetensors`, no symlink in any component | required |
| `prompts` | list of 1–6 nonblank strings, each at most 4000 characters; no NUL or `--` overrides | required |
| `seeds` | list of 1–4 integers, each 0–4,294,967,295 | required |
| `width`, `height` | integers 64–2048, each a multiple of 32 | 512, 512 |
| `inference_steps` | integer 1–100 | 20 |
| `guidance_scale` | number 0–20 | 4 |
| `num_frames` | integer 1–257; the source model's frame law from the model table (4.4): FLUX requires 1, LTX requires 8n+1, H3 accepts 1 or 17n+5 (5–243) | 1 |
| `frame_rate` | number greater than 0 and at most 60; a model with a fixed cadence requires it (H3: exactly 24) | 24 |

Validation refuses an existing generation directory and an unavailable source config or
checkpoint before `prepare()` creates anything. Prompt override refusal preserves identical
requested settings for both arms; prompts are argv values, never shell input.

A source run is admitted when the model table (4.4) has a row for its `base_model` on this
trainer that names a `generator` hook: today `black-forest-labs/FLUX.1-dev`
and `Comfy-Org/MiniMax-H3` on AI Toolkit, and `Lightricks/LTX-2` on LTX.
Other models return `422 invalid_params` before creating a generation run, naming the trainer's
default model (`This generation path supports <model_ref> checkpoints only`). The frame count and frame
rate are then checked against the row's `video` law and fixed cadence, in this order: an
image-only row takes `num_frames` 1; a video row takes 1 frame (when it previews stills) or
`first + k·step` frames; a fixed cadence takes exactly that rate. The `minimax_h3` and
`aitoolkit_arch_image` hooks also require the source run’s saved `native-config.json`; preparation
captures it as private `source-native-config.json`.
Its training dataset may contain stills, clips or both; output choice is independent: 1 frame
produces PNG, 17n+5 frames produce MP4 at 24 fps.
The checkpoint must be a regular, non-symlink `.safetensors` output of the source run.
Preparation captures `source-run.json` and `selected-checkpoint.safetensors` privately in the
new run directory. `generation.json` contains the validated/defaulted request fields above
plus `checkpoint_sha256`, computed from that copy. The script checks that SHA before use.
argv is `[/opt/venvs/<trainer>/bin/python, /opt/pod/scripts/generate_results.py, --trainer,
<trainer>, --config, /workspace/runs/<id>/generation.json]`; cwd is the generation run,
log is `trainer.log`, and the existing authenticated file APIs serve only `output/`.

`output/comparison.json` has these exact fields:

| fields | meaning |
| --- | --- |
| every `GenerationParams` field above | the requested comparison batch, including selected source checkpoint path |
| `checkpoint_sha256` | SHA-256 of the captured selected checkpoint |
| `trainer` | `aitoolkit` or `ltx` |
| `base_model` | supported source run base model ID |
| `upstream_revision` | pinned inference implementation revision |
| `source_config` | captured source `run.json`, with top-level credential fields removed |
| `effective_native_config` | H3 only: allowlisted effective model/network/train quality settings and per-dataset frame/fps/resolution settings; private paths omitted |
| `comparison_training_adapter` | H3 only: false; the frozen training assistant is omitted from both inference arms |
| `state` | `generating`, `complete`, or `failed` |
| `pairs` | list of `{prompt, seed, base_path, lora_path}` |

Pairs enumerate prompts in request order, with seeds in request order inside each prompt.
Paths are relative to this run's `output/`: `pair-000-base.png` / `pair-000-lora.png` for
FLUX or H3 stills; `.mp4` for LTX or H3 video, then index 001 onward. `complete` is written
only after every expected file exists. Exceptions inside the inference block write `failed`
and retain available outputs. Current pre-inference validation failures can precede manifest
creation; this is not a successful empty comparison.

**Consumer requirement:** the app reads this
manifest's state, requires `complete` and every listed pair for a saved successful comparison,
and displays `failed`/incomplete output as such. A PNG or MP4 existing alone is not success.

FLUX uses the pinned AI Toolkit `StableDiffusion`, `ModelConfig`, `GenerateImageConfig`
and explicit flowmatch scheduler. It loads the base and then the selected LoRA fused before
quantization. LTX uses the pinned official `ltx_pipelines.ti2vid_one_stage` CLI with fixed
FP8 casting and CPU offload; only the trained side receives `--lora <checkpoint> 1.0`.
Inference uses the captured configuration and checkpoint even if retention already pruned
the source training dataset; it neither requires nor restores those training inputs.
The app defaults to 49 frames for LTX, offering 17/49/97/129 at 24 fps. Those settings are
request choices, not evidence of capacity on every GPU. Offline source verification and
actual GPU execution are recorded separately in POD-STATUS.

### 3.7 `cleanup-datasets` and pre-start cleanup

No timer and no arbitrary delete path. Every trainer/generator start performs the same
validated dataset-cleanup step before preparation/spawn, after request and reservation
validation. An explicit CPU catalog service `cleanup-datasets` accepts `params: {}` and
`gpus: []`, uses fixed argv in the agent interpreter, and reports its removed dataset names
and reclaimed bytes in its log. It uses the same policy as automatic cleanup and `GET /storage`.

Only dataset folders referenced by **terminal completed training runs** are eligible. Unknown,
active, failed or interrupted runs are preserved; lack of terminal-completion evidence after
an agent restart is not permission to delete. Resolve every candidate beneath `paths.datasets`
and reject symlinks. Always keep the requested current run's dataset, a generator's source
dataset, every active run's dataset, and datasets for the **last three resumable completed
runs**, ordered newest first by checkpoint modification time with run ID as the tie-breaker.
A dataset shared with any protected run remains protected. Cleanup never removes checkpoints,
training-state files, run configs/manifests/logs, generated comparisons or model caches.
Unattributed datasets and in-progress upload stages are not cleanup candidates.

The supervisor persists `run-state.json` with `name`, `run_id`, `state`, `exit_code` and
`group_alive`. Eligibility requires a matching trainer/run ID, `state: exited`, exit code 0
and `group_alive: false`; the marker is invalidated before a new trainer incarnation starts.
Missing/unreadable metadata remains protected. Only direct dataset-directory children with
valid run-name syntax are pruned; custom nested layouts stay intact. Storage reads refresh
observed terminal state before calculating eligibility, but do not delete files.

Resume of a pruned Hub dataset uses the source run's saved `dataset-manifest.json`: the exact
`repo_id`, resolved commit `revision`, split, columns, ID column and `only_metadata` setting,
re-pulled into the saved dataset path before the trainer starts. Missing pinned source facts
cause a clear refusal, never a pull of current `main`. Local mode recovery is defined in 3.4.

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
  "resume": false,
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
| `dataset.path` | yes | | must resolve under `/workspace/datasets/`; approved images/clips + `<stem>.<caption_ext>` sidecars (what `pull_dataset.py` produces) |
| `dataset.caption_ext` | no | `txt` | |
| `triggers` | yes | | ≥ 1; preserved as run metadata; captions contain their actual mapped concepts. No global first-trigger injection |
| `profile` | no | null | informational: which caption profile produced the captions; stored in `run.json` and the model card |
| `base_model` | yes | | Hub id or `/workspace/models/<dir>`. No default: the H3 vs FLUX vs LTX choice is the user's |
| `steps` | no | 2000 | |
| `learning_rate` | no | 1e-4 | |
| `rank` | no | 16 | LoRA rank; `alpha` defaults to `rank` |
| `resolution` | no | `[512, 768, 1024]` | int or list; LTX takes the largest as its bucket |
| `batch_size` | no | 1 | |
| `gradient_accumulation` | no | 1 | |
| `seed` | no | 42 | |
| `resume` | no | false | true opts into saved settings/checkpoint validation before service start; it keeps the same run ID and dataset |
| `initialization` | no | null | AI Toolkit H3 new-run preload: `{name,lora_sha256,recipe_sha256}` identifies the two fixed staged artifacts; never a client filesystem path |
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
conventional FLUX-LoRA starting point from ai-toolkit's example configs. H3 has the explicit
BF16 quality recipe and target-driven grouping below. Native LTX uses its measured memory
preset. None is a universal fit or training-quality promise.

**Live evidence and remaining uncertainty** (full receipts and exact image revisions are in
`POD-STATUS.md`):

- AI Toolkit: FLUX produced real checkpoints, loss, Resume and matched generation. H3 completed
  one owner/Claude-reported 3,000-step still-image run on 69 stills with the published
  `v0.2.3-clean-20261011` image; its LoRA was published privately and the pod was stopped. This
  verifies that still-image train/publish/stop path only. H3 clips, external warm-start, same-run
  Resume and matched generation remain unverified on hosted hardware. The single run on one
  96 GB RTX PRO 6000 does not establish general model quality or capacity for other settings.
- LTX-2: the pinned trainer's entrypoints, `caption`/`media_path` preparation, one-frame
  buckets, mapped training keys, nested checkpoints and scraped TensorBoard events ran on
  real hardware. A 512-pixel/rank-16 run passed on one visible 32 GB GPU in a 125 GB host.
  The trainer venv requires TensorBoard explicitly; the image tests an actual event write/read.
- Other model families and capacity beyond the measured runs remain unverified. LTX’s approved
  video training, Resume and paired generation have separate real receipts. These functional
  checks do not establish universal memory capacity. Resume evidence and its exact scope are
  recorded separately in `POD-STATUS.md`.

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
| `triggers` | run metadata only; no `process[0].trigger_word` is injected |
| `rank`, `alpha` | `network.{type: lora, linear, linear_alpha}` |
| `save_every` | `save.save_every` (+ `dtype` and `max_step_saves_to_keep` from the model's row; FLUX `float16`, 4) |
| `dataset.path`, `caption_ext`, `resolution` | `datasets[0].{folder_path, caption_ext, resolution, cache_latents_to_disk: true, caption_dropout_rate: 0.05}` |
| `steps`, `learning_rate`, `batch_size`, `gradient_accumulation` | `train.{steps, lr, batch_size, gradient_accumulation_steps}` + `dtype`, `optimizer`, `gradient_checkpointing` from the model's row (FLUX `bf16`, `adamw8bit`, `true`), `noise_scheduler: flowmatch`, `train_text_encoder: false` |
| `base_model` | `model.name_or_path` (+ the row's `arch`, extra model keys and `quantize` / `quantize_te`; FLUX `arch: flux, is_flux: true, quantize: true`; H3 uses the pinned `minimax_h3` BF16 recipe below) |
| `sample_every`, `sample_prompts`, `seed` | `sample.{sample_every, prompts, seed, width/height = max(resolution), sampler: flowmatch, guidance_scale: 4, sample_steps: 20}` |
| `extra` | deep-merged last |

Command: `/opt/venvs/aitoolkit/bin/python /opt/ai-toolkit/run.py <run>/config.yaml`.


**H3 quality and exact targets.** `Comfy-Org/MiniMax-H3` selects the pinned registered
`minimax_h3` model. The default quality recipe uses BF16 model/text encoder, `quantize: false`,
`quantize_te: false`, `low_vram: false`, `fl2va_pruned`, AdamW/flowmatch/sigmoid, weight decay
0.01, constant warmup (35 steps), text-embedding/latent caching and the transformer block
20–49 qkv/out/fc1/fc2 subset. The four model binary assets are pinned to
`e5eb578a89295337b8ff433a035929ce0279e0b6` under `/workspace/models/h3-bf16-quality`:
pruned BF16 DiT, BF16 Qwen3-VL encoder and the FP16 video/FP32 audio VAEs. The frozen
image-training adapter is pinned to `circlestone-labs/MiniMax-H3-Image-Training-Adapter`
revision `7c6c04f75ba597232d4ce2bb4a14709948ec723a`. The pinned model implementation itself
resolves original tokenizer/processor/config files from `MiniMaxAI/MiniMax-H3`.
Only binary asset filenames are declared in the shared recipe resource; a supplied old
component/assistant filename must match those known assets before native import replaces paths.
No old pod path is treated as an already-installed model.

`h3_dataset.py` verifies complete decoded frame counts/timing with `ffprobe` before model
download. Clips require 5–243 frames on the 17n+5 grid, exactly 24 fps with uniform decoded
intervals (1 µs decimal rounding tolerance), and positive 32-aligned dimensions. Their area
must fit `max(resolution)²`; otherwise refuse and ask for a larger cap or re-approved smaller
input. The pinned bucket code then keeps exact width/height (scale 1), rather than cropping.
Private input views group by actual frame count: each native dataset uses that explicit N,
`auto_frame_count: false`, `shrink_video_to_frames: true`, `fps: 24`. N equal to the actual
count makes upstream frame selection i→i, with no trim/resampling. Clip groups enable
`do_audio`; stills have a separate one-frame group and retain the requested image resolution
array. The default audio loss multiplier is 0 for still-only inputs and 1 when clips are
present; an explicit imported/advanced recipe can override it. Source clips and audio bytes
are retained; joint-audio optimization through this new path is still a hosted-test gap.
`h3-inputs.json` records admitted target dimensions/counts and `native-config.json` atomically
records the effective native configuration before launch. H3 uses native
`gradient_accumulation`, avoiding its mutually exclusive `gradient_accumulation_steps` key.

**External H3 weights initialize a new run.** Upload exactly `initial-lora.safetensors` and
`initial-recipe.json` to a distinct `init-<UUID>` stage using 2.14. The canonical recipe has
exactly four sections: `model`, `network`, `train`, `dataset`. One authoritative field/asset
policy is bundled at `app/Sources/ConceptStudio/Resources/Training/h3-recipe-fields.json` and
copied unchanged into pod scripts. No raw job/meta/output/Hub/credentials, old paths,
counters or start-step settings cross this contract. The native original recipe remains a
private project artifact. Its model must identify `Comfy-Org/MiniMax-H3` / `minimax_h3` /
`fl2va_pruned`; supplied components must be known BF16 assets. `use_training_adapter` is a
boolean, not an arbitrary assistant path.

The request’s `initialization: {name,lora_sha256,recipe_sha256}` binds both fixed uploads by
lowercase SHA-256. Agent admission requires a NEW run directory and a matching actual H3
Comfy/native PEFT A/B safetensors header/rank. Preparation claims the stage, captures both
artifacts privately outside `output/`, verifies the copies and releases the stage. Normal
local dataset installation refuses initializer slots; they never enter the media manifest.
The native import retains supported `save.save_every`, `save.max_step_saves_to_keep`, saved
`dtype`, `train.do_guidance_loss`, `train.guidance_loss_target`, and all image-resolution
buckets. Advanced controls edit these values and positive training step/rank/batch values
directly. H3 app defaults are 300-step saves, 40 retained checkpoints, float32 saved weights,
768 and 1024 image buckets and guidance off. The current Circlestone training adapter
requires guidance preservation loss to remain off; Advanced shows this requirement. Only
an imported native recipe with explicit `model.use_training_adapter: false` exposes the
guidance toggle and target (default 3.5). App import, training and resume reject adapter-on
(or omitted/default-on) plus guidance-on before transferring inputs. A native recipe that
omits `use_training_adapter` used the adapter only if it names `assistant_lora_path`; the
import writes that actual choice explicitly into the canonical settings. The pod wrapper
checks the effective merged recipe before downloading model assets. Zero retention keeps all
checkpoints. FLUX/LTX defaults stay unchanged. Saved precision affects exported weights,
independently of BF16 training precision. The previous v1 recipe/runtime enabled guidance
with target 3.5; the exact v2 recipe, verification wrapper and runtime receipt disabled it,
as did the successful v3 app run. The historical v1 combination is not supported by the
current Circlestone adapter contract. Imports keep their actual supported settings; the
unsupported adapter/guidance combination is refused with an explanation.

Editable save settings and guidance target travel in the existing `run.json.extra` shape;
`save_every` is also supplied at the existing top level. The fixed canonical initializer
retains its four original sections and excludes `save` and `train.guidance_loss_target`;
run.extra supplies those editable values after initializer loading. This keeps the published
`v0.2.3-clean-20261011` validator contract. The imported quality settings are preserved in
`run.json.extra`; final requested rank, alpha, LR, steps, batch and accumulation are authoritative. Rank must match starting weights;
selector settings must not exclude loaded LoRA modules. The wrapper forces current run,
approved dataset views/output and a fresh start at 0, setting the pinned upstream
`network.pretrained_lora_path` to its captured private file. It is not a frozen assistant
and not same-state Resume; no old optimizer/counter state is loaded. Existing same-run
Resume retains the immutable initializer binding but does not need or re-upload its stage;
it uses the captured pair and removes fresh `start_step: 0` so the real saved step restores.

The new app controls send explicit values through the published image's existing merge
contract. [The exact-image-source witness](../../docs/process/walkthrough-gpu-source-witness-2026-10-12.json)
executes old `b7908618` validators/native config generation offline with the new params and
canonical initializer. It proves source acceptance and effective config values, including
fresh start at zero; it does not claim image execution or GPU/training quality. The source's
additional effective-save fields in comparison receipts, implicit script H3 defaults and
server-side adapter/guidance guard need an image rebuild. Valid guidance-off requests use
the existing image contract; the app enforces the guard before submission. The app works without that optional receipt addition; existing captured
`run.json.extra` and native configuration retain the submitted settings. Image publication
remains separately owned and has not been performed by this walkthrough implementation.

H3 generation privately captures the effective native model/network recipe and selected
checkpoint. It creates the pinned registered model and an actual `LoRASpecialNetwork` with
the trained rank/alpha/selectors/target modules and `base_model=sd`. Upstream `load_weights`
then converts Comfy `diffusion_model.*.lora_A/B` keys. The assistant is omitted on both arms;
the same live network uses multiplier 0 and 1, with merge disabled, identical requested
prompts/seeds/geometry/steps, and the pinned H3 scheduler. `model.lora_path` is not used.

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

**Approved video targets.** The app sends `extra.preprocess.buckets_from_media: true`
instead of a fixed video bucket. The shared preprocess policy accepts only a boolean and
rejects combining it with `resolution_buckets`. Before downloading a model or launching
preprocessing, the wrapper counts each approved clip's actual decoded frames with `ffprobe`
and derives its `width×height×frames` bucket. Video dimensions must be multiples of 32,
frame counts 8n+1 from 9 through 257. Still images add the ordinary square one-frame bucket.
The native segment editor approves constant-rate selected segments only, exports and
re-counts that exact segment, preserves sample timing and audio, and fits the full picture
into a 32-aligned aspect-preserving canvas before captioning. Both native approval and the
wrapper refuse variable-rate timestamps: pinned `video_utils.read_video` discards frame PTS
and supplies `stream.average_rate` to the trainer. The wrapper checks every decoded interval
and the final interval against that rate within container timestamp rounding tolerance.
Choose a constant-rate source or portion; no automatic retiming is performed. Common HD footage can therefore use 512×288 or 288×512, rather than an unseen
square center crop. Changing the target requires approval, captioning and publishing again.
The included memory-saving training preset skips audio optimization; video/audio bytes in
the approved target are retained. This is a visual/motion LoRA path, not an audio-training proof.

Custom explicit video buckets remain possible through the agent. Their preflight applies
the pinned preprocessor's actual bucket selection (aspect difference, then frame count,
then area among fitting buckets) and refuses any choice that would truncate frames or
change the approved clip's aspect ratio. No temporal subsampling flag is exposed.

**Selected checkpoint custody.** Generation preparation privately captures the selected
checkpoint and sanitized source run configuration before either inference variant starts.
A resume on another GPU cannot change those inputs between base and LoRA sampling. The
comparison manifest records the captured checkpoint SHA-256 and source settings. The large
private checkpoint copy is outside the run output directory and is not offered by the
files/download API. `generate_results.py` owns its cleanup before source/config validation
and installs a SIGTERM handler that raises into the cleanup scope.
Normal completion, handled errors, and normal Stop/SIGTERM finalize any existing manifest
(`failed` on interruption) and remove the private checkpoint copy. SIGKILL, abrupt runtime
teardown, host failure or a failure during preparation can still leave a private copy; no
`finally` block guarantees cleanup after forced termination. Preserve source-run checkpoint
bytes and completed output files in every case.

**Repeat and Resume.** Repeat prefills editable native settings and the saved dataset
revision, then creates a new run and dataset folder. Resume sends `resume: true` with the
same run ID; dataset, model, triggers, rank/alpha, learning rate, resolution, batch size,
accumulation, seed, `extra` and initializer provenance must match the saved run. It requires a checkpoint; LTX also
requires the matching `training_state_step_<digits>.pt`. The pinned LTX trainer restores
scheduler/RNG/step from its default minimal state; full optimizer state requires upstream's
full-state option. AI Toolkit finds the newest matching save by creation time, restores
LoRA weights and `training_info.step`, and loads `optimizer.pt` when available. Neither
path promises bit-identical continuation. The established start/restart API remains
available without the stricter Resume opt-in. Historical records are project-owned; the
global pod record retains billing/pending-output custody and cannot import a comparison
into another project's history or results folder.

Explicit LTX Resume refuses a saved `extra.model.load_checkpoint` override (including null)
and `extra.checkpoints.no_resume: true`: either can bypass the selected saved state in the
pinned trainer. `no_resume: false` remains valid. Ordinary starts and Repeat retain their
existing configuration behavior. AI Toolkit Resume likewise refuses custom checkpoint layouts.

**Resume step requirement:** `resume: true`
must request a total `steps` strictly greater than the checkpoint's saved training step.
Use AI Toolkit's checkpoint `training_info.step`, or LTX's `step_<digits>` checkpoint with
its matching training-state file; unknown/unreadable step information is a refusal, not zero.
Reject a no-op or regressing request as `422 invalid_params` before dataset cleanup, re-pull
or spawning. The catalog checks checkpoint/state existence, immutable settings, saved step
and the missing dataset's recovery facts before preparation. Both wrappers use
`restore_dataset.py` to restore a pruned dataset, then validate its presence again before
starting the trainer. The missing-folder recovery requirement is in 3.7; it does not authorize changing model, dataset revision or
hyperparameters under Resume.

### 4.4 The model table (`scripts/model_table.py`, `scripts/model-table.json`)

Which models exist, and what each one needs, is one JSON file read by the app, the agent and
the scripts: `docs/model-table.md` is its format and the checklist for adding a model. The file
is `app/Sources/ConceptStudio/Resources/Training/model-table.json`, which the app bundles; both
images `COPY` it to `/opt/pod/scripts/model-table.json`. `model_table.py` (stdlib only, answers
`--help` like every script) reads that image path when it exists, else the file in the checkout
it sits in. The wrappers run under `python -I` and cannot import siblings, so they load
`model_table.py` with `runpy` the way they load `h3_recipe.py`; the agent loads it from
`paths.scripts`, else the checkout (`catalog._model_table`). Order of rows is order of the
family match and of the names in messages.

Three lookups, and which site uses which:

- **Exact row**, `model_ref` equal to `run.json`'s `base_model` on the service's trainer. Hooks,
  generation, the recipe keys and the first choice for the `model` block use it.
- **Effective row**, the exact row or the trainer's `default_model`. Capabilities use it (the app).
- **Family match**, AI Toolkit only: when there is no exact row, the first row whose
  `family_match` fits the lowercased name (`flux`; `minimax`, `hailuo` or the token `h3`) supplies
  the `model` block, so custom paths such as `/workspace/models/MiniMax-H3` still get
  `arch: minimax_h3`. It never enables a hook, generation or any other row behaviour. A name that
  matches nothing gets `name_or_path` only, and `extra.model.arch` has to supply the rest.

What the pod does with a row:

| Site | Reads |
| --- | --- |
| `launch_aitoolkit.py` `model_block` | `architecture`: `arch`, `model_extra` (in order), `quantize`, `quantize_text_encoder` (written as `quantize_te` when not null) |
| `launch_aitoolkit.py` `build_native_config` | for an exact row without a `trainer_config` hook: `train.dtype`, `train.gradient_checkpointing`, `train.optimizer`, `save.dtype` (when not null), `save.max_step_saves_to_keep`, then the row's `trainer_options.process` keys deep-merged, written over the skeleton before `extra` merges (`extra` wins) |
| `generate_results.py` | the exact row with a `generator` hook, else `Generation supports <display names>`; the row's frame law and cadence; for `aitoolkit_image`, the row's model settings; for `aitoolkit_arch_image`, the saved native config |
| `push_lora.py` `model_card` | `license`: with `show_notice`, `license: other`, `license_name`, `license_link` in the front matter and a closing `## Licence` section; `usage_note`: the last paragraph of `## Use`; otherwise the card is unchanged |
| `catalog.py` | the exact row for generation admission (above), external initialization (a `native_recipe` hook), and the `trainer_config` / `generator` hooks' preparation |

**Hooks.** A hook is a named strategy for one concern; the row names it, `model_table.HOOKS`
registers the names and each consumer keeps its dispatch beside the code that calls it. A name
the registry does not know fails in `hook()`. No other code tests a model's name.

| Concern | Name | Pod implementation |
| --- | --- | --- |
| `trainer_config` | `minimax_h3` | `launch_aitoolkit.TRAINER_CONFIG_HOOKS`: `minimax_h3_trainer_config` (H3 quality recipe, dataset groups, initialization, guidance check, model config) and `minimax_h3_prelaunch` (`h3_recipe.download_assets`); the agent's half is `catalog._minimax_h3_trainer_config` (the effective recipe written into run.json) |
| `native_recipe` | `minimax_h3` | `catalog._NATIVE_RECIPE_RULES`: external initialization is admitted for the row, read through `h3_recipe.read_initialization` |
| `generator` | `aitoolkit_image` | `generate_results.flux_generate`: still images through ai-toolkit with the row's model settings |
| `generator` | `aitoolkit_arch_image` | `generate_results.arch_generate`: still images from the model class `get_model_class` returns for the row's `arch`, with the trained LoRA bound as a network (`bind_h3_network`, the trainer's own construction) from the saved native config; base side at network multiplier 0. The agent requires and captures `native-config.json` |
| `generator` | `ltx_one_stage` | `generate_results.ltx_generate` / `ltx_command` |
| `generator` | `minimax_h3` | `generate_results.h3_generate` and `h3_manifest`; the agent requires and captures `native-config.json` |
| `run_extra` | `ltx_video_buckets` | none: the app applies it |

Trainer-level code does not read the table: the launchers' shared block, `launch_ltx.py`,
`ltx_rules.py`, `h3_recipe.py`, `h3_dataset.py`, `checkpoints.py`, `storage.py`, `plan.py` and the
service catalog's trainer entries. The LTX-2 and H3 rows mirror pins and recipes those files own.

## 5. GPU inventory backend

```python
class GpuInfo(BaseModel):
    index: int
    name: str
    memory_total_mib: int
    memory_used_mib: int
    uuid: str | None


class GpuBackend(Protocol):
    kind: str  # "nvidia-smi" | "fake"

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
  uploads/<name>/         flat authenticated staging files; removed after successful local installation
  datasets/<name>/        approved media, <stem>.txt/.json, metadata.jsonl, manifest.json, optional job.yaml
  runs/<training-id>/     run.json, dataset-manifest.json, config.yaml, trainer.log, tensorboard/, output/, preprocessed/ (ltx)
  runs/<generation-id>/   generation.json, source-run.json, private selected-checkpoint.safetensors, trainer.log
    output/              comparison.json, pair-NNN-base.png/mp4, pair-NNN-lora.png/mp4
  models/hf-cache/        HF_HOME for every child (vLLM weights, base models)
  models/<dir>/           user-placed local models
  logs/                   vllm.log, tensorboard.log, pull-dataset.log, push-lora.log, podagent.log
```

`PODAGENT_WORKSPACE` overrides `/workspace` (tests, local runs). Every path a client supplies
(`dataset.path`, `logdir`) must resolve under the workspace; the catalog rejects anything else
(`invalid_params`).

Trainer samples/checkpoints sit in their native layout under `output/`; generated comparison
files use the separate generation run. File list/download paths are relative to `output/`,
so private captured weights/config outside it are not served. The upload
stage installs into the existing dataset layout; it is not a new
training format. Dataset cleanup/retention is defined once in 3.7.

## 7. Scripts

### 7.1 `pull_dataset.py`

`(--repo ID | --local-dir DIR) --to DIR [--split train] [--revision R] [--image-column image] [--caption-column caption]
[--id-column C] [--job-path concept-captioner/job.yaml] [--only-metadata] [--require-captions]`.
Token from `HF_TOKEN`. The authenticated catalog does not expose `--require-captions`; its
client can read the reported caption counts.

Two conventions, detected from the repo's file list (`HfApi.list_repo_files`):

1. **imagefolder**: media files plus `metadata.jsonl` (`file_name`, `caption` or `text`), or
   `metadata.csv` (JSONL wins in a folder containing both). `snapshot_download`, then copy
   media into `DIR` flat (subfolders flattened with `__`; name/stem collisions are errors),
   copy matching response `.json` sidecars and write `<stem>.txt` from the caption field or
   source sidecar. Multiple metadata folders are filtered by `split` when a matching folder
   exists. Without `--only-metadata`, unlisted nonhidden media is also copied, using its
   sidecar captions. With it, metadata is mandatory and only its listed files are copied;
   missing listed files or paths escaping the snapshot are errors.
2. **parquet / arrow**: `datasets.load_dataset(repo, split=…, revision=…)`; sample id per
   `concept_captioner.sources.hf._sample_id` rules (`--id-column`, else `file_name`/`filename`/
   `image_id`/`id`/`name`, else the row index); image bytes written with their original suffix
   (PNG when unknown); caption from `--caption-column` when present and non-empty; an existing
   `<caption-column>_response` column becomes the response `.json` sidecar. At this snapshot,
   `--only-metadata` filters the imagefolder collector only; the tabular/loading-script branch
   still follows its rows. The app's publication is imagefolder, so its exact included set
   uses the metadata path above.

Supported file suffixes, case-insensitively, are **`.png`, `.jpg`, `.jpeg`, `.webp`, `.mp4`,
`.mov`, `.m4v`**. This applies to generic CLI/`podctl` pulls as well as metadata-only app
pulls; clips are not restricted to `only_metadata`. Bytes are copied unchanged, with no
cropping, trimming, retiming or training-compatibility claim. LTX validates approved clip
dimensions/frame timing in 4.3; image-only trainer use of clips is refused by the native app.

Always written: `metadata.jsonl` (`file_name`, `caption`) regenerated from what landed, and
`manifest.json` (`source`, `repo_id`, resolved `revision`, `requested_revision`, `only_metadata`, `split`,
`convention`, `image_column`, `caption_column`, `id_column`, `count`, `with_caption`,
`without_caption`, `job_yaml`, UTC `pulled_at`). `job.yaml` is fetched from `--job-path` when
the repo has it (so the trainer wrapper and the model card can read triggers and profile). Exit 1 and a message on any image without a
caption when `--require-captions` is passed; otherwise the counts tell the client.

The destination is replaced through a sibling `DIR.partial` stage and `DIR.old` rename.
Failure while collecting/writing removes the stage and preserves the prior dataset; a
successful re-pull removes stale old media. `--require-captions` is checked after the new
folder is installed, so that particular exit 1 leaves the new incomplete dataset inspectable.
Local mode uses the same collector, write and atomic-install behavior under the confined
agent upload source, without Hub calls; its contract and additional `input_digest` are in 3.4.
Unlike optional `--require-captions` for generic Hub pulls, local mode requires a nonempty,
fully captioned set before installation and preserves the previous dataset on failure.

### 7.2 `push_lora.py`

`--run-dir DIR --repo ID [--private] [--no-samples] [--all-checkpoints] [--commit-message M]`.
Creates the model repo if needed (`HfApi.create_repo(exist_ok=True)`), uploads with
`upload_folder` and `allow_patterns`: the final `*.safetensors` (newest when there are several,
unless `--all-checkpoints`), `run.json`, `config.yaml`, `samples/*` (unless `--no-samples`), and a
generated `README.md` model card (base model, triggers, steps, rank, profile, dataset name, the
`concept-captioner` version). When the base model's row in the model table (4.4) has
`license.show_notice`, the card also carries the licence (front matter and a closing `## Licence`
section). Prints the repo URL. Exit 1 when no `.safetensors` is found.

### 7.3 Launch wrappers

Section 4.3.

### 7.4 `generate_results.py`

`--trainer aitoolkit|ltx --config /workspace/runs/<generation-id>/generation.json`.
The catalog prepares and confines this file; no listener or arbitrary command API is added.
The script reads the captured `source-run.json`, verifies the private checkpoint SHA-256,
and calls the pinned inference implementation for the two arms with the same requested
prompts, seeds, dimensions, steps and guidance. Generation output/manifest details are in
3.6; selected-checkpoint custody and cleanup behavior are in 4.3.

Exit 0 requires every expected output file and `state: "complete"`. An inference exception
writes `failed`, retains any output files, and returns a nonzero service exit. The current
CLI reports filesystem/value/subprocess failures as one stderr line with exit 1. A captured
checkpoint or config failure before the inference scope can leave no comparison manifest;
consumers must never reinterpret that as success.

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
