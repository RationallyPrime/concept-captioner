# ConceptStudio app status

Updated 2026-10-12 for the walkthrough/glossary integration. The baseline includes all seven hardening lanes and
follow-up `cd5f746`, with the review corrections and owner acceptance below. Source checks,
native offline demo checks and bounded FLUX/LTX generation, resume and video training checks
have completed. The GPU proofs predate the review repairs: FLUX used r1; LTX used r2.
The current `v0.2.3-clean-20261011` images contain the review repairs, direct upload and the H3
additions. The owner and Claude subsequently completed a real H3 still-image run on that tag,
recorded in [the walkthrough](../../docs/process/walkthrough-2026-10-11.md). Earlier
FLUX/LTX runtime checks retain their original image scope. See [RUNNING.md](RUNNING.md),
[CORE-STATUS.md](CORE-STATUS.md) and [POD-STATUS.md](../../pod/docs/POD-STATUS.md).

## Walkthrough integration, 2026-10-12

The [repair record](../../docs/process/walkthrough-repairs-2026-10-12.md) maps every finding
to current behavior. Settings groups captioning connections separately from publishing/training
accounts, checks saved keys without generation, and moves selected-model testing to Captioning.
Provider model catalogs respect reported capabilities and actual server/credential context.
New projects have no demo concept; image imports preserve caption/response companions, and
Captioning distinguishes existing, imported and final captions. Mapping proposals can be accepted
in bulk with Undo. Disclosures open across their entire row and Welcome presents the workflow.

The supplied 177-entry glossary, its two readings and all 81 sources are bundled unchanged;
eighteen separate operational entries explain the app. Help supports section filtering, aliases,
related-term navigation and the complete original introduction.

GPU offers respect network-volume location; optional persistent pod disks survive Stop but not
Remove. Unsettled results prevent removal, including lost start acknowledgements. A stale refresh
cannot declare a newly started training/generation action failed. H3 exposes checkpoint cadence,
retention, saved precision and multiple buckets; Circlestone guidance loss stays off and invalid
imports/runs are refused. New valid requests use the published image’s existing parameter contract.

Current offline gates: **550 Swift tests** (289 app and 261 Core), **118 Python reference tests**
and **315 pod-script tests** passed. Strict SwiftLint reports zero violations; SwiftFormat and
Python Ruff/format are clean. Independent source
review accepted project/provider/UI changes; the integration review closed startup settlement
and output-custody defects. Visual/native checks and delivery receipts are recorded in the repair
record. Developer ID signing remains unavailable on this Mac.

## Model table

The supported training models are rows of `Sources/ConceptStudio/Resources/Training/model-table.json`
(format and how to add a model: [model-table.md](../../docs/model-table.md); the pod images copy the
same file). The app loads it once through `ModelTable` (`GPU/ModelTable.swift`, `GPU/ModelRow.swift`)
and the picker, defaults, GPU floor, checkpoint and resolution controls, run.json, saved-run
capabilities, generation frame rules, video formats and caption titles all read the row for the
selected trainer and model. Where a model genuinely differs the row names a hook (`ModelHooks`): the
H3 native recipe, its guidance rules and the LTX video-bucket change to the trainer settings. No code
outside a hook tests a model's name; the trainer (`aitoolkit`, `ltx`) is still branched on.

The table has five rows: FLUX.1-dev, LTX-2, MiniMax H3, Z-Image and Qwen-Image-2.1. Z-Image and
Qwen-Image-2.1 count their training length in epochs (the app sends steps) and show their licence
notice and first-download size under the picker. Both compare through the `aitoolkit_arch_image`
generator hook; Z-Image's picker note says a Z-Image LoRA works on Z-Image-Turbo at about twice the
strength. Qwen-Image-2.1 is offered only on GPUs with at least 80 GB.

## Regularisation images and REPA

Two optional row fields, `regularization` and `repa`, are decoded by `ModelRow` and read by the Training
screen. They apply to AI Toolkit rows only; `regularization` needs a generator hook and no
`trainer_config` hook, and `repa` needs an architecture in `ModelRow.repaArchitectures`. The
Qwen-Image-2.1 row carries both, so the app offers them for that model only.

