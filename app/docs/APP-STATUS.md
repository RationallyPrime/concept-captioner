# ConceptStudio app status

The development preview at `app/dist/ConceptStudio.app` includes the 2026-10-10 native UI
refinement using Impeccable. Its design direction is recorded in [DESIGN.md](../DESIGN.md),
with APP-BRIEF remaining the product authority. The owner supplied hakonfreyr.com as a quality
reference. The refinement uses a photo workspace, clearer hierarchy and progressive controls
while preserving the nine-screen journey and the shared captioning/training contracts.

The earlier agent-driven GUI checks reached Welcome, demo Images and Concepts before this
refinement. The user confirmed that Next: Concepts works and the app responds normally.
The native computer-control connection still fails with a closed transport pipe; the last
read failure did not establish an app crash or a locked Mac. The refined UI has offscreen
layout evidence described below, but its complete interactive walkthrough remains pending.
The preview is an unsigned macOS 15+ Swift 6 / SwiftUI executable, with SwiftPM and Yams as
its only third-party dependency. Its build and bundle metadata validate; `RUNNING.md` covers
first run, the repeatable render command and distribution requirements.

## Implemented

Welcome with new/open/recent projects and offline demo; Settings with gateway-first Keychain
storage, direct-provider accounts, a cancellable captioning connection test and Advanced GPU
image/volume settings. A native split view exposes all nine journey screens, guidance, next
actions, the Demo badge, running cost and Stop everything.
Startup recovery runs only for saved metadata naming a potentially running computer. Welcome
shows that retained computer and its cost, with stop controls before a project is opened.

The first six screens use the shared ConceptCore Job, Runner and sidecar formats: folder,
selected-file, Apple Photos and Hub imagefolder import; Vision face detection, face quality,
readable-text and exact/near-duplicate warnings; reference images, explicit concept boundaries
and model-drafted boundary decisions; on-device and multimodal mapping proposals that require
confirmation; live per-image caption outcomes with optional critic, cancellation, skill/profile/
model controls and saved endpoint settings; final-caption protection, selective re-captioning
and a comparison sink that does not replace saved captions; one-commit Hub publication of
training images/sidecars at the dataset root, `concept-captioner/job.yaml` and imagefolder
metadata. Reference faces stay local, and published paths preserve sample/mapping/record IDs.

The GPU module supplies RunPod catalog/lifecycle, storage selection, plan, trainers,
logs, curves, authenticated TensorBoard, budget and idle-stop logic, and fake providers. The app
passes the project's triggers/profile into that module. Captioning has a direct route to GPU
rental and a user action to start and select the authenticated app-created vLLM server, so a
one-GPU user can caption before training. Its pod token remains outside the job. Closing waits
for local cancellation and confirmed provider stop before releasing project folder access.

Both trainer containers are public and passed anonymous pulls of the exact verified image
digests on 2026-10-10 at 21:25 UTC. A fresh installation now automatically selects the included
image for the chosen trainer. Missing or blank image preferences use that default; a nonblank
custom image is preserved. Clearing and saving an Advanced override restores the included
image immediately. No registry setup is required for the included images.

Demo model outcomes include written, unusable, rejected and failed; Core supplies unmapped,
skipped and protected-final outcomes. The model, assistance, publish and GPU demo actions use
local data/fakes. No demo Keychain reads or network calls are performed; Apple Photos import is
disabled in demo to prevent iCloud access.

## Evidence and boundaries

Focused app tests exercise the shared project round trip and sidecars, final protection after
overwrite/reopen, stem-collision avoidance, all demo model outcomes, the nine-screen demo action
sequence through fake training/result publication/stop, cancellation settlement, and the trusted
pod endpoint/key construction without copying the token into the job. Downloaded captioner and reviewer URLs stay
separate from the user's configured key host, with injected-wire coverage for omitted keys.
Finite assistant draft schemas and decoding cover hosted strict structured-output constraints.
The GPU module has stubbed-wire and fake-lifecycle tests, including retained state and confirmed
stops. Idle and budget stops survive agent/proxy errors and Keychain failures; a stopped
computer remains managed until explicit removal, keeping one computer under the app's control.
Stopping clears the temporary container disk; separate network storage persists and remains
billed. GPU choices require current stock at the selected network volume’s location.
The publish contract is replayed through the actual
Core Hub source/Runner and the actual Python pod imagefolder collector/writer: three intended
images with captions and no reference-image contamination. Vision revision 2 uses conservative
photo similarity and face-proposal thresholds with an ambiguity margin; pixel-equivalent and
distinct-image witnesses cover the sample behavior, not calibrated face recognition. Build and
strict lint and formatting pass, and the initial app gate passes 27 tests in seven suites
(16 app tests and 11 GPU tests). Independent coordinator review accepted the app, and the
Sol core reviewer independently accepted the GPU module and its failure-path repairs. The
coordinator also ran the complete package: 27 app/GPU tests plus 207 core tests, all passed;
strict lint and formatting were clean. The final provider-change handler preserves the
verified pod model instead of overwriting it with a different default.

After the real Qwen 8B run, both app caption-server startup paths were updated to use its
working context, concurrency and memory settings. Concurrent training also reuses an already
active caption server instead of issuing a duplicate start that the agent rejects with 409.
The focused GPU suite now passes 12 tests, with wire witnesses for both startup paths and
training on GPU 1 while the existing caption server stays on GPU 0. An independent reviewer
reran that suite and accepted the frozen repair; product build, strict lint and format passed.
The full 234-test result above remains the earlier integration boundary. These startup checks
establish app wiring, not caption quality; the live experiment has rejected the initial 8B
captions for describing traits that its job reserves for the concept.

