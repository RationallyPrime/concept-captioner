# POD-STATUS

Current verification state as of 2026-10-10 20:00 UTC. Real agent, caption, trainer,
checkpoint/curve/Hub and GPU isolation proofs are recorded below. All three task-created
pods are independently confirmed `EXITED`; no runtime work remains queued. The public
base template is verified. Public trainer-image availability remains blocked, and the
billing reads are partial posted amounts rather than a complete final charge. Source,
fake execution, live functional execution and caption quality remain separate evidence.

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

Four independently accepted runtime changes are published:

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
- `de6f152`: TensorBoard is installed into the actual isolated LTX trainer venv after
  its final dependency sync. The build itself wrote and reread a CPU scalar, step 1/loss
  0.5, with TensorBoard 2.21.0. An independent reviewer accepted the frozen Dockerfile and
  completed build receipt; the later real GPU run also produced readable curve events.

## Images and fake compose

All three CUDA images built and pushed on cx53. Base and ai-toolkit carry accepted source
`92136b1`; repaired LTX carries `de6f152`. Registry references share the tag
`v0.1.0-verify20261010`:

| image | final registry digest | bytes | publication |
| --- | --- | --- | --- |
| `ghcr.io/rationallyprime/concept-captioner-pod-base` | `sha256:e49e9d2de028ed8185d037b9dcf86ff8652a37923de660b26eb16c51d92c387a` | 10,290,568,891 | public; actual anonymous Docker pull succeeded with an empty isolated config |
| `ghcr.io/rationallyprime/concept-captioner-pod-aitoolkit` | `sha256:6fcdd6259987203bed61913dd8585eae60a18dc28b184e2545b202fe9c4baf7b` | 14,147,141,514 | pushed, private; latest actual anonymous Docker pull rejected as unauthorized |
| `ghcr.io/rationallyprime/concept-captioner-pod-ltx` | `sha256:1d346fa7b00de3e95168929d838e39d52206af057e8fc35b5cf1aff35794f6ea` | 13,896,513,451 | pushed, private; latest actual anonymous Docker pull rejected as unauthorized |

The initial live ai-toolkit proofs below used accepted source `c325cb4` under the same tag,
with supported vLLM arguments. Their ai-toolkit digest was
`sha256:56330d8c426efd6a1c8c939c8a0d0cbf6032e956edaf1d61716885f242d0a32d`.
The tag was then rebuilt to the final digests above. Initial LTX used the pre-repair
`92136b1` image. Its successful checkpoint proof exposed a missing TensorBoard dependency.
The independently accepted Dockerfile repair, source
`de6f152`, built and pushed the same LTX tag at new digest
`sha256:1d346fa7b00de3e95168929d838e39d52206af057e8fc35b5cf1aff35794f6ea`; this is the
current LTX image. Build CPU SummaryWriter/EventAccumulator verified step 1/loss 0.5 in the
actual LTX venv, TensorBoard 2.21.0. The preceding LTX digest was `sha256:61f90e3d40dec8cb3d2886ecad5787656276672a7bb1d4729e28353f17044945`.

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
anonymous Docker pull verified it, including a fresh anonymous pull after stage 5. The Mac
was subsequently unlocked and the native app launched successfully, then computer-use
transport failed with `Sky Computer Use native pipe closed before response`. Fresh bindings
and resets did not recover it. This is the current browser blocker; trainer visibility
still requires the authorized settings change, with settings at
`https://github.com/users/RationallyPrime/packages/container/concept-captioner-pod-aitoolkit/settings`
and the corresponding `concept-captioner-pod-ltx/settings` path.

## Live resources and cost state

Task-created durable volume `nydku2wmvd` is 200 GB Standard in EU-RO-1, freshly read back.
Its published rate is $0.07/GB/month ($14/month), including after compute stops. Checkpoints
and datasets remain on that volume; no volume or output has been terminated/deleted.

