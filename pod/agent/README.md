# podagent

The control agent that runs as PID 1 on a concept-captioner GPU pod. The macOS app (and
`podctl`) talk to it over HTTP on port 8800; it starts and stops vLLM, TensorBoard, the trainers
and the dataset/LoRA transfer scripts, assigns GPUs with `CUDA_VISIBLE_DEVICES`, and summarises
TensorBoard event files. It also proxies the loopback TensorBoard at `/tensorboard/` (a browser
gets a derived, expiring session cookie from `POST /tensorboard-session`) and serves each run's
output directory at `/runs/{id}/files`, so a trained LoRA can be downloaded without a Hub account.
The API is specified in `../docs/POD-SPEC.md`.

```bash
uv venv && uv pip install -e ".[dev]"
pytest -q
ruff check . && ruff format --check .

# run locally with two fake GPUs and no Docker
PODAGENT_TOKEN=local-dev-token-0123 PODAGENT_FAKE_GPUS=2 PODAGENT_WORKSPACE=/tmp/ws python -m podagent
```

Environment:

| variable | meaning |
| --- | --- |
| `PODAGENT_TOKEN` | required; bearer token for every request (>= 16 chars). No token: the agent exits 2. |
| `PODAGENT_FAKE_GPUS` | integer >= 0: use the fake GPU inventory and fake services (no CUDA needed) |
| `PODAGENT_WORKSPACE` | volume root, default `/workspace` |
| `PODAGENT_PREFIX` | where venvs/scripts live, default `/opt` |
| `HF_TOKEN` | inherited by children that talk to the Hub (not by `tensorboard`) |

Children never inherit `PODAGENT_TOKEN` or a stray `VLLM_API_KEY`; vLLM gets its key from its
own params (default: the agent token). Every child also gets `CUDA_VISIBLE_DEVICES`,
`CUDA_DEVICE_ORDER=PCI_BUS_ID` and `HF_HOME`.