On the Training screen, between "What to train" and "Run settings" (`GPU/TrainingAidsView.swift`), a
model with the fields shows two sections in plain language, each with its own Definitions:
**Regularisation images** (a toggle, the class nouns taken from the project's concepts, the number of
images, a minutes-and-money estimate from the row's seconds per image and the quoted hourly price, and
the note that training takes about twice as long) and **Representation alignment (experimental)** (one
toggle and the size of the helper-model download). Advanced training controls add "Regularisation
strength" while the toggle is on. A trigger with no concept stops the run with "Define a class noun for
<trigger> in Concepts before training with regularisation images."

`trainingParams` writes `regularization` then `repa` before `extra`, as explicit values: the row's
generation settings and the six AI Toolkit REPA keys, so a saved run repeats the same way after the table
changes (Repeat passes on the saved blocks for the same model). With regularisation on, a length in epochs
doubles into trainer steps, since every other step looks at a regularisation image; Repeat halves it again
to show epochs. Choosing a model resets both toggles to the row's `default_on` and keeps an edited image
count or strength. Starting a run with regularisation on first draws the images (the `draw-regularization`
service, "Drawing regularisation images: 12 of 40"), downloads them, and has the project's own captioner
describe each one with `RegularizationCaptioner` (ConceptCore): the project's endpoint, skill and profile plus
the skill's `references/regularization.md` and the class nouns, never a trigger. On a one-GPU computer the
caption server is stopped for the drawing and started again if the project captions with it. The captions go
to the trainer in `regularization.captions`; Saved runs says what each run used.

The glossary has an entry for `representation-alignment` (alias REPA, section Training progress and
controls); the three terms the sections link to are `StudioTerm.regularizationImages`,
`.priorPreservation` and `.representationAlignment`.

## Implemented

- **Onboarding:** Images contains the owner's full explanation of diffusion
  training, concepts, training data, captions and concept boundaries, with italic glossary
  terms and hover, click and keyboard definitions. The same catalog now supplies contextual
  Definitions on every journey screen, Settings, Advanced training controls, concept/media
  editors, saved runs and generation. Help opens a searchable catalog and the full explanation
  without changing the Images disclosure's remembered state. At the owner's later
  walkthrough request, Welcome uses a brief orientation and ordinary project/account
  actions rather than repeating that introduction. The demo uses photographic examples. Labels describe operations,
  inputs and consequences.
- **One concept by default:** category-specific questions and caption/mapping/reviewer
  instructions for person, object/character, style and motion. Multiple concepts and detailed
  overrides are under Advanced. Style and motion apply to the entire training target;
  Mapping appears only when a concept needs a locator. Human confirmation remains required
  for person, object, character and custom-concept proposals. Concepts restores its ⌘↩ action.
- **Dataset curation:** duplicate candidate groups, Include/Exclude and session Undo, crop
  inspection and approval, HEIC/TIFF normalization. Captioning and publication use only
  included approved targets. Approval invalidates old captions and subject mappings; style
  and motion are reassigned automatically. Previously published excluded targets are removed from
  the next dataset commit; unrelated remote files are preserved and excluded from app training.
- **Real clips:** import from files, folders, Photos or Hub imagefolder; playback, frame
  inspection, exact segment approval and LTX/H3 video captions. The selected model determines
  the permitted segment: LTX uses `8n+1` frames; H3 uses `17n+5` at exactly 24 fps.
  Approved segments preserve the
  selected frames and timing, with aspect-preserving 32-aligned dimensions. Variable-rate
  selections are refused because pinned LTX preprocessing cannot preserve their timestamps;
  constant-rate portions remain selectable. LTX derives its
  preprocessing buckets from those targets. Native Gemini routes accept inline video;
  OpenRouter and vLLM accept a video content part. Python uses pydantic-ai for Gemini and
  OpenRouter and explicitly refuses vLLM video until supported by that library. OpenAI and
  Anthropic refuse clips before sending. Both languages enforce the same encoded-body client
  limit; model capability remains separate from route capability. Hashing and Photos video
  transfer use files on disk, and timeline inspection reads compressed timestamps.