The next measured-defaults change adds the successful LTX 8-bit optimizer, quantization,
text-encoder loading and tiled image-preparation settings to the actual training request.
Both trainers retain the existing caption-server start/reuse behavior. Rental now requires
at least 32 GB per GPU and requests a 60 GB host-RAM placement floor per GPU. This avoids
offering devices too small for the included Qwen 8B server; it is not a guarantee for arbitrary
models or datasets. The focused GPU suite passes 13 tests, with independent acceptance of
the frozen change. That integration passed all 236 Swift tests (29 app/GPU and 207
Core), strict lint and formatting; the unsigned preview bundle was rebuilt and its metadata
and entitlement plist validated.

The public-image default change then passed seven focused action tests, including eight
cases observing the actual native create request for both trainers with missing, blank or
custom preferences, and three save/reset cases. Parent review accepted the scoped change.
That integration passed 238 Swift tests (31 app/GPU and 207 Core), strict lint and
formatting. The unsigned preview is rebuilt with the automatic image choice.

The native UI refinement adds a shared type/spacing/color vocabulary, a contact-sheet gallery,
Learn/Describe columns beside the reference, thumbnail mapping navigation, adaptive review,
account-key guidance and explicit TensorBoard loading/error/reload states. All original model,
skill, profile, GPU and trainer controls remain available. Review retains unsaved drafts across
photo/screen navigation; explicit Save and Command-S write the active caption. Failed saves
retain drafts, Discard restores the current saved version, and project replacement/close/quit
warn before discarding. Cancelling a concept editor cancels only its owned draft request.

The latest integration passes **246 executed offline Swift tests** (39 app/GPU and 207 Core).
The separate opt-in rendering test is skipped by an ordinary run. Eight new draft tests cover
navigation, explicit final saves, filesystem failure/retry, later-edit retention, discarded or
undone drafts followed by a real demo recaption, and draft-only quit confirmation. Independent
source review accepted the change and its bounded layout repair. Strict lint and formatting
pass across 84 source/test files; the arm64 unsigned bundle and its plists validate. Later
changes to layout only were built/linted and checked through the native renderer; they do not
change the tested caption or service contracts.

The render command uses the actual SwiftUI views in never-shown native windows, an isolated
copy of the source and the existing local dependency checkout. It uses only the bundled demo
and fake services. The visual matrix covers all nine screens plus Welcome and Settings at
980 × 680 and 1240 × 820 in both appearances, and the concept editor at 660 × 650. Inspection
found and repaired a minimum-height problem that pushed the shell header/footer out of view.
Captioning's Start action and cost explanation now stay visible while choices and results
scroll. Filled primary buttons use a darker tint than links to keep white labels readable in
both appearances. Native sidebar/selection vibrancy is inaccurate in offscreen cached drawing; those
pixels cannot establish live appearance contrast. The captures use a simulated active-control
appearance and show initial viewports, not scrolling or input. The human walkthrough still
needs to verify native focus, keyboard/menu actions, dialogs, VoiceOver and full live flow.

The automated action tests above are headless checks. Complete pixel-layout and interactive
keyboard/VoiceOver coverage remain pending. Keychain save/read, Apple Photos/iCloud selection,
real security-scoped bookmark restoration, live model requests, live Hub import/publication,
real RunPod creation and trainer hardware behavior are not established by the app tests.
Read-only live native RunPod calls successfully decoded the actual catalog and network-volume
responses. `CORE-STATUS.md` also records a real Swift Hub upload/verify/download round trip
and an authenticated native-schema image request to the owned Qwen pod. A single direct
Gemini 3.8 Flash request also returned 200 and decoded the shared Caption schema from a
bundled synthetic demo image. That establishes native provider integration, not a caption
quality comparison or full training-prompt evaluation.
Those proofs do not establish interaction with the app UI. Separate pod-stream evidence owns
real container tags, GPU training and spend.

On 2026-10-10, a separate headless probe using an exact copy of the app's `PodAgentClient`
also read the owned live agent's plan, services, trainer logs and persisted FLUX events over
authenticated HTTP. All four requests returned 200. The same `TrainingPoint` consumed by
Monitor decoded step 2 and loss 0.05031000077724457, matching the real event scalar.
Source hashes were checked after the calls. This establishes native control reads and curve
decoding; it does not establish rendered chart interaction. The first live LTX run saved
checkpoints but lacked TensorBoard in its trainer environment. After that dependency was
added to the image, a fresh 512-pixel, rank-16 LTX run completed two steps on one visible
32 GB GPU in a two-GPU pod. One authenticated native events request at 19:46 UTC decoded
step 2 and loss 0.04809999838471413, exactly matching its real `scraped/loss` scalar.
Both trainers now have actual native loss-point decoding evidence. Neither probe establishes
rendered chart interaction or training quality.

The actual native `RunPodProvider` also performed the required final shutdown of the owned
two-GPU pod. At 19:58 UTC, an authenticated GET decoded RUNNING, its stop POST returned 200,
and a separate fresh native GET decoded EXITED. This proves the provider stop/status path
against a real pod; the app's complete interactive rental-to-shutdown flow remains unverified.

The preview is unsigned and not notarized. Signing, notarization, sandbox runtime checks and
distribution approval remain external release work described in `RUNNING.md`. This file does
not claim that a fake training result is a real LoRA or that a built bundle is a published app.
