# ConceptStudio app status

Development preview prepared on 2026-10-10 at `app/dist/ConceptStudio.app`. It was built and
its bundle metadata validated; an automated agent has not launched the GUI. The app is an
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
computer remains managed until explicit removal, preventing a new rental from orphaning its
billed disk. GPU choices require current stock at the selected network volume’s location.
The publish contract is replayed through the actual
Core Hub source/Runner and the actual Python pod imagefolder collector/writer: three intended
images with captions and no reference-image contamination. Vision revision 2 uses conservative
photo similarity and face-proposal thresholds with an ambiguity margin; pixel-equivalent and
distinct-image witnesses cover the sample behavior, not calibrated face recognition. Build and
strict lint and formatting pass, and the final app gate passes 27 tests in seven suites
(16 app tests and 11 GPU tests). Independent coordinator review accepted the app, and the
Sol core reviewer independently accepted the GPU module and its failure-path repairs. The
coordinator also ran the complete package: 27 app/GPU tests plus 207 core tests, all passed;
strict lint and formatting were clean. The final provider-change handler preserves the
verified pod model instead of overwriting it with a different default.

These are headless checks. Pixel layout and interactive keyboard/VoiceOver use have not been
observed, because GUI launch is prohibited. Keychain save/read, Apple Photos/iCloud selection,
real security-scoped bookmark restoration, live model requests, live Hub import/publication,
real RunPod creation and trainer hardware behavior are not established by the app tests.
Read-only live native RunPod calls successfully decoded the actual catalog and network-volume
responses. `CORE-STATUS.md` also records a real Swift Hub upload/verify/download round trip.
Those proofs do not establish interaction with the app UI. Separate pod-stream evidence owns
real container tags, GPU training and spend.

The preview is unsigned and not notarized. Signing, notarization, sandbox runtime checks and
distribution approval remain external release work described in `RUNNING.md`. This file does
not claim that a fake training result is a real LoRA or that a built bundle is a published app.
