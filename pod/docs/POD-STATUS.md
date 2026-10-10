# POD-STATUS

Current verification state as of 2026-10-10 19:18 UTC. Source, fake execution, live functional
execution and caption quality are separate evidence below. The requested seven live
checks are in progress; this file does not claim the complete pod handoff yet.

## Implementation and local verification

The agent, GPU inventory, topology plan, fixed service catalog, supervisor, event reader,
transfer scripts, both trainer wrappers, podctl and all four Dockerfiles are implemented.
The source contract is `POD-SPEC.md`; running code determines actual behavior. The first
handoff had only fake/mock verification. That historical limitation was superseded by the
builds and live receipts recorded here.

| tree | latest local result | scope |
| --- | --- | --- |
| agent | 570 passed, 1 skipped | catalog/API, actual fake subprocess lifecycle, GPU fixtures, topology, auth, TensorBoard proxy and event reader; skipped optional TensorBoard parity in the development venv |
| scripts | 240 passed | wrapper validation/config/preprocess, mocked trainer launches and Hub transfer; isolated `python -I` entrypoints |
| podctl | 113 passed | CLI/client, gateway classification, logs/wait semantics |

Ruff and formatting passed for all three trees. The inherited Starlette/httpx warning does
not change these results. Commands use each package's existing development venv; scripts
run with `../agent/.venv/bin/python -m pytest tests -q`. These local counts establish source
behavior, not CUDA execution.

Three independently accepted changes are published:

- `52bedeea032aaa08a7923249bc06c127795f00d2`: existing vLLM allowlist verified; one stdlib
  LTX preprocess validator at API and isolated script boundaries; invalid flags are rejected
  before run preparation, writes or subprocesses. Cloudflare proxy 520–526 without an agent
  envelope is unreachable (podctl exit 3). Parent independently ran 15 API preprocess,
  33 wrapper preprocess and 21 proxy checks.
- `c325cb411331062e1de80b2b0271f16c2c188dbb`: TensorBoard binds loopback and uses the
  authenticated agent `/tensorboard/` proxy. Bearer first navigation supplies a scoped
  HttpOnly cookie, Secure on real pods; cookie authentication cannot reach control routes.
  Credentials are not forwarded upstream and port 6006 is internal. LTX resolves the
  supported Hub source into controlled workspace paths automatically. Parent independently
  ran 6 TensorBoard API and 10 Hub/download wrapper checks.
- `92136b16e2b280a638908b3293be730f8f303bb9`: actual vLLM 0.31.0+cu129 rejected obsolete
  `--disable-log-requests`. An exhaustive installed-wheel source probe of 2,771 Python files,
  with the current `enable_log_requests` as positive control, also found no hyphen/underscore
  forms of `--swap-space`, `--max-seq-len-to-capture` or `--disable-mm-preprocessor-cache`.
  The four flags now return API 422 before process, logs or GPU booking. Parent independently
  checked 8 focused cases including all four pre-spawn API rejections. The unsuccessful
  CPU-only CLI help probe is not used as the absence witness.

## Images and fake compose

All three CUDA images built and pushed on cx53 from accepted source `92136b1`, with that
OCI revision label. Registry references share the tag `v0.1.0-verify20261010`:

| image | final registry digest | bytes | publication |
| --- | --- | --- | --- |
| `ghcr.io/rationallyprime/concept-captioner-pod-base` | `sha256:e49e9d2de028ed8185d037b9dcf86ff8652a37923de660b26eb16c51d92c387a` | 10,290,568,891 | public; actual anonymous Docker pull succeeded with an empty isolated config |
| `ghcr.io/rationallyprime/concept-captioner-pod-aitoolkit` | `sha256:6fcdd6259987203bed61913dd8585eae60a18dc28b184e2545b202fe9c4baf7b` | 14,147,141,514 | pushed, currently private; visibility/anonymous pull pending |
| `ghcr.io/rationallyprime/concept-captioner-pod-ltx` | `sha256:61f90e3d40dec8cb3d2886ecad5787656276672a7bb1d4729e28353f17044945` | 13,874,943,964 | pushed, currently private; visibility/anonymous pull pending |

The initial live ai-toolkit proofs below used accepted source `c325cb4` under the same tag,
with supported vLLM arguments. Their ai-toolkit digest was
`sha256:56330d8c426efd6a1c8c939c8a0d0cbf6032e956edaf1d61716885f242d0a32d`.
The tag was then rebuilt to the final digests above. Current LTX uses the final image.

