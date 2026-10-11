# ConceptStudio app status

Updated 2026-10-11 after the overnight implementation, based on all seven hardening lanes and
follow-up `cd5f746`. Source checks, native offline demo checks and bounded current-image
FLUX/LTX generation, resume and video training checks have completed. Owner acceptance remains
separate. See [RUNNING.md](RUNNING.md),
[CORE-STATUS.md](CORE-STATUS.md) and [POD-STATUS.md](../../pod/docs/POD-STATUS.md).

## Implemented

- **Onboarding and the entire nine-screen flow:** the owner's full explanation of diffusion
  training, concepts, training data, captions and concept boundaries; italic glossary terms;
  hover, click and keyboard definitions. Welcome uses ordinary project/account actions and
  photographic demo examples. Labels describe operations, inputs and consequences.
- **One concept by default:** category-specific questions and caption/mapping/reviewer
  instructions for person, object/character, style and motion. Multiple concepts and detailed
  overrides are under Advanced. A sole style applies to the entire training target without
  face identification. Human confirmation remains required for subject proposals.
- **Dataset curation:** duplicate candidate groups, Include/Exclude and session Undo, crop
  inspection and approval, HEIC/TIFF normalization. Captioning and publication use only
  included approved targets. Approval invalidates old captions and subject mappings; a sole
  style is reassigned automatically. Previously published excluded targets are removed from
  the next dataset commit; unrelated remote files are preserved and excluded from app training.
- **Real clips:** import from files, folders, Photos or Hub imagefolder; playback, frame
  inspection, exact segment approval and LTX video captions. Approved segments preserve the
  selected frames and timing, with aspect-preserving 32-aligned dimensions. Variable-rate
  selections are refused because pinned LTX preprocessing cannot preserve their timestamps;
  constant-rate portions remain selectable. LTX derives its
  preprocessing buckets from those targets. Direct Gemini and Pydantic's Google route accept
  native video; other native transports fail explicitly instead of sending a poster frame.
- **Saved training runs:** project-local dataset revisions, settings, checkpoints, outputs and
  available GPU cost information; reopen history, Load settings for repeat and supported
  checkpoint resume. Missing revision or cost information is shown as unavailable.
- **Generated results:** actual pod generation services for FLUX.1-dev and LTX-2, checkpoint
  choice, paired base/LoRA generation with matched prompts and seeds, downloaded galleries,
  and Save trained model to this Mac. Other generation combinations explain their limits.
- **OpenRouter browser authorization:** documented PKCE consent, temporary loopback callback,
  Keychain key storage, cancellation, direct API calls afterward, key usage and allowance.
  Manual keys remain available. ChatGPT sign-in remains a separate account path.
- **Shared project and cost controls:** CLI-compatible job/sidecar formats, project-contained
  custom skills, private Hub upload, local retrieval, budget/idle stop, launch reconciliation,
  and explicit handling of pending outputs before a computer is stopped.

## Exercised in the native window

The 2026-10-11 rebuilt unsigned app was opened and controlled directly:

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

- Focused tests cover account authorization/cancellation, category-aware prompts, exact media,
  curation/Undo, Hub file selection, output generation requests, run restore/repeat/resume and
  cost/output custody. Independent source review has driven repairs at the integration seams.
- Actual local video fixtures exercise frame counts, variable timing and visible-edge
  preservation, plus HEIC/TIFF normalization and file/sidecar restoration.
- 114 offscreen render frames cover Welcome, nine journey screens, Settings, Advanced,
  concept/crop editors, empty/error states and generated/saved-result surfaces in light and
  dark at minimum/default sizes. Native vibrancy and interactions are verified separately.
- The full implementation gate passed **402 Swift tests** (160 app, 242 Core) and **94 Python tests**.
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

Current trainer images are published under `v0.2.0-overnight20261011-r2` and verified by
anonymous digest pulls. The app defaults and public template use these images. Bounded GPU
checks and their limits are recorded in POD-STATUS.

Owner acceptance and distribution still pending:

- Live ChatGPT and OpenRouter consent and authenticated captioning under the owner's account.
- Native TensorBoard rendering during an actual run. Offline state and the live backend
  handshake are verified separately; no GPU was restarted solely for this UI check.
- The owner's full morning walkthrough and first real dataset training run.
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
unconnected state. ChatGPT reached the owner's two-factor challenge; cancellation also passed. Live consent remains pending.

Recent-project restoration passed after quitting and reopening the same preview build. A
rebuild exposed an access-restoration failure that was incorrectly reported as a deleted
folder. The development bundle uses an executable-specific ad hoc identity; signed-build
bookmark persistence remains unverified. The error handling now preserves entries on access
failures and asks users to reselect the folder rather than claiming it disappeared. The final
rebuilt native check confirmed both the correct error and the retained Recent entry. These
repairs passed 25 focused Swift tests, strict lint/format checks and independent source review.

### Known limits before an existing H3 project can train here

The app's ordinary H3 launch currently selects `arch: h3`, whereas the pinned AI Toolkit
registers `minimax_h3`. Its global first-trigger setting also injects that trigger into captions
for other concepts. Neither path is suitable for an existing dual-identity H3 continuation.
Built-in result generation supports FLUX.1-dev and LTX-2, not H3; actual video training currently
uses LTX. Importing and faithfully continuing an externally trained H3 checkpoint and its
specialized recipe is not established by the same-storage FLUX/LTX Resume proofs. These are
concrete integration gaps, not likeness-quality findings. No family training was started.