| pod | hardware actually observed | compute rate | state at this update |
| --- | --- | --- | --- |
| `iqs4zrmjf097hf` | 1 × RTX PRO 4500 Blackwell; 32,623 MiB VRAM, 62 GB RAM, 12 vCPU, CUDA 13.2 | $0.72/hour | `EXITED`; final independent read 19:58:55Z |
| `q833ws7hsuyrqn` | 2 × RTX PRO 4500 Blackwell; distinct GPU UUIDs, 32,623 MiB each, 125 GB RAM, 56 vCPU, CUDA 13.2 | $1.44/hour | native stop 19:58:06Z, fresh native `EXITED` 19:58:07Z, independent read 19:58:55Z |
| `ey4f2374hd3y62` | A100 PCIe 80 GB; 117 GB RAM, 31 vCPU, CA-MTL-3, CUDA 13.2 | $1.79/hour | cancelled experiment; stopped/read back `EXITED` 19:28:52Z, independently rechecked 19:58:55Z |

The two training pods each had 50 GB container disk; the cancelled A100 had 100 GB.
Container disk is ephemeral and is lost on stop/restart. Its published rate applies while
the pod is running, $0.10/GB/month; no stopped-container-disk retention or continuing charge
is claimed. The network volume is independent and is the continuing task storage charge.
The one-GPU pod was created 18:30:26Z, initial container boot 18:37:21Z, first proxy health
18:39:08Z. The preceding 64 GB reserved-RAM request failed capacity and created no pod.
The two-GPU pod was created 18:34:47Z and stopped after its useful proof at approximately
18:40:51Z. The one-GPU pod was stopped and read back `EXITED` at 19:06:34Z, then updated to
the pre-repair LTX image and restarted for the initial trainer proof; agent boot logged
19:11:54Z. It stopped again at 19:24:57Z after outputs were secured. A subsequent start with
the repaired image was refused by its original host's GPU capacity, so the existing pair
resumed at 19:33:30Z for the remaining useful work. No extra replacement pod was created.

At 20:00:31Z exact-resource billing reads for the aligned 17:00–21:00 window returned:

| resource | records returned | posted USD |
| --- | --- | --- |
| one-GPU pod `iqs4zrmjf097hf` | 18:00 and 19:00 buckets | 0.3690129272872582 |
| two-GPU pod `q833ws7hsuyrqn` | 18:00 bucket only | 0.14567590539809316 |
| cancelled A100 `ey4f2374hd3y62` | none yet | no posted amount; not a free-compute claim |
| network volume `nydku2wmvd` | 18:00 and 19:00 buckets | 0.03888889029622078 |

The currently posted task subtotal is **$0.5535777229815722**. It is incomplete: the pair's
19:00 restart period and the cancelled A100 have not appeared in these reads. Rates and
elapsed-time projections are separate from billing records. Rate fields on an `EXITED` pod
do not establish active compute billing. No pre-existing account resource was changed.

## Verified on a real pod

The seven demonstrations were executed in the brief's order. The base template was created
early as preparation and reread after trainer and device proofs for stage 6. Stage 1 built
and pushed all images and passed fake compose; stages 2–3 exercised authenticated real
agents and vision captioning; stage 4 produced both trainers' checkpoints, curves and Hub
roundtrips; stage 5 demonstrated sequential release and simultaneous isolated GPU
residency; stage 6 verified the public base template/image/token requirement; stage 7 is
this evidence and cost report. Trainer images remain private, and simultaneous caption
computation during training was not established by the delayed native request.

## Agent, topology and VRAM proof

Both live agents passed authenticated health, inventory, plan, service status, logs and
TensorBoard start/stop. One GPU selected sequential GPU0. Two GPUs selected caption GPU0 /
trainer GPU1. Real TensorBoard 2.21 binds `127.0.0.1:6006` under `/tensorboard`; its agent
proxy answered 200 and issued an HttpOnly/Secure/SameSite=strict cookie scoped to that
subtree. Cookie-only health answered 401. Both children stopped with `group_alive=false`.

Single-GPU normal lifecycle releases were measured: vLLM stopped to 2 MiB idle before
FLUX; FLUX exit returned to 2 MiB before the next vLLM; the second vLLM stop also returned
2 MiB before pod stop.