Build import checks passed: base CPython 3.12.14, vLLM 0.31.0+cu129, torch 2.13.0+cu129,
FlashInfer 0.7.0.post1 cache; ai-toolkit torch 2.13.0+cu130, flash-attn 2.8.3, natten 0.21.7,
torchcodec 0.15.0+cu130, diffusers 0.39.0.dev0 and transformers 5.5.3; LTX trainer/core 1.4.2,
torch 2.13.0+cu132 and natten 0.21.7+torch2130cu132. The final ai-toolkit installed setuptools
84.0.0 after upstream dependency resolution; the real entrypoint and tiny training succeeded.
Driver observations are on CUDA 13.2 hosts. R570 compatibility has not been live tested.

The fake image built and compose answered health 200 / unauthenticated health 401, two
fake GPUs, concurrent plan caption GPU0/trainer GPU1, authenticated TensorBoard 200 with
scoped cookie, and service stop. cx53 host port 8000 was already occupied, so this isolated
proof mapped localhost 38800/38000. Compose exposes only 8800/8000; TensorBoard stays
loopback through `/tensorboard/`. Fake execution proves control integration, not GPU memory.

The signed-in Chrome settings change made the base package public; REST read-back and
anonymous Docker pull verified it. The next browser attempt found the Mac locked. Trainer
visibility remains a concrete external blocker, with settings at
`https://github.com/users/RationallyPrime/packages/container/concept-captioner-pod-aitoolkit/settings`
and the corresponding `concept-captioner-pod-ltx/settings` path.

## Live resources and cost state

Task-created durable volume `nydku2wmvd` is 200 GB Standard in EU-RO-1, freshly read back.
Its published rate is $0.07/GB/month ($14/month), including after compute stops. Checkpoints
and datasets remain on that volume; no volume or output has been terminated/deleted.

| pod | hardware actually observed | compute rate | state at this update |
| --- | --- | --- | --- |
| `iqs4zrmjf097hf` | 1 × RTX PRO 4500 Blackwell; 32,623 MiB VRAM, 62 GB RAM, 12 vCPU, CUDA 13.2 | $0.72/hour | running useful LTX model preprocessing/training work |
| `q833ws7hsuyrqn` | 2 × RTX PRO 4500 Blackwell; distinct GPU UUIDs, 32,623 MiB each, 125 GB RAM, 56 vCPU, CUDA 13.2 | $1.44/hour | stopped; fresh `EXITED` read-back after first bounded two-GPU API proof |

Each has 50 GB container disk, published active-disk rate $0.10/GB/month ($5/month).
The one-GPU pod was created 18:30:26Z, initial container boot 18:37:21Z, first proxy health
18:39:08Z. The preceding 64 GB reserved-RAM request failed capacity and created no pod.
The two-GPU pod was created 18:34:47Z and stopped after its useful proof at approximately
18:40:51Z. The one-GPU pod was stopped and read back `EXITED` at 19:06:34Z, then updated to
the final LTX image and restarted for this queued trainer proof; agent boot logged 19:11:54Z.

At 19:16 UTC the billing API returned no finalized pod billing records for either exact pod
in the 17:00–20:00 aligned window. This is reporting delay, not a claim of free compute.
The exact volume already has one recorded 18:00–19:00 charge of $0.01944444514811039.
Final settled compute totals and final stopped receipts remain pending. Rate fields on an
`EXITED` pod are not evidence that its GPU is still billing.

## Agent, topology and VRAM proof

Both live agents passed authenticated health, inventory, plan, service status, logs and
TensorBoard start/stop. One GPU selected sequential GPU0. Two GPUs selected caption GPU0 /
trainer GPU1. Real TensorBoard 2.21 binds `127.0.0.1:6006` under `/tensorboard`; its agent
proxy answered 200 and issued an HttpOnly/Secure/SameSite=strict cookie scoped to that
subtree. Cookie-only health answered 401. Both children stopped with `group_alive=false`.

Single-GPU normal lifecycle releases were measured: vLLM stopped to 2 MiB idle before
FLUX; FLUX exit returned to 2 MiB before the next vLLM; the second vLLM stop also returned
2 MiB before pod stop. Actual concurrent vLLM/trainer device isolation on the two-GPU pod
is still pending. The manual API-server crash/subreaper recovery check is also pending.