- **Direct dataset upload:** when no Hub token is configured, Publish checks saved inputs and
  Start training uploads an immutable copy directly through the authenticated agent. It includes
  only approved included media, saved captions/records, metadata and the job, with 2 GiB/file
  and 20 GiB/dataset limits. Training waits for atomic installation. Local Resume checks the
  exact input digest in both app and pod; Repeat allows edited data as a new run. No Hub
  dataset account is required; gated base-model access is unchanged. The current
  `v0.2.2-clean-20261011` and later images include this route; the older r2 images do not.
- **Saved training runs:** project-local dataset revisions or local input digests, settings, checkpoints, outputs and
  available GPU cost information; reopen history, Load settings for repeat and supported
  checkpoint resume. Each new run captures its budget and rental-spend baseline before
  preparing inputs, and records them before transfer. Resume retains that cap and adds its continuation cost. The existing
  whole-computer cap still applies. Missing revision or cost information is shown as unavailable.
- **Generated results:** pod generation services for FLUX.1-dev, LTX-2 and H3, checkpoint
  choice, paired base/LoRA generation with matched prompts and seeds, downloaded galleries,
  and Save trained model to this Mac. A comparison is successful only when its downloaded
  manifest says complete and every listed pair is present; partial files remain available
  with a failure message. Other generation combinations explain their limits.
- **OpenRouter browser authorization:** documented PKCE consent, temporary loopback callback,
  Keychain key storage, cancellation, direct API calls afterward, key usage and allowance.
  Manual keys remain available. ChatGPT sign-in remains a separate account path.
- **Caption progress:** ChatGPT's actual deltas reach a per-sample preview while writing.
  Retries, completion, failure and cancellation clear it; partial text never becomes a saved
  caption or response record. Other clients do not simulate a stream.
- **Recent projects:** a missing `job.yaml` has recovery advice distinct from an access failure.
  Remove from recent projects only removes the saved entry, preserving files on disk.
- **Workspace storage:** authenticated usage readout and explicit completed-dataset cleanup.
  Pod starts retain active/current inputs and the last three resumable completed datasets;
  Resume restores a pruned Hub dataset only from its saved exact revision. Pod-side step
  validation refuses a total at or below the saved checkpoint step.
- **Pod credentials as RunPod secrets:** the Hub token and each pod's agent bearer are written
  to the account's secret store before a computer is rented and reach the pod only as
  `{{ RUNPOD_SECRET_… }}` references, so a pod listing never shows a token. The agent secret
  is deleted when the computer is removed; unreferenced ones are pruned at launch.
- **Shared project and cost controls:** CLI-compatible job/sidecar formats, project-contained
  custom skills, private Hub upload, local retrieval, budget/idle stop, launch reconciliation,
  and explicit handling of pending outputs before a computer is stopped.

## Exercised in the native window

**Walkthrough clarity fixes, 2026-10-11:** the rebuilt offline demo was walked from Welcome
through all nine steps. Finished footer messages clear when leaving their step. Concepts has
one forward button and retains ⌘↩. The crop preview shows all four edges and dims excluded
pixels. Local reference-face comparison reports agreement or no confident suggestion beside
each already-confirmed sample, retaining the human assignments. Captioning explains the
demo's fixed format. Editing a caption displays the unsaved notice without moving the image
above the editor. Recent projects show parent folders. Training identifies the computer and
run separately and describes the selected hosted captioning route. Monitor showed no run
before training, then the simulated curve and **Training: Finished** alongside **Computer:
Running**, matching the exited log. Saved-run copy explains data versions and continuation.

Welcome's accessibility press reports an error through the computer-control tool but opens
the disclosure; the same tool error also occurred while successfully opening the demo.
VoiceOver was started for the requested check, but its global navigation keys could not be
verified through that control connection. It was off afterward. A trial storage-binding change
did not alter the behavior and was removed. Full human VoiceOver acceptance remains unverified;
this is not recorded as a repaired application defect.

