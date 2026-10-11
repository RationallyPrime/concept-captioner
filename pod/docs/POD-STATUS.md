# POD-STATUS

State of the pod side after the 2026-10-11 fix round; live checks date from lab commit
`e620882` (2026-10-10, last live read 21:26 UTC). The
contract is [POD-SPEC.md](POD-SPEC.md). The day-by-day record, with every timestamp, digest,
hash and billing bucket, is in
[status-history-2026-10-10.md](../../docs/process/status-history-2026-10-10.md#pod-status).

## What exists

- **Control agent** (`pod/agent`): authenticated HTTP API for GPU inventory, topology plan,
  a fixed service catalog (vLLM, both trainers, TensorBoard), supervisor, logs and training
  events. TensorBoard listens on loopback and is reached only through the agent's
  authenticated `/tensorboard/` proxy. vLLM and LTX preprocessing arguments are allowlisted.
- **Transfer scripts and trainer wrappers** (`pod/scripts`): Hub dataset pull, AI Toolkit
  (FLUX) and LTX launchers, LoRA push.
- **podctl** (`pod/podctl`): command-line client for the agent.
- **Images**, public on GHCR under tag `v0.1.0-verify20261010`: `concept-captioner-pod-base`,
  `-aitoolkit`, `-ltx`; plus a fake image for compose tests. Public RunPod template
  `87fxs5v8fn` points at the base image; it carries no token, and the agent refuses to start
  without one.

## Verified live

On RTX PRO 4500 Blackwell pods (one GPU and two GPUs, 32 GB each), 2026-10-10:

- Authenticated agent control on one and two GPUs; topology chose sequential GPU 0 on one GPU
  and caption GPU 0 / trainer GPU 1 on two.
- vLLM captioning: Qwen 2.5 VL 3B and Qwen3 VL 8B served and returned structured captions
  (from Python and from Swift).
- Hub dataset in, tiny FLUX and LTX runs, checkpoints, readable loss curves, LoRAs pushed to
  private Hub repos and downloaded with matching hashes.
- VRAM released between services on one GPU; on two GPUs, vLLM and LTX resident at the same
  time on separate physical devices, and a second booking of GPU 0 refused with 409.
- All three images pulled anonymously by exact digest. Total spend: **$1.43** for pods,
  **$1.49** with network storage. All three pods are stopped (`EXITED`); the 200 GB network
  volume `nydku2wmvd` is kept and bills **$14/month**.

Receipts: `~/Projects/concept-captioner-notes/evidence/2026-10-10/` (private notes, not
published), with a SHA-256 manifest. Build and push logs are on cx53 under
`/home/hive/work/concept-captioner-pod-verify-20261010`.

## Verified offline only

- **agent 612 passed** (TensorBoard parity included: the venv has the `pod` extra);
  **scripts 242 passed**; **podctl 125 passed**. Fresh venvs per [pod/README.md](../README.md);
  ruff check and format clean on all three. These counts establish source behavior, not CUDA
  execution.
- Fake compose: health, auth, two fake GPUs, concurrent plan, TensorBoard through the proxy.
- **2026-10-11 fix round, not yet run on a pod** (every live receipt above predates it):
  - TensorBoard's browser credential is no longer the bearer: `POST /tensorboard-session`
    issues a derived, 12-hour HMAC session cookie (POD-SPEC §2.1, §2.9); proxied responses set
    no cookie. The app's TensorBoard view calls the handshake before loading the page.
  - The `/tensorboard` proxy targets the catalog's fixed port 6006; the `tensorboard` service
    no longer takes a `port` param.
  - `trainer-ltx` validates with `LtxRunConfig`; the shared rule file is `ltx_rules.py`.
  - `launch_ltx.py` downloads LTX-2 at revision `dfcc2108383fe1aaa0584bdf55d368a4bdadd90c`
    (the repo's head since 2026-08-04, so the same files the 2026-10-10 run fetched) before
    writing run files, and exits 69 on failure.
  - `Dockerfile.ltx` pins TensorBoard 2.21.0; `Dockerfile.base` runs
    `images/check_vllm_flags.py`, the automated form of the 2026-10-10 manual source probe.
    Neither image has been rebuilt with these steps.
  - `GET /runs/{id}/files` and `GET /runs/{id}/files/{path}` list and stream a run's output
    files (Range supported) for users without a Hub account; `podctl files`, `pull` and
    `tensorboard` were run end to end against a local fake agent only.

## Open

- **Caption quality.** The 3B and 8B captions failed the concept boundary in the cancelled
  five-image experiment; none is training data. The larger comparison is deferred by Hákon.
- **Caption inference while training runs.** Both services were resident at once, but the
  caption request ran after training exited.
- **Not run live:** FLUX resume, H3 trainer keys, parquet datasets, recovery after an agent
  crash, CUDA driver R570.
- **Not run live (2026-10-11 fix round):** the TensorBoard session handshake, the run-file
  endpoints and the pinned LTX download above; the images need a rebuild first.
- **No self-stop on the pod (decided 2026-10-11):** cost guards live in the app, which keeps
  the Mac awake while a pod runs and finds its pods on launch (implemented in the app; see
  [APP-STATUS](../../app/docs/APP-STATUS.md)).