## Captioning: functional proof and rejected quality outputs

Qwen/Qwen2.5-VL-3B-Instruct served through the authenticated vLLM proxy. Python wrote all
five public DreamBooth bear_plushie photo sidecars in 82.79 seconds. The native Swift client
separately returned HTTP 200 and parsed a structured synthetic image caption. Working
settings: context 16,384, max sequences 2, GPU memory fraction 0.7, eager execution and
batched tokens 4,096. Observed active VRAM was 21,888 MiB. The earlier 8,192-token context
failed because the complete bundled prompt needed 9,452 input tokens.

Qwen/Qwen3-VL-8B-Instruct, revision `0c351dd01ed87e9c1b53cbc748cba10e6187ff3b`, then
served on the same 32 GB GPU: context 16,384, max sequences 2, memory fraction 0.85, eager
and batched tokens 4,096. Actual loaded model memory was 16.69 GiB; observed GPU memory
26,520–26,524 MiB. Five drafts took 26.28 seconds; a same-model critic took 38.92 seconds
(4 written, 1 rejected); one bounded focused-policy retry wrote five in 21.10 seconds.

The 3B drafts and all three 8B batches fail the requested concept boundary or visible pose/accessory evidence;
none is accepted as comparative training data. Exact outputs and Job variants were retained
in the separate notes experiment. The actual focused HTTP request witness records 22,161
text characters, `ACTIVE JOB CONFIGURATION`, the full held-trait/no-transcription rules,
focused overrides and one image. The instructions were present; no missing-Job source
defect was found. HTTP success and caption quality are separate outcomes.

A bounded stronger-model pass is queued after both tiny trainer proofs: official BF16
Qwen/Qwen3-VL-32B-Instruct revision `0cfaf48183f594c314753d30a4c4974bc75f3ccb`, 66,714,912,872
weight bytes, on an available suitable 80 GB GPU. The official FP8 variant is 35,516,966,184
bytes and cannot fit the current single 32 GB GPU. No stronger-model pod has been created.

## Dataset, FLUX checkpoints and curves

Private functional dataset `RationallyPrime/concept-captioner-pod-proof-20261010`, commit
`4b3ce9f99229dd2c8fea58c5f8045633d59ea94a`, has four synthetic shape images with only
NORA7/IVAN9 fixtures. It is separate from native Swift smoke and the five-photo concept
experiment. Local Job validation passed; real agent pull fetched 4 images / 4 captions and
`concept-captioner/job.yaml` into `/workspace/datasets/tiny-proof`.

Run `tiny-flux-proof-20261010` used gated `black-forest-labs/FLUX.1-dev` successfully,
two steps, rank 2, resolution 256, batch 1, RunConfig sampling seed 42, lr 0.0001, sampling off.
Training RNG was not explicitly set: pinned ai-toolkit reads `extra.train.training_seed`; the
paired experiment sets that field separately. The ordinary
wrapper config quantizes, uses adamw8bit, bf16 and gradient checkpointing; no extra override
was required. It exited 0 at 18:53:51Z and saved step-1/final safetensors plus optimizer state.
Agent events read two TensorBoard files and three loss/lr points: last step 2, loss
0.0503100008, lr 0.0001. Sampled active VRAM was 16,988 MiB; post-exit usage was 2 MiB.
This does not establish 512px/rank16 capacity or a measured training peak.

Agent `push-lora` uploaded both checkpoints, run/config and generated model card to private
`RationallyPrime/concept-captioner-tiny-flux-proof-20261010`, commit
`0f50ab0e343fd9aced140990778c19250393d802`. Both files were downloaded from that commit and
independently accepted by the parent: 21,610,744 bytes each, 988 tensors, valid rank-2
safetensors headers. SHA256 final:
`e9b60bdce2c72e18d81ef0f691de9b119136ed9f5d31d625e12aa769f5c54dd9`;
step 1: `867ef5a8bf24de84499f7ead0eac5026e0ac6faf8c2925b3716d547047b80614`.

## LTX live proof in progress