The owner subsequently asked to remove the repeated introduction from Welcome. That screen
now explains project creation/opening briefly; the full text remains on Images. This removes
the redundant Welcome disclosure rather than changing the owner's explanation.

**Review-repair check:** the rebuilt window showed recent-entry removal controls. In the
offline demo, Concepts ⌘↩ opened Mapping for Person, and opened Captioning directly for
Style and Motion with Mapping absent from the sidebar. The expanded Concepts Advanced
section and exact **Demo · no charges** badge were visually inspected. A simulated computer
displayed storage usage; its cleanup action completed with the retention explanation, then
Stop everything returned it to Exited. No real computer or account was used. Two stale Mapping
instructions found here were corrected and rebuilt. Missing-job removal, no-Hub preparation
and streaming-caption edge cases are covered by automated checks, not a new live GUI claim.

**Earlier overnight check:** the 2026-10-11 rebuilt unsigned app was opened and controlled directly:

- Welcome and the full training explanation; an inline definition opens a native popover.
- Images: three synthetic photographs, Exclude and Undo, crop sheet and Cancel.
- Concepts and Mapping: one-concept presentation and prepared confirmed assignments.
- Captioning: all three prepared captions written without any provider request.
- Review: caption/image pairing, mark Final, Save, and disabled re-caption protection.
- Publish, GPU pods and Training: simulated upload, rental, training completion and Stop.
- Monitor: simulated loss, honest no-real-generation demo state, saved settings and Repeat.
- Settings and Advanced settings, File and Go menus, visible native sidebar and scrolling.

This was an agent walkthrough of the offline demo, not the owner's acceptance or a live paid
training run. It found and repaired a native paragraph-width bug missed by offscreen rendering.
The first Edit concept presentation also exposed a sheet-state defect; the rebuilt native
check passed, including preserving custom style details through reopening and unchanged Save.

## Offline verification

- **Earlier walkthrough/H3/help gate (2026-10-11, before the 2026-10-12 walkthrough/glossary
  integration):** 498 Swift tests passed (238 app tests in 39 suites; 260 Core tests in 38
  suites), plus 117 Python reference tests. H3 media cases export
  real synthetic 22- and 39-frame audiovisual segments and check exact caption/critic request
  bytes, sidecars, publication and Undo. Budget checks include failed/cancelled preparation,
  accumulated Resume cost and restoration without the original project open. The pod's
  script and agent gates are recorded separately in POD-STATUS. These are offline tests;
  the real provider/trainer evidence below retains its original scope.
- **Earlier presentation checks (2026-10-11):** strict SwiftLint and SwiftFormat were clean across 164 Swift
  files. The offscreen harness rendered 116 light/dark, minimum/default screen states,
  including Help at 640 × 480 and 780 × 720. Bounded visual review covered all nine journey
  screens, Welcome, Settings and Help; a narrow Captioning rerender confirmed that the demo
  format explanation wraps without widening the minimum-size form. These are rendered views,
  not fresh native interaction or VoiceOver acceptance. The complete native nine-screen demo
  walkthrough above preceded the H3/global-help additions; their interactive acceptance and
  actual H3 run remain separate.

- **Walkthrough clarity gate, 2026-10-11:** **478 Swift tests** pass (218 app and 260 Core),
  strict SwiftLint reports zero violations, SwiftFormat is clean across 153 files (two
  resource exclusions), and the debug bundle builds. Focused regressions cover navigation
  during both work gates, crop/export geometry, actual Review editor placement, mapping
  conclusions, the demo format lock, run-state explanations and recent-name disambiguation.
  Existing sole-style approval tests also exercised saved mappings and Undo, including the
  file-backed target path. These checks precede the in-progress H3 and per-run-budget work.