On the pair, Qwen3-VL-8B ran on GPU0 (service PID 1035, logged EngineCore PID 1401) while
LTX resumed on GPU1 (PID 1821) from step 2 to step 22. The bounded 20-step functional
extension ran 19:50:39.455908Z–19:53:59.942041Z and saved checkpoints at 5, 10, 15, 20 and
22. Thirty-seven runtime samples recorded both distinct physical GPU UUIDs, vLLM at
25,232 MiB on GPU0 and LTX up to 22,542 MiB observed on GPU1. After trainer exit GPU1
dropped to 2 MiB while GPU0 remained at 25,232 MiB. Source fixes each child's
`CUDA_VISIBLE_DEVICES`; supervisor `in_use_by` is bookkeeping, while these independent
physical memory changes substantiate device isolation.

At 19:50:39.983776Z a different service, `trainer-aitoolkit`, requested GPU0 and received
actual API 409 `gpu_busy`, identifying vLLM's reservation. No second trainer spawned.
The native synthetic caption returned HTTP 200 and parsed structured output, but its actual
request began 19:54:34.348241Z and ended 19:55:47.535800Z, entirely after trainer exit.
This proves simultaneous service allocation/residency and isolation, with no claim of
simultaneous caption computation. No additional training run was added to manufacture an
overlap. Manual API-server crash/subreaper recovery remains unverified.

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

The user cancelled the five-image caption/comparative-training experiment at 19:28 UTC
because the dataset is too small to support the intended scientific comparison. Prepared
notes and rejected outputs are retained as cancelled work, not training evidence. The
briefly allocated A100 pod `ey4f2374hd3y62` was stopped and freshly read back `EXITED` at
19:28:52Z; its pending local server-start wait was cancelled (exit 130), and no 32B caption
batch executed. Creation-to-stop elapsed 117.223 seconds at $1.79/hour, a rate projection of
$0.0582859 compute; exact billing still has no finalized record. Its 100 GB scratch container
disk had no network/persistent mount and was lost on stop. The stopped pod configuration
is retained; the pod was not terminated/deleted.
The broader experiment is deferred until this evening with a rational dataset and statistical
design. No further experiment resource or caption work is queued now.

## Dataset, FLUX checkpoints and curves

Private functional dataset `RationallyPrime/concept-captioner-pod-proof-20261010`, commit
`4b3ce9f99229dd2c8fea58c5f8045633d59ea94a`, has four synthetic shape images with only
NORA7/IVAN9 fixtures. It is separate from native Swift smoke and the five-photo concept
experiment. Local Job validation passed; real agent pull fetched 4 images / 4 captions and
`concept-captioner/job.yaml` into `/workspace/datasets/tiny-proof`.

Run `tiny-flux-proof-20261010` used gated `black-forest-labs/FLUX.1-dev` successfully,
two steps, rank 2, resolution 256, batch 1, RunConfig sampling seed 42, lr 0.0001, sampling off.
Training RNG was not explicitly set: pinned ai-toolkit reads `extra.training_seed`; the
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

The authenticated TensorBoard scalar-history API returned HTTP 200 and all three points.
Actual native Swift `PodAgentClient` reads of plan, services, logs and latest events also
returned HTTP 200; native `TrainingPoint` decoded step 2/loss 0.05031000077724457.

## LTX checkpoints and the curve repair

Run `tiny-ltx-proof-20261010` started 19:15:13.99Z on GPU0, pre-repair `92136b1` LTX image. It uses the same
four synthetic images, supported Hub source `Lightricks/LTX-2`, two steps, resolution 256,
rank 2, batch 1, lr 0.0001, RunConfig seed 42, save every step and sampling off. The wrapper
writes this seed to both root `seed` and `validation.seed`; pinned upstream `trainer.py:156`
calls `set_seed(cfg.seed)` and its `config.py:802` declares the root reproducibility seed. The wrapper downloaded
22 selected checkpoint, mirrored Gemma and tokenizer files in 76 seconds into the fixed
workspace model directory, then preprocessed all four images. No manual model
path/download/SSH was required. The trainer exited 0 at 19:23:18Z, saved step-1/step-2 LoRA
weights plus training states, and reported peak GPU memory 21.29 GB; post-exit memory was
2 MiB. The log parser saw step-2 loss 0.0826/lr 0.00001, but the LTX venv lacked
TensorBoard and wrote no curve file. This actual dependency failure drove the accepted image
repair above; an import in the agent venv cannot satisfy the isolated trainer interpreter.