Run `tiny-ltx-proof-20261010` started 19:15:13.99Z on GPU0, final LTX image. It uses the same
four synthetic images, supported Hub source `Lightricks/LTX-2`, two steps, resolution 256,
rank 2, batch 1, lr 0.0001, RunConfig seed 42, save every step and sampling off. The wrapper
writes this seed to both root `seed` and `validation.seed`; pinned upstream `trainer.py:156`
calls `set_seed(cfg.seed)` and its `config.py:802` declares the root reproducibility seed. The wrapper downloaded
22 selected checkpoint, mirrored Gemma and tokenizer files in 76 seconds into the fixed
workspace model directory, then loaded four captions for preprocessing. No manual model
path/download/SSH was required. Checkpoint, curves and Hub push are not yet established.

The actual queued source-verified low-memory override is:

```json
{
  "optimization": {"optimizer_type": "adamw8bit"},
  "acceleration": {
    "quantization": "int8-quanto",
    "load_text_encoder_in_8bit": true,
    "offload_optimizer_during_validation": true
  },
  "preprocess": {
    "args": ["--load-text-encoder-in-8bit", "--vae-tiling", "--skip-audio"]
  }
}
```

The wrapper already sets bf16 and gradient checkpointing. Upstream source recommends this
memory-saving recipe for 32 GB; live success and memory measurements are still pending.
The intended private output repo is `RationallyPrime/concept-captioner-tiny-ltx-proof-20261010`.

## Stage 6 preparation: public RunPod template

Template `87fxs5v8fn`, **Concept Captioner — authenticated vLLM agent**, was created at
approximately 19:17 UTC and freshly read back public. This is preparation; stage 6 acceptance
remains pending until the preceding trainer and topology demonstrations pass. It points to the final public base tag, has no registry credential,
HTTP ports 8800/8000, 50 GB disk, persistent `/workspace` 200 GB, CUDA 13.0/13.1/13.2,
and no SSH/Jupyter. The API drops empty env values: `PODAGENT_TOKEN` is deliberately absent.
The launcher must generate a unique 16+ character token per pod and supply it; the agent
exits without one. vLLM uses the same token by default. HF token is supplied by the user when
needed. The template itself does not include an account token or a paid GPU allocation.

## Unresolved source/spec notes

The initial handoff listed implementation details beyond the spec. Auth/body limits, stop
timeout, TensorBoard routing, LTX Hub preparation and compose ports are now reflected in the
spec. The remaining notes are retained here so live verification does not erase findings:

- The LTX mapping in spec §4.3 still names `model.model_source`; the wrapper and current
  upstream use `model.model_path`, root `seed`, explicit encoder paths and image bucket
  dimensions. The quoted mapping needs alignment after the live result.
- Spec §1 still shows legacy CLI pod-creation flags and a terminate-after cost guard; actual
  native creation uses REST v2 `image`, `gpu.minCudaVersion`, network mount and ports. Driver
  selection and explicit stop authority in this run are recorded above.
- Transfer source additionally supports `metadata.csv`, repo sidecars and unlisted images,
  split-specific metadata, `<caption-column>_response` records, a resolved pinned revision and
  richer manifest fields. `--require-captions` swaps the dataset before returning 1. Push also
  includes nested `*/samples/*`, excludes preprocessed/dot directories and records `push.json`.
- Wrapper resume behavior, H3 config/quantization keys and native TensorBoard locations have
  not all been live verified. FLUX native and scraped curves are established; LTX remains in
  progress. Empty-caption sampling disables validation; logging is optional when the trainer
  environment lacks TensorBoard.
- vLLM parameter bounds and defaults in source, including the current v0.31 flag allowlist,
  remain authoritative; the spec sample does not enumerate every rejected override.

## Evidence and remaining terminal work

Local receipts live under `/tmp/concept-captioner-pod-proof-20261010` (private directory).
Sanitized agent receipts, prepared-request witness, runtime flag probe and downloaded
FLUX/Hub receipt are retained there. Build/push logs and isolated Docker configs are on
cx53 under `/home/hive/work/concept-captioner-pod-verify-20261010`; credentials are never
part of this document. The notes experiment retains the rejected caption drafts.

Remaining requested checks: LTX tiny checkpoints/curves/Hub roundtrip; two-GPU concurrent
workload isolation; trainer public visibility and anonymous pulls; final settled task-only
costs and stopped read-backs; stage 6 final template/image/auth verification after stages 4–5.
Real parquet transfer, resume and manual crash recovery remain
unproven optional historical checks; they are not substituted for the concrete seven proofs.
The separate 512px/rank16 paired experiment is pending accepted boundary captions and both
stream acceptances. No rejected caption batch has been promoted into training data.