- **Review-repair gate, 2026-10-11:** **450 Swift tests** (190 app in 29 suites, 260 Core in
  38 suites), **116 Python tests**, **660 agent**, **291 pod scripts** and **125 podctl**
  tests pass. Strict SwiftLint and SwiftFormat are clean across 145 files (two formatter
  resource exclusions); Python Ruff/format are clean. The debug app bundle builds.
  Independent source review accepted all six repair threads and their composed upload flow.
  The final native-copy corrections were rebuilt and linted after the full test gate.
- Current direct-upload tests use synthetic local inputs, stubbed native HTTP/agent seams
  and the real local installer. They prove exact input preservation, quotas, admission and
  changed-input refusals; they do not establish a live RunPod upload. Streaming-caption proof
  uses actual URLSession SSE through the runner, with no provider request in this round.
- Focused tests cover account authorization/cancellation, category-aware prompts, exact media,
  curation/Undo, Hub file selection, output generation requests, run restore/repeat/resume and
  cost/output custody. Independent source review has driven repairs at the integration seams.
- Actual local video fixtures exercise frame counts, variable timing and visible-edge
  preservation, plus HEIC/TIFF normalization and file/sidecar restoration.
- The earlier 116-frame offscreen set covers Welcome, nine journey screens, Settings,
  concept/crop editors, empty/error states and generated/saved-result surfaces in light and
  dark at minimum/default sizes. None captures an expanded Advanced section. Native vibrancy
  and interactions are verified separately.
- The overnight implementation gate passed **402 Swift tests** (160 app, 242 Core) and **94 Python tests**.
  The final dataset-switch repair then passed **23 focused session/history tests**, including
  the offline demo and current-versus-saved dataset requests, with independent source acceptance.
  Strict SwiftLint is clean; SwiftFormat is clean on 129 source/test files, with two resource
  exclusions. Python Ruff and format checks are clean. The debug bundle builds and explicitly
  links AVKit, whose absence was caught by a valid video-editor render.
- Updated focused renders cover the actual video editor in both appearances, with start time
  and duration visible before approval. Exact frames and image size remain in Advanced.
  The unlocked-Mac follow-up verified keyboard activation and actual video frame selection;
  see the native follow-up below.

## Live evidence and remaining acceptance

Earlier live proofs (2026-10-10) established Swift Hub upload/download, direct Gemini and
vLLM image captions, native RunPod reads/stop, and FLUX/LTX training-event reads. Those proofs
predate this redesign and do not establish its new generation, resume or video paths.

On 2026-10-11, the native Gemini path sent one exact approved synthetic nine-frame,
512 × 288 MP4 and returned HTTP 200 with a usable shared Caption object from
`gemini-3.8-flash` (4,389 input / 76 output tokens). Explicit 24 FPS sampling repaired
the initial default-sampling 400, verified first with a single-variable control and then
the unmodified production client. The private notes receipt at
`evidence/2026-10-11-video-native-proof/README.md` records all three requests. This
is functional provider acceptance, not a caption-quality study, every-source-frame observation
or actual trainer preprocessing proof.

The new FLUX generation service completed a real matched base/LoRA pair at 256 × 256, with
one prompt, seed 42 and four inference steps. The downloaded PNGs and manifest matched their
served hashes. Native `retrieveGeneration` and `downloadRun` fetched those real files; an
offline project reopen restored one run and one comparison with no Keychain or network calls.
The historical source lacked a dataset revision, start time and cost; the retained proof receipt
records its row timestamp as the local import time rather than reconstructing those values.
Resume continued the retained synthetic training run from step 2 to step 3,
exited successfully and saved a distinct valid checkpoint with step-3 metadata. These small
checks establish execution, not training quality. The proof GPU was stopped and independently
read back as Exited. The final checkpoint-snapshot images passed source/hash and CPU control
checks. LTX preprocessed the approved clip at its derived 512 × 288 × 9 bucket, completed two
training steps, then resumed to step 3. It generated a real matched base/LoRA pair: each video
decodes to 49 frames at 512 × 512 and 24 fps. Its complete manifest records the selected step-3
checkpoint hash. Native collection and offline reopen passed for those model/video files and
the recorded dataset revision. The LTX proof pod was also stopped and independently read back
as Exited. The approved input hash is verified at native export and exact-revision Hub download,
not directly on the pod filesystem.