The agent uploaded both checkpoints and run/config/model card to private
`RationallyPrime/concept-captioner-tiny-ltx-proof-20261010`, commit
`2c39837124df95f7b56fe3b7b78831c14b122295`. Downloaded safetensors are 27,062,728 bytes each,
2,304 tensors with rank-2 shapes. Step-1 SHA256
`caa0e2810ece786380cb0b64f33ad430e5e4e906454182e094d0a3ab75fe229d`; step-2
`70d1d4e86d5b3d9859fdfae1e3096c1b3e425bd7f739f439e294e1f47257f1ce`. The one-GPU pod
was stopped after securing outputs. Its next start was refused: "There are not enough free
GPUs on the host machine to start this pod." It remains EXITED.

The existing pair resumed at 19:33:30Z, pulled the repaired image by immutable digest and
started run `tiny-ltx-default-proof-20261010` at 19:36:54.694383Z on GPU1: two steps, 512px,
rank 16/alpha 16, batch 1, root seed 42, same low-memory recipe. It exited 0 at
19:45:17.223928Z, saved both checkpoints and wrote one TensorBoard event file. The agent
read step 2/loss 0.04809999838471413 and lr 0.000009999999747378752. The authenticated
TensorBoard scalar-history API returned HTTP 200 with the final loss point; the actual
native Swift `PodAgentClient.latest` also returned HTTP 200 and decoded the same
`TrainingPoint`. This establishes the measured native-default functional recipe on one
32 GB device, with this host's 125 GB RAM. No scientific quality claim follows.

The exact successful low-memory override is:

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

The wrapper already sets bf16 and gradient checkpointing. The later ordinary resume from
step 2 to step 22 skipped preprocessing and supplied the stage-5 physical GPU1 observation
of 22,542 MiB. The upstream peak statistic on the pair is not used as an attributed GPU1
peak: it reported 0.00 GB in the first run and 24.64 GB during resume, while physical GPU0
already held vLLM. Its device attribution is unverified. The independent physical sample
is an observation, not a captured training peak.

The successful 256px/rank2 run used a 62 GB RAM host; the 512px/rank16 run used 125 GB RAM.
No required host-RAM minimum was established, and no minimum-RAM reservation was needed
on either successful creation. The larger host observation is not a requirement claim.

The agent uploaded both 512px/rank16 checkpoints and run/config/model card to private
`RationallyPrime/concept-captioner-tiny-ltx-default-proof-20261010`, commit
`bd22a74931355941824632455d094a0f29f38315`. Both were downloaded from that immutable commit:
214,240,000 bytes each, 2,304 tensors, rank-16 shapes `[16,4096]` / `[4096,16]`. Step-1 SHA256
`252b59eeb9f0adef28b2fe774838f6c2f8a022f340f0cdd61de66afe2c32ae6a`; step-2
`0c0e949266054c3d9f87d0083cc6fa420954e6aa473b03a5b4d33ff1ce73226e`. The original two-step
config/log/curve receipts and Hub commit were secured before the bounded isolation resume;
later checkpoints and training state remain on the durable network volume.

## Stage 6: public RunPod template

Template `87fxs5v8fn`, **Concept Captioner — authenticated vLLM agent**, was created at
approximately 19:17 UTC as preparation. Its final read-back at 19:58:55Z followed the trainer
and topology demonstrations and confirmed public visibility. It points to the final public
base tag, has no registry credential,
HTTP ports 8800/8000, 50 GB disk, persistent `/workspace` 200 GB, CUDA 13.0/13.1/13.2,
and no SSH/Jupyter. The API drops empty env values: `PODAGENT_TOKEN` is deliberately absent.
The launcher must generate a unique 16+ character token per pod and supply it; the agent
exits without one. vLLM uses the same token by default. HF token is supplied by the user when
needed. The template itself does not include an account token or a paid GPU allocation.
The final base image was freshly pulled anonymously after stage 5. A CPU launch of that
actual image without a token exited 2 with the explicit refusal to start; it did not expose
an unauthenticated agent. These final image/auth checks created no additional paid pod.

