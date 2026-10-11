# POD-STATUS

State of the pod side at lab commit `e620882` (2026-10-10, last live read 21:26 UTC). The
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

- **agent 570 passed, 1 skipped** (optional TensorBoard parity); **scripts 240 passed**;
  **podctl 113 passed**. Ruff check and format clean on all three.
- Fake compose: health, auth, two fake GPUs, concurrent plan, TensorBoard through the proxy.

## Open

- **Caption quality.** The 3B and 8B captions failed the concept boundary in the cancelled
  five-image experiment; none is training data. The larger comparison is deferred by Hákon.
- **Caption inference while training runs.** Both services were resident at once, but the
  caption request ran after training exited.
- **Not run live:** FLUX resume, H3 trainer keys, parquet datasets, recovery after an agent
  crash, CUDA driver R570.
- **Run-result retrieval without a Hub account (decided 2026-10-11, being implemented):**
  authenticated agent endpoints to list and download a run's output files.
- **No self-stop on the pod (decided 2026-10-11):** cost guards live in the app, which keeps
  the Mac awake while a pod runs and finds its pods on launch.
