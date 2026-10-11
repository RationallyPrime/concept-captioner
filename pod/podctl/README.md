# podctl

A small terminal client for the pod agent (`../agent`): one subcommand per API call plus a few
sugars, compact tables by default, raw JSON with `--json`. The contract is `../docs/POD-SPEC.md`
§8; the agent's endpoints and error envelope are §2.

```bash
uv venv && uv pip install -e ".[dev]"
pytest -q && ruff check . && ruff format --check .

export PODCTL_URL=https://<pod-id>-8800.proxy.runpod.net   # or http://127.0.0.1:8800 in fake mode
export PODAGENT_TOKEN=...                                   # the token the pod was created with
podctl health
podctl plan --caption --train
podctl caption-up Qwen/Qwen3-VL-32B-Instruct               # = start vllm --gpus 0 --params '{"model": …}'
podctl logs vllm --tail 50 --follow
podctl start pull-dataset --params '{"repo_id": "you/nora7-faces"}' --wait
podctl train aitoolkit --config run.json --gpus 1,2
podctl events nora7-h3-001
podctl tensorboard --session                               # the browser path: handshake, then cookie only
podctl files nora7-h3-001
podctl pull nora7-h3-001 --latest --to ./nora7-lora        # the final LoRA, no Hub account needed
podctl stop vllm
```

`--url`/`--token` override `PODCTL_URL`/`PODAGENT_TOKEN`. Only `httpx` is required.

## Commands

| command | API | notes |
| --- | --- | --- |
| `health` | `GET /health` | key/value listing; nested keys as `runpod.pod_id` |
| `gpus` | `GET /gpus` | `IDX NAME MEM_MIB IN_USE_BY` (`MEM_MIB` is used/total) |
| `plan [--caption] [--train] [--gpu-count N]` | `POST /plan` | at least one of `--caption`/`--train`; `--gpu-count` is only sent when given |
| `services` | `GET /services` | `NAME STATE PID GPUS PORT RUN_ID STARTED EXIT`, idle services included |
| `status NAME` | `GET /services/NAME` | the state object as key/value; `params.*` flattened, secrets arrive redacted |
| `start NAME [--gpus 0,1] [--params JSON \| --params-file F] [--wait]` | `POST /services/NAME/start` | params must be a JSON object (`-` reads stdin); `--wait` polls `status` every 2 s until the state is not `running` and prints the final state |
| `stop NAME [--timeout 30]` | `POST /services/NAME/stop` | `--timeout` 1–90 s between SIGTERM and SIGKILL (the call blocks for the wait; the proxy cuts at 100 s) |
| `logs NAME [--tail N] [--follow]` | `GET /services/NAME/logs` | plain lines, no decoration; `--tail` 1–5000 (default 200) |
| `events RUN_ID` | `GET /runs/RUN_ID/events` | header, then `TAG STEP VALUE COUNT WALL_TIME` sorted by tag |
| `files RUN_ID` | `GET /runs/RUN_ID/files` | `PATH SIZE SHA256 MODIFIED` for every regular file under the run's `output/` |
| `pull RUN_ID [--to DIR] [--latest \| --include GLOB …]` | `GET /runs/RUN_ID/files`, then `GET /runs/RUN_ID/files/PATH` per file | default DIR `./RUN_ID`; files keep their listed relative paths. `--latest`: only the newest `*.safetensors` (push-lora's rule for the final LoRA); `--include` (repeatable, `fnmatch`): only matching paths. Each file streams to `<name>.partial` and is renamed only when its size and SHA-256 match the listing; a file already present with the listed digest is not downloaded again. A listed path with `..`, a leading `/` or an empty segment is refused (exit 2) before anything is written. Prints each local path (`--json`: one document with `local_path` added per file) |
| `tensorboard [PATH] [--session]` | `GET /tensorboard/PATH` (default `data/runs`) | prints TensorBoard's body as-is. `--session` first calls `POST /tensorboard-session`, then sends only the session cookie, no bearer: the request a browser makes |
| `train aitoolkit\|ltx --config run.json --gpus 1,2 [--wait]` | `POST /services/trainer-<x>/start` | the file (POD-SPEC §4.1) is the params, verbatim; the agent validates it |
| `caption-up MODEL [--gpus 0] [--params JSON \| --params-file F]` | `POST /services/vllm/start` | params `{"model": MODEL}`; extra vLLM params merge under it |

`--gpus` is a comma-separated list of distinct non-negative indices. `train` requires it; `start`
defaults to none; `caption-up` defaults to `0` (the topology rule pins vLLM to GPU 0).

### `--follow`

Before every fetch the service state is read, so the loop ends by itself once the service is
no longer `running`, after one last fetch that catches the final lines. New lines are found by
overlapping the previous window with the new one; if the log advanced by more than `--tail`
lines in one 2 s poll the gap is reported on stderr and the lines in between are not shown
(raise `--tail`). With `--json`, each poll that produced new lines prints one logs document
holding only those lines.

### `--wait`

For the one-shot services (`pull-dataset`, `push-lora`, the trainers). The start state is
printed, then the final state. A final state of `failed` exits 1.

## Output and exit codes

Default output is a table or key/value listing: `None` and empty values print as `-`, booleans
as `true`/`false`, integer lists as `0,1`, anything else as JSON. `--json` prints the agent's
response verbatim, one JSON document per line (two for `--wait`, one per poll for `--follow`).
Errors and progress notes go to stderr.

| exit | meaning |
| --- | --- |
| 0 | success |
| 1 | the agent answered with its error envelope (printed on stderr: `podctl: error CODE (STATUS): message`, with `invalid_params` details listed per field; the raw envelope with `--json`); also a `--wait` that ends in `failed`, a pulled file whose size or SHA-256 does not match the listing (nothing is kept), and `pull --latest`/`--include` that selects nothing |
| 2 | usage: missing URL/token, bad JSON, bad `--gpus`, a value outside its documented range |
| 3 | cannot reach the agent: transport error, or a 502/503/504/520–526 that is not the agent's envelope (the RunPod proxy while the pod boots) |
| 130 | interrupted with Ctrl-C during `--wait`/`--follow` |

## Testing

`tests/test_cli.py` drives `podctl.cli.main` against a scripted fake agent behind
`httpx.MockTransport`: `cli.make_client` (the client factory) and `cli.sleep` are module-level
names that the tests replace, so the `--wait` and `--follow` loops run against a fixed sequence
of responses with no real delay. No network, no agent process, no GPU.