## Remaining verification boundaries

The initial handoff listed implementation details beyond the spec. Auth/body limits, stop
timeout, TensorBoard routing, LTX Hub preparation, actual trainer mappings/entrypoints,
compose ports and REST v2 lifecycle/storage semantics are now aligned in the spec. These
remaining boundaries are retained so live verification does not erase untested behavior:

- Transfer source additionally supports `metadata.csv`, repo sidecars and unlisted images,
  split-specific metadata, `<caption-column>_response` records, a resolved pinned revision and
  richer manifest fields. `--require-captions` swaps the dataset before returning 1. Push also
  includes nested `*/samples/*`, excludes preprocessed/dot directories and records `push.json`.
- LTX ordinary resume and both trainers' native/scraped curves and TensorBoard locations
  were observed. FLUX resume and H3 config/quantization keys remain unverified on live
  hardware. Empty-caption sampling disables validation. The repaired LTX image supplies
  TensorBoard to the trainer venv; the initial missing-dependency result is historical.
- vLLM parameter bounds and defaults in source, including the current v0.31 flag allowlist,
  remain authoritative; the spec sample does not enumerate every rejected override.

## Evidence and remaining terminal work

Local receipts live under `/tmp/concept-captioner-pod-proof-20261010` (private directory).
Sanitized agent receipts, prepared-request witness, runtime flag probe and downloaded
FLUX/LTX Hub receipts are retained there. Build/push logs and isolated Docker configs are on
cx53 under `/home/hive/work/concept-captioner-pod-verify-20261010`; credentials are never
part of this document. The notes experiment retains the rejected caption drafts.

Principal local receipts:

- `final-stopped-template-receipt.json`: independent final three-pod EXITED states, final
  template read-back and storage scope; `final-task-billing-receipt.json`: exact resource
  billing records, partial subtotal and separately labeled A100 elapsed-rate projection.
- `flux-hub-receipt.json`, `ltx-hub-receipt.json`, `ltx-default-hub-receipt.json`: downloaded
  checkpoint lengths, hashes and tensor headers; the adjacent directories contain weights.
- `flux-tensorboard-curve.json`, `ltx-default-tensorboard-curve.json`, and
  `ltx-default-stage4-{log,service,events}.json`: successful authenticated curve/run evidence.
- `topology-runtime-samples.json` and `gpu-busy-api-proof.json`: physical two-GPU observations
  and actual different-service reservation rejection.
- `ltx-tensorboard-review-build.log`, `vllm-removed-flags-source-probe.json` and
  `package-base-public.jpg`: causal repair/build, installed-wheel and public-package proof.

Native receipts are separately at `/tmp/concept-captioner-swift-agent-flux-read.json`,
`/tmp/concept-captioner-swift-agent-ltx-read.json`,
`/tmp/concept-captioner-swift-qwen8-concurrent.json` (explicitly after trainer exit), and
`/tmp/concept-captioner-swift-native-stop.json`. The final native stop proved actual app
`RunPodProvider` status/stop/status, all HTTP 200, before independent MCP verification.

The remaining distribution blocker is trainer public visibility and successful anonymous
pulls. The current GUI transport failure prevents the already-authorized settings changes.
Final settled task-only cost is delayed in billing; partial posted amounts are preserved
without treating missing records as zero spend. No paid pod remains active or useful runtime
work queued. Real parquet transfer, FLUX resume and manual crash recovery remain unproven
historical checks. The five-image experiment is cancelled/deferred by the user; no rejected
caption batch was promoted into training data. All tiny trainer runs are functional proof
only and supply no scientific caption-quality comparison.