The current TensorBoard session/cookie handshake passed through the real RunPod proxy,
including rejected unauthenticated and out-of-scope requests. This proves backend access,
not native WebKit rendering. Both new proof pods used one 32 GB GPU and 62 GB host RAM; these
small recipes do not establish a memory guarantee for other datasets or settings.

Current trainer images are published under `v0.3.2-20261014`, a clean build of the regularisation and
REPA change at `374e695` (`v0.3.1-20261014` is the same change before its review fixes, at `0124582`; the earlier `v0.3.0-20261014` was built from PR #10 at `f784947`, and
`v0.2.3-clean-20261011` from `main` at `b7908618`) (digests in `pod/images/README.md`), and verified by
anonymous tag-to-digest checks. The app default uses this tag. The owner/Claude H3 still-image training
run used `v0.2.3-clean-20261011`;
the earlier bounded FLUX/LTX proofs used the r1/r2 tags, which stay published. Their
separate scopes and limits are recorded in POD-STATUS.

On 2026-10-11 the owner confirmed signing in and captioning live through both ChatGPT and
OpenRouter. These are owner-reported native acceptance checks for account access and captioning;
they supersede the earlier pending account/captioning notes. The OpenRouter credential method
was not separately recorded, so this does not prove a particular OAuth callback URL. These
checks do not establish a quality comparison or every model's video support.

Owner acceptance and distribution still pending:

- Live checks of direct upload, storage cleanup and repaired generation/Resume on the
  published clean image. Its rebuild/default update and Hub-token secret integration have
  landed separately; they are not work performed by this walkthrough repair round.
  H3 still-image training on v0.2.3 has owner/Claude acceptance; H3 clips, external
  warm-start, same-run Resume and matched generation still need live acceptance.
- Native TensorBoard rendering during an actual run. Offline state and the live backend
  handshake are verified separately; no GPU was restarted solely for this UI check.
- A follow-up walkthrough of these repairs. The owner/Claude walkthrough and first real
  H3 still-image training run have completed; this new UI has separate acceptance below.
- VoiceOver acceptance, Photos permission/bookmark persistence in a signed sandboxed build,
  Developer ID signing and notarization. The preview remains unsigned.

The app's budget and idle limits run on the Mac. They cannot stop a rented computer while the
app is absent or the Mac is asleep. Launch reconciliation resumes those guards. Separately
billed saved storage remains after GPU stop. This limitation is unchanged; there is no claim of
server-side budget enforcement.

## Unlocked-Mac follow-up, 2026-10-11

Native file import and playback passed with synthetic clips. A selected 17-frame segment
starting at frame 19 exported as exactly 17 frames at 30 fps and 512 × 288; Undo restored the
original file hash. Actual thumbnail clicks exposed imprecise AVPlayer seeking; the repair
pauses playback, clears the old segment boundary and seeks with zero tolerance. The rebuilt
window displayed the selected first and late frames correctly. Keyboard Tab reached glossary
definitions; Space and Return now open the existing popover, and Escape dismisses it.
All three keys passed in the final rebuilt window.

The real retained FLUX comparison appeared as two labelled images. Its gallery and model
Reveal actions selected the correct folders in Finder. Save with stopped storage displayed the
required connection instruction. The retained LTX comparison reopened as two native video
players and playback was exercised. These checks reuse the earlier actual downloads; they are
not another live training or download claim. Command-number navigation and Go Back worked.
OpenRouter opened its real browser authorization entry and native Cancel returned to an
unconnected state. ChatGPT reached the owner's two-factor challenge; cancellation also passed.
The owner subsequently completed sign-in and live captioning with both providers, as recorded above.

