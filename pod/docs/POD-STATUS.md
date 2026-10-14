# POD-STATUS

State after the 2026-10-11 source review repairs and the Phase 2 H3 source additions. The
current published tag, `v0.3.0-20261014`, is a clean build of PR #10 at `f784947` (the model table);
the previous tag, `v0.2.3-clean-20261011`, is a clean build of `main` at
`b79086183bba40e8120f0cba1ee59173f10108a5` (review repairs, direct dataset upload and the H3
additions included) with the repository Dockerfiles and no overlay; it has had anonymous
tag-to-digest checks and a CPU smoke (2026-10-12). The owner/Claude subsequently
completed the real H3 still-image run documented in the
[walkthrough](../../docs/process/walkthrough-2026-10-11.md): 3,000 steps, 69 stills,
private LoRA publication and pod stop. This is a recorded runtime acceptance, not a new
GPU check performed during these repairs. The previous clean
tag `v0.2.2-clean-20261011` (from `2789c1d3`) stays published. The
earlier clean tag `v0.2.1-clean-20261011` (from `ce52a220`, before those repairs) stays
published. The real-pod evidence below was gathered on the overnight
`v0.2.0-overnight20261011-r2` tag (accepted source `98708207`, with two files overlaid onto older
layers), which also stays published. Actual FLUX generation and Resume passed on the r1 AI
Toolkit image; r2 AI Toolkit has a CPU witness only, and its checkpoint-snapshot path has not
run on a FLUX GPU. LTX approved-video training, Resume and matched video generation passed on
the final r2 image. Both proof pods were stopped after verification and terminated in the
owner-authorized afternoon cleanup; outputs were secured locally and on the network volume.
Historical live checks date from lab commit `e620882` (2026-10-10, last live read 21:26 UTC). The
contract is [POD-SPEC.md](POD-SPEC.md). The day-by-day record, with every timestamp, digest,
hash and billing bucket, is in
[status-history-2026-10-10.md](../../docs/process/status-history-2026-10-10.md#pod-status).

## What exists

- **Control agent** (`pod/agent`): authenticated HTTP API for GPU inventory, topology plan,
  a nine-service catalog (vLLM, both trainers, both generators, TensorBoard, dataset pull,
  LoRA push and dataset cleanup), supervisor, logs and training
  events. TensorBoard listens on loopback and is reached only through the agent's
  authenticated `/tensorboard/` proxy. vLLM and LTX preprocessing arguments are allowlisted.
- **Transfer scripts and trainer wrappers** (`pod/scripts`): Hub dataset pull or authenticated
  local dataset installation, AI Toolkit
  (FLUX/H3) and LTX launchers, LoRA push. H3 still-image training has the owner/Claude runtime acceptance above;
  clip training, external warm-start, Resume and matched generation remain unexercised live.
- **podctl** (`pod/podctl`): command-line client for the agent.
- **Images**, public on GHCR under tag `v0.3.0-20261014` (clean build from commit
  `f784947`; digests in [images/README](../images/README.md)): `concept-captioner-pod-base`,
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
  **$1.49** with network storage. All three proof pods were stopped and then removed in the user-authorized 2026-10-11
  cleanup (DELETE 204 followed by independent GET 404). The independent 200 GB network
  volume `nydku2wmvd` was preserved and bills **$14/month**.

Receipts: `~/Projects/concept-captioner-notes/evidence/2026-10-10/` (private notes, not
published), with a SHA-256 manifest. Build and push logs are on cx53 under
`/home/hive/work/concept-captioner-pod-verify-20261010`.

## Verified offline only

- **Walkthrough recipe integration, 2026-10-12:** all **315 pod-script tests** pass, with Ruff
  check/format clean. H3 checkpoint settings and explicit no-adapter guidance settings survive
  import and merge. The merged Circlestone/guidance-loss combination is rejected before model
  downloads. The exact published-source compatibility witness is linked under Open below;
  these new server guards/defaults await the separate image rebuild.

- **Review repairs, 2026-10-11:** agent **660 passed**, scripts **291 passed**, podctl
  **125 passed**; Ruff and formatting clean. Independent source review covers generation
  completion, SIGTERM custody, Resume/retention and the direct-upload integration. These are
  source/CPU checks, not evidence that the published images contain these changes.
- The app reads `comparison.json.state` and preserves partial failed files with a visible
  error. The generator catches ordinary SIGTERM, marks an existing manifest failed and
  removes its private checkpoint copy on Stop and early validation errors. A real local
  subprocess SIGTERM test exercises this; SIGKILL/container loss cannot guarantee cleanup.
- Resume validates total steps against the checkpoint itself and refuses overrides that bypass
  the saved LTX state. Dataset cleanup runs at validated training/generation start or by
  explicit catalog action. It preserves current/active/failed/unknown/shared inputs and the
  latest three resumable completed runs; checkpoints, results and caches are retained.
  Pruned Hub inputs restore from their recorded revision. LTX result generation uses its saved
  configuration/checkpoint without downloading pruned training data.
- Authenticated file upload streams to a confined stage with exact length and 2 GiB/file,
  20 GiB/dataset limits. The local pull mode installs the metadata-listed set atomically before
  training. Tests cover auth-before-body, interrupted uploads, atomic replacement, path/size
  refusals, no Hub calls and matching Swift/Python Unicode input digests. Local Resume requires
  the original input digest; edited inputs require a new run. Base-model access is unchanged.
- **agent + scripts 892 passed** in the overnight combined gate (the venv has the `pod`
  extra, including TensorBoard and datasets); **podctl 125 passed** in the preceding fix round. Fresh venvs per [pod/README.md](../README.md);
  ruff check and format clean on all three. These counts establish source behavior, not CUDA
  execution.
- Fake compose: health, auth, two fake GPUs, concurrent plan, TensorBoard through the proxy.
- **2026-10-11 hardening source checks** (actual runtime scopes are recorded below):
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
    The full runtime builds executed these steps; r2 overlays preserve those verified layers.
  - `GET /runs/{id}/files` and `GET /runs/{id}/files/{path}` list and stream a run's output
    files (Range supported) for users without a Hub account; `podctl files`, `pull` and
    `tensorboard` were run end to end against a local fake agent. The overnight real-pod
    downloads exercised the same HTTP file-list and streaming endpoints from Python and Swift.

## Overnight features: published and verified in bounded GPU checks

Native GPU/history/results checks and the final dataset-switch regressions are recorded in
[APP-STATUS](../../app/docs/APP-STATUS.md). Combined agent/scripts gate: **892 passed**, including installed optional parity
dependencies; Ruff check/format clean. These checks use fake agent/model seams, not GPUs.

- `generate-aitoolkit` and `generate-ltx` use the actual pinned trainer inference paths,
  with selected checkpoint, matched prompts/seeds/settings, incremental manifests, real-file
  validation and the existing authenticated SHA-256 downloads. FLUX.1-dev and LTX-2 are the
  implemented families. This is runnable backend code, not a substitute demonstration gallery;
  one actual FLUX image pair and one LTX video pair have been generated and retrieved.
- Native saved-run history records dataset repository and resolved commit, submitted settings,
  loss points, available checkpoints, result location, and GPU cost estimates when a rate is
  known. Repeat creates a new run pinned to a recorded revision; if none was recorded, the app
  explicitly uses the latest remote state of the saved repo. Resume preserves the saved inputs
  and settings while increasing total steps, and uses the trainer's checkpoint/state mechanism.
  LTX default minimal state preserves scheduler/RNG/step; it does not promise optimizer continuity
  without upstream full-state saving. FLUX resume requires the wrapper's default checkpoint
  layout; arbitrary custom layouts are refused instead of claiming continuation.
- Project-owned history/comparisons stay out of another project's record after a global pod
  restore. Global pending outputs still keep their storage/cost guards and cannot be downloaded
  into the wrong project. Focused native tests cover this, repeat navigation, dataset revision
  pinning, resume without repull, matched generation requests, checksum recovery and stop guards.
- App training pulls only the media listed in the pinned publication's `metadata.jsonl`.
  Approved MP4 targets and caption/response sidecars are retained; unrelated unlisted Hub files
  are excluded from the training snapshot. FLUX refuses videos. LTX derives actual 32-aligned
  width/height and full 8n+1 frame-count buckets from the approved clips before model preparation.
  Explicit custom buckets are refused if they would crop or truncate those clips. Variable-rate
  selected segments are refused at native approval and backend preflight, because the pinned
  LTX loader discards frame timestamps and reconstructs uniform timing from the average rate.
  Constant-rate selected segments retain their timing; no automatic retiming is performed.
  The native editor owns the visible fit and exact-segment export before captioning. Audio bytes remain in
  approved media; the included memory-saving preset trains visual/motion behavior and skips
  audio optimization.
- Pinned primary-source witnesses are cached under
  `/tmp/concept-captioner-overnight-upstream/manifest.json`: AI Toolkit `f7a1fb9…`, LTX-2
  `9ec55f9…`. The old public `v0.1.0-verify20261010` tags do not include these services or the
  preceding hardening round. The `v0.2.0-overnight20261011-r2` images do, and
`v0.2.2-clean-20261011` rebuilds them from `main` at `2789c1d3` without the overlay (verified
by anonymous digest pulls, the base `check_vllm_flags.py` build step, a CPU control smoke on the
published base image, and TensorBoard 2.21.0 plus the LTX-2 `9ec55f9f` pin in the LTX image).
The r2 history: runtime source
  `017d79f` was built with the repository Dockerfiles; the independently accepted CFR repair
  at `b1d0bef` and selected-checkpoint custody repair at `98708207` were overlaid by exact
  source hashes, preserving those trainer runtime layers. All three final tags passed anonymous
  pulls using fresh empty Docker client configurations; OCI revision and installed catalog,
  generator and CFR wrapper hashes were checked in each actual image. Generation privately
  captures selected checkpoint/config before either variant, so later Resume cannot replace
  the LoRA input. The manifest keeps captured settings/SHA; the private weight copy is removed
  on normal completion or handled error. The actual r2 CPU image passed an original-file
  replacement witness; this does not claim concurrent CUDA execution.
- Final base CPU smoke passed health/auth, all eight services, TensorBoard session and cookie
  scope, run configuration, file SHA and Range download, and planning on two fake GPUs.
  This is an actual image/control check, not CUDA inference.
- Actual native `ProjectPublisher` and `HubClient` published the approved synthetic nine-frame
  512×288 MP4 to private dataset `RationallyPrime/concept-captioner-video-infra-20261011`
  at commit `3dee9e096b06a2741c10269236a13f6f64be1163`. Its exact-revision download matched
  SHA-256 `497b84d0c020cc1c98fba5e158ab3c7503efdbd7f981582ee5e937941bd91e99`.
- Actual FLUX `generate-aitoolkit` returned exit 0 with one base/LoRA PNG pair: selected
  original step-two checkpoint, `NORA7 geometric figure on a plain background`, seed 42,
  256×256, four inference steps, guidance 4. Both PNGs and complete manifest were downloaded
  with matching SHA-256 through Python and actual native `GPUWorkspace.retrieveGeneration`.
  This functional proof used r1 and predates the private snapshot repair. Original selected
  weights were secured before Resume.
- Actual same-ID FLUX Resume advanced `tiny-flux-proof-20261010` from step 2 to 3 and exited 0.
  Its downloaded 21,610,744-byte checkpoint has 988 tensors and `training_info.step=3`,
  SHA-256 `d2947945f647005a6796dfa2bcd0ce4eee6a8a74b6b9ad967eb77fd0c009b437`.
  `scraped/loss` reports step 3, value 0.2554000020. The original step-two file remains secured
  locally with SHA-256 `e9b60bdce2c72e18d81ef0f691de9b119136ed9f5d31d625e12aa769f5c54dd9`.
- That pod, `c6xdg7goo1jpkm`, was stopped after outputs were secured; fresh MCP stop and two
  independent reads report `EXITED`. Its actual rate was $0.72/hour, with a conservative
  creation-to-readback projection of $0.220754 including image pull (settled billing is separate).
  The network volume remains; ephemeral container disk is discarded on stop.
- Actual LTX training on r2 processed the approved constant-rate nine-frame 512×288 target
  using the derived `512x288x9` bucket, completed two optimizer steps and exited 0 at
  05:06:36 UTC. The disabled validation template in the log is 512×512×1; it does not describe
  the training clip. `scraped/loss` reports step 2, value 0.1256999969. Downloaded step-two
  LoRA weights are 27,062,728 bytes, SHA-256
  `a8f6a66a68486dc5e63b1dad96ab7b4db9a3312b10120b2541d1996694cd73e5`; matching
  trainer-state files are available. Input SHA was measured at native publication and the
  exact Hub revision download, not directly on the pod filesystem.
- Actual same-ID LTX Resume restored scheduler/RNG at step 2, performed one optimizer
  update and exited 0 at 05:12:51 UTC. The new step-three LoRA has 2,304 tensors and
  SHA-256 `8e1e6bf0902a238c8d0cae10fd4032105f27da87003ed8f09e835bd11c92de70`;
  its matching trainer-state file is listed. Downloaded bytes match the served checksum.
  `scraped/loss` reports step 3, value 0.0322000012; the trainer reports peak GPU memory
  20.99 GB on the 32 GB GPU/62 GB host. This uses the upstream minimal state and does not
  establish full optimizer-state continuity.
- Actual public HTTPS proxy TensorBoard handshake passed on that pod: bearer-authenticated
  `POST /tensorboard-session` returned 200; its scoped cookie opened real TensorBoard HTML
  with 200. Unauthenticated TensorBoard and cookie-only `/health` requests returned 401.
  The cookie has path `/tensorboard`, Secure, HttpOnly and SameSite=Strict. Its value was
  not recorded or printed. This is a real RunPod proxy/CPU service check while GPU work was
  queued, in addition to the final-image fake-GPU control checks above.
- Actual r2 LTX `generate-ltx` exited 0 at 05:24:35 UTC with a complete base/LoRA MP4 pair.
  Both have 49 decoded frames, 512×512, 24 fps and duration 2.041667 seconds, using the same
  prompt, seed 42, four inference steps and guidance 4. The manifest captures the step-three
  checkpoint SHA above and its source settings; manifest SHA-256 is
  `ff116fc6b28594ca916792ec8421bf0d720e4eafa0f746f56df5f38440dc2861`. Both variants
  completed streamed Gemma and diffusion on the measured 32 GB GPU/62 GB host, using
  `--quantization fp8-cast --offload cpu`. Generated AAC audio is present; this does not
  establish audio fine-tuning, because this training preset skipped audio optimization.
- The actual native `PodAgentClient`/`GPUWorkspace` collector completed nine authenticated
  GETs by 05:25:08 UTC and saved the pinned step-three model, complete manifest and both
  videos with matching SHA-256. Python independently downloaded and decoded both videos.
  This is synthetic functional evidence; no user training or quality campaign was run.
- Owned LTX proof pod `5bqs5hgvb166t5` was created 04:52:22 UTC with one RTX PRO 4500,
  62 GB host RAM and r2 on the same volume. After collection it was stopped; stop and fresh
  independent GET reported `EXITED` at 05:25:55 UTC. Both overnight proof pods were read
  again as `EXITED` at 05:26:45 UTC, with the 200 GB network volume still present. The
  ephemeral container disks are discarded on stop; no pod or volume was terminated/deleted.
- Actual running rates were $0.72/hour for each new pod. Conservative creation-to-stopped-
  readback compute projections are **$0.220754 FLUX + $0.4025358 LTX = $0.6232898**, below
  the $5 compute cap; these include image pull and are not settled charges. Task-only billing
  read at 05:27 UTC for the aligned 04:00–06:00 window had no posted pod records yet. The
  volume had one posted 04:00–05:00 charge of **$0.0194444451**; the current hour is partial.
  Existing network storage continues independently at $14/month. No owned GPU work remains
  running or queued; invoice settlement is not awaited on a paid pod.
- Durable private receipts: `~/Projects/concept-captioner-notes/evidence/2026-10-11-overnight-pod/`,
  including `final-r2-images.json`, `base-r2-fake-smoke.json`, `template-r2.json`,
  `hub-receipt.json`, `ltx-pair-validation.json`, both stop receipts,
  `final-stopped-readbacks.json`, `billing-final.json`, source freezes and focused test logs.
  The public template's image-only update to the final base was independently read back;
  all other fields were preserved.

## Phase 2 H3 source (2026-10-11)

- H3 now selects pinned `minimax_h3`, BF16 model/text encoder, the frozen image-training
  adapter and the concrete AdamW quality recipe. Per-example captions carry mapped
  concepts; no global first trigger is injected. Supplied old component paths are never
  assumed installed. The canonical quality/known-asset policy has one shared native/pod JSON.
- Exact approved clips use decoded 24 fps CFR timing, 17n+5 counts (5–243), 32-aligned
  dimensions and a covering area cap. Explicit frame-count groups preserve all selected
  frames/audio and separate still buckets; the native effective config and input facts
  are saved. Metadata-only ffprobe preflight on all 18 prepared selected clips passed at
  cap 1024. No private pixels/audio were inspected or uploaded by this verification.
- The existing authenticated upload route admits only two additional fixed initializer
  slots in a distinct stage. SHA-bound, validated H3 A/B weights and canonical recipe are
  privately captured for a NEW warm-start run at 0. Imported precision/block selection
  survives; requested rank/alpha/LR/steps/batch/accumulation are actual native settings.
  Same-run Resume retains that binding, restores its own checkpoint and needs no old stage.
- The generator attaches the actual pinned trained network to the registered H3 model
  using saved effective native settings; base/LoRA arms use multiplier 0/1, identical
  prompts/seeds and no frozen assistant. PNG or 24 fps MP4 is selected per request,
  independently of training input type. Result manifests omit private initializer/native
  paths and retain complete/failed semantics and all produced output files.
- Offline checks: all **310 script tests** and **454 selected agent/catalog/API/supervisor
  tests** passed at the first complete code gate; final narrow selector/initialization
  closure is recorded separately in the private freeze receipt. The fake inference tests
  verify call/recipe/output contracts; they are not GPU generation or a fake product gallery.
- At the end of this source phase, deployment and H3 runtime checks were pending. The later
  v0.2.3 image and owner/Claude still-image run supersede that deployment/training gap.
  H3 clips, external warm-start, Resume and generation still need live acceptance. Earlier
  FLUX/LTX receipts remain evidence for their exact images.

## Open

- **Current baseline:** v0.2.3 includes the H3 initializer/recipe/clip/generator code and has
  the owner/Claude still-image training acceptance above. The new walkthrough controls
  send explicit save and guidance fields through the image’s existing `extra` contract;
  [the source witness](../../docs/process/walkthrough-gpu-source-witness-2026-10-12.json)
  executes that exact published validator/wrapper. New script defaults and extra comparison
  receipt fields are source changes awaiting Claude-owned image publication. This is offline
  compatibility evidence, not new live acceptance of those controls or pod-disk restart.
- **Caption quality.** The 3B and 8B captions failed the concept boundary in the cancelled
  five-image experiment; none is training data. The larger comparison is deferred by the owner.
- **Caption inference while training runs.** Both services were resident at once, but the
  caption request ran after training exited.
- **Not run live through this new app/pod path:** H3 clip training, external initialization,
  same-run continuation, joint audio and matched generation. H3 registration/loader/network
  keys are source-verified. Other live gaps: parquet datasets, recovery after an agent
  crash, CUDA driver R570.
- **Pinned LTX download scope:** this round reused the previously populated network-volume
  model cache, resolved through the revision-pinned wrapper. A fresh empty-cache download at
  that pin was not repeated; model loading and actual training used those cached files.
- **No self-stop on the pod (decided 2026-10-11):** cost guards live in the app, which keeps
  the Mac awake while a pod runs and finds its pods on launch (implemented in the app; see
  [APP-STATUS](../../app/docs/APP-STATUS.md)).
