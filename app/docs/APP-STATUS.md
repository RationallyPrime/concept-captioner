# ConceptStudio app status

Development preview prepared on 2026-10-10 at `app/dist/ConceptStudio.app`. It was built and
its bundle metadata validated. Agent-driven GUI checks reached Welcome, demo Images and
Concepts, with all nine navigation entries visible. Concepts showed the reference image,
Learn/Describe boundary, guidance and next action at 1240 × 820 without obvious clipping.
The user confirmed that Next: Concepts works and the app responds normally. Native control
then disconnected again on the first attempted navigation, while the Mac was unlocked and
the app remained running. This is a tool-transport failure, not an observed app crash;
Mapping through Monitor and the complete interactive walkthrough remain unverified. The app is an
unsigned macOS 15+ Swift 6 / SwiftUI executable, with SwiftPM and Yams as its only third-party
dependency. `scripts/build-app.sh` produces the bundle; `RUNNING.md` covers first run and
distribution requirements.

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
The latest integration passes 238 Swift tests (31 app/GPU and 207 Core), strict lint and
formatting. The unsigned preview is rebuilt with the automatic image choice.

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