Recent-project restoration passed after quitting and reopening the same preview build. A
rebuild exposed an access-restoration failure that was incorrectly reported as a deleted
folder. The development bundle uses an executable-specific ad hoc identity; signed-build
bookmark persistence remains unverified. The error handling now preserves entries on access
failures and asks users to reselect the folder rather than claiming it disappeared. The final
rebuilt native check confirmed both the correct error and the retained Recent entry. These
repairs passed 25 focused Swift tests, strict lint/format checks and independent source review.

### H3 source integration and remaining runtime proof

The H3 route now uses the pinned AI Toolkit `minimax_h3` implementation, BF16 component
downloads, exact approved clip groups and an optional imported native recipe. A new run can
start from copied external LoRA weights; its old counters are discarded and its optimizer
starts fresh. Same-run Resume remains a separate operation. Captions already name their
mapped concepts, so the wrapper no longer injects the first trigger into every sample.
H3 comparisons use the captured native network recipe and selected trained weights, with
matched prompts/seeds for base and LoRA. Still-trained H3 LoRAs can generate stills or video.

The native path checks for a 96 GB GPU before H3 input transfer, based on the known reference
recipe. That does not establish memory fit for every setting. Metadata-only inspection of
the 18 prepared project clips accepted their exact decoded frame counts, 24 fps timing and
32-aligned dimensions under a 1024 resolution cap; no pixels or audio were inspected by
that check. The new export, initializer, generation and budget source checks passed the
offline integration gate; the earlier FLUX/LTX GPU proofs do not validate this H3 implementation. An
AI Toolkit image containing these changes was subsequently published as v0.2.3 and
the owner/Claude completed the 3,000-step still-image run described below. H3 clip training,
warm-start, Resume and matched generation remain separate runtime checks. This repair
session did not start a family training run.

## Owner/Claude H3 run, recorded 2026-10-12

The [walkthrough record](../../docs/process/walkthrough-2026-10-11.md) reports a completed
3,000-step H3 identity LoRA run using 69 still images, Gemini captions and the clean
v0.2.3 AI Toolkit image on a 96 GB RTX PRO 6000. The 179 MB result was pushed privately,
and the computer was stopped after approximately 72 minutes. The record estimates about
$3 GPU cost; this is not a newly queried settled invoice. These are owner/Claude runtime
receipts, not a GPU run performed by this walkthrough-fix session. They establish the
still-image train/publish/stop path, not H3 clips, warm-start, Resume or generation.

## ChatGPT connection follow-up, 2026-10-11

The reported invalid-stream-event failure came from the primary checkout's stale app bundle,
built before the `60469b4` raw-byte SSE repair. Rebuilding the usual preview location
includes that framing repair. A live request then exposed a second issue in current source: the
provider sent the complete caption in `response.output_item.done`, followed by a successful
completion with `output: []`. The client now retains those indexed completed items and uses
them when that final output array is empty. It still requires `response.completed`, preserves
a nonempty final output, and rejects failed, incomplete, interrupted and refused responses. Native Settings confirmed the saved ChatGPT
account has plan access and the OpenRouter key remains in Keychain.

A fresh app restart also exposed an empty-model-catalog problem in Settings: testing the
ChatGPT connection required visiting Captioning first. The connection test now prepares the
selected account's model catalog inside its existing cancellable operation before resolving
the client. It preserves the selected model and credentials and reports discovery errors.
Gemini's existing local key was installed separately in the app's Keychain; no key values or
account credentials are committed to the repository.

The post-fix live check used the actual rebuilt `ChatGPTModelClient` with the owner's selected
unexpired ChatGPT registration and one synthetic demo PNG. It received HTTP 200 and decoded a
usable Caption from `gpt-6.1-sol` (2,067 input / 49 output tokens). This proves the production
client's image/structured-output path; it is not a caption-quality evaluation or a native Runner
sidecar-save check. Computer-control access timed out on the final Settings click; the owner
subsequently confirmed that test succeeded and that live captioning worked. Focused gates
passed 19 Core stream test methods and 23 app
account test methods; both changes received independent source acceptance. The usual primary
checkout preview is updated along with the worktree build. Development signing remains deferred
at the owner's request.
