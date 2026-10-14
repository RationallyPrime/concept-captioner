# Status history, 2026-10-10

The three status documents as they stood at lab commit `e620882` (2026-10-10 23:04 UTC), before
they were rewritten as current-state summaries on 2026-10-11. The text below is the original,
unchanged except for two things: evidence paths under `/tmp/` were moved on 2026-10-11 to the
private notes directory and are cited at their new location,
`~/Projects/concept-captioner-notes/evidence/2026-10-10/` (file names unchanged); and relative
link targets were repointed so they resolve from `docs/process/` (the core section's
APP-STATUS link now points at the app section of this file).

Current state: [APP-STATUS](../../app/docs/APP-STATUS.md),
[CORE-STATUS](../../app/docs/CORE-STATUS.md), [POD-STATUS](../../pod/docs/POD-STATUS.md).

Contents: [app](#conceptstudio-app-status) · [core](#core-status) · [pod](#pod-status)

---

# ConceptStudio app status

## ChatGPT account integration, 2026-10-10

Settings now offers **Log in with ChatGPT**, using OpenAI's official **Continue with ChatGPT**
browser flow for open-source apps. The native implementation uses PKCE, validates the signed
identity, keeps separate account registrations and rotating credentials in Keychain, discovers
the account's available models, and supports reauthorization and sign-out. Sign-out reports
when remote revocation could not be confirmed. The first successful plan-enabled sign-in
explains plan usage; ordinary returning sign-in does not force another consent screen.

Captioning keeps `kind: openai` in shared jobs and offers an explicit local choice between
ChatGPT plan usage and separately billed OpenAI API credits. That choice applies to OpenAI
captioning, reviewers, comparisons and assistance. The active ChatGPT account and Manage usage
link are visible. No OAuth credentials or registration enter project files, and there is no
automatic switch to API billing. The Python CLI retains its independent API-key configuration.

ChatGPT requests use the fixed public Responses endpoint with image inputs, structured output,
`store: false` and streaming. Only `response.completed` can become a saved caption. A confirmed
plan limit cancels the active batch and blocks subsequent requests from that client; the alert
opens ChatGPT usage settings. Unsupported preview options, including output-token caps, are
rejected before inference. An explicit default-settings action provides recovery without
editing the job file and preserves unrelated providers' settings.

The sandbox declaration adds network-server permission solely for the temporary HTTP callback
bound to `127.0.0.1`; completion, cancellation and timeout close it. Stop everything, project
close and entering demo settle account work. Demo sign-in remains disabled. The integration
adds no third-party dependency or subprocess.

The final local integration passed **276 executed Swift tests**: 59 app/GPU/authentication
and 217 Core. The opt-in renderer was skipped in that ordinary test run. Strict lint found
zero violations; formatting found 0/94 source/test files requiring changes. The debug `.app`
rebuilt with an arm64 executable and valid Info/entitlement plists. Focused offline checks cover
PKCE and callback state, signed identity claims, separate accounts, rotating refresh,
terminal versus temporary credential failures, sign-out/late-refresh ordering, demo/stop
handoffs, model catalogs, streamed completion, image/schema bodies and usage-limit cancellation.
Independent source review accepted the feature after rerunning 22 auth/identity/endpoint tests
and 12 focused Core tests. Its catalog visibility, stale account status and cancellation-handoff
findings are closed; this acceptance covers the implementation and offline witnesses.

Independent visual review accepted the added controls in ten states: Captioning and demo
Settings at minimum/default sizes in light/dark, plus the actual sign-in section in both
appearances. Eight layouts are captured under `app/dist/visual-check/chatgpt-final`; the two
corrected sign-in captures are under `app/dist/visual-check/chatgpt-mark`. The sign-in section
uses the approved mark loaded from its resource bundle. The captures use synthetic account
and model data with injected credential/HTTP/browser seams; no real credentials or requests.
They establish layout, not interactive access, VoiceOver or native sidebar vibrancy.

The real browser consent flow, Keychain persistence in the distributed signed app, and an actual
image-caption response through a user's ChatGPT plan remain unverified. Those require a user
to authorize ConceptStudio's own registration. Existing Codex/ChatGPT credentials have not been
read or reused. The latest native-control attempt reported `cgWindowNotFound`; process inventory
shows ConceptStudio running, but the rebuilt version's window could not be inspected or its
relaunch confirmed. Quit and reopen the preview for the human check. The preview remains unsigned;
signed sandbox and distribution checks remain
pending. See [RUNNING.md](../../app/docs/RUNNING.md#caption-with-your-chatgpt-plan) for the user flow and the
official integration references.

## Previous UI checkpoint

The development preview at `app/dist/ConceptStudio.app` includes the 2026-10-10 native UI
refinement using Impeccable. Its design direction is recorded in [DESIGN.md](../../app/DESIGN.md),
with APP-BRIEF remaining the product authority. The owner supplied a portfolio site as a quality
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

---

# CORE-STATUS

State of ConceptCore on 2026-10-10 after the handoff repairs and ChatGPT captioning work.

## ChatGPT plan captioning

The native ChatGPT client accepts an asynchronous account-token provider and sends image-aware
structured caption requests only to the public OpenAI Responses endpoint. It requires
`store: false`, streaming, and a completed terminal response before returning a caption.
It reuses the existing Responses encoders and parser; API-key routes retain their behavior.
Unsupported preview settings fail before credential access. HTTP and streamed usage-limit
errors stop new requests from the client and notify the app to cancel its batch.

The independent reviewer accepted the exact Core changes after rerunning 12 focused tests
across the ChatGPT and existing Responses gateway suites, including URLSession through an
offline URLProtocol. The final integrated package passed **217 Core tests in 31 suites**;
strict lint and formatting passed. Interrupted, failed, incomplete and malformed streams,
image/schema requests, cancellation, token acquisition and usage-limit handling have offline
evidence. Real ChatGPT-plan inference still requires a user's sign-in and remains unverified.
The app owns browser OAuth, Keychain credentials and account/model controls; see
[APP-STATUS.md](#conceptstudio-app-status) for their evidence and remaining boundaries.

## What exists

All nine modules of `CORE-SPEC.md` are implemented with tests: models (Job and friends, YAML),
skills (Agent Skills loader, bundled skill as a resource), prompt, triggers, images, model clients
(OpenAI-compatible, Responses, Anthropic, Gemini; structured output with one in-conversation retry;
`resolve` with the key-safety rule), runner (streaming outcomes, optional critic, response
records, human-final skip), sources (local folder, sidecar sink) and hub (Hub client with LFS
upload and verify, imagefolder source and sink).

Handoff baseline: `swift build` and `swift test` green, 183 tests in 26 suites; swiftformat and
swiftlint clean. The earlier gateway acceptance is the 207-test run recorded below. The workflow's four review lenses (parity with the Python
reference, Swift 6 concurrency, API fitness for an app, wire formats of the three clients and the
Hub) produced 28 findings, 19 confirmed adversarially, 14 fixed inside the workflow. The fixer
on `HubClient.swift` was interrupted mid-edit; the missing call-site change was completed by hand
and the suite re-run.

The offline suite covers stubbed model transports and the runner. The Swift Hub client,
owned vLLM endpoint and one direct Gemini request have passed the live checks below.
Other direct-provider and gateway requests remain verified offline only.

## Accepted gateway and provider work, 2026-10-10

The Sol core author implemented Vercel and Pydantic AI Gateway routes alongside OpenRouter.
Each has its own key and fixed origins. Pydantic routing uses native Vertex, Anthropic,
Responses (the default OpenAI route), or explicit Chat Completions, matching the finite
supported Python routes. Job URLs cannot redirect gateway keys. Unsupported upstreams and
key regions fail with configuration errors.

Independent coordinator review accepted the frozen changes after source inspection, outgoing
request tests and a complete isolated core run: **207 tests in 30 suites passed**. The isolated
SwiftPM package uses the exact repository source/tests and existing Yams checkout; it establishes
core behavior while app screens are still being edited. The author’s strict SwiftLint and
SwiftFormat checks passed on all eleven changed source/test files. These are offline checks;
live acceptance for other direct providers and gateways remains outstanding. Subsequent
live Hub, owned vLLM and direct Gemini evidence is below.

The remaining handoff findings are dispositioned:

- Hub LFS verification was already called after every pending PUT. New tests verify ordering,
  object IDs/sizes, headers and that verification failure prevents the commit. No Hub code rewrite.
- Claude thinking uses model-family budget/adaptive capabilities, only supported effort values,
  and sufficient output-token space; explicit insufficient limits fail clearly.
- Gemini thinking uses 2.5 budgets or the family’s supported levels, with old non-thinking
  models omitted and the Developer/Vertex distinction retained.
- OpenAI-compatible thinking rejection retains the provider response and names the model,
  selected effort and corrective setting action. This does not claim every model accepts thinking.

`Runner.run` now provides an awaited async outcome callback for the app. Tests demonstrate
updates before completion and cancellation draining an uncooperative provider before returning;
no source access is released while a child can still write.

## Not done yet

- Live OpenAI/Anthropic and gateway requests remain outstanding.
- Parquet-backed Hub datasets remain out of scope for v1; imagefolder convention only.

## Accepted key-routing repair, 2026-10-10

The key-routing finding is repaired and independently accepted by the Sol key-review agent:
the vLLM key is bound to the user-configured host in Python and Swift;
job authentication/routing headers and sampled ambiguous URL inputs are rejected. The Swift
KeyStore now carries the user-configured vLLM endpoint separately from the job.

Local checks after this repair: all 186 Swift tests in 26 suites passed (stub transports only),
strict swiftlint and formatting clean; all 48 Python tests passed, with focused Ruff checks
clean. The new tests observe outgoing authentication headers for matching and different hosts.
Independent review reproduced a Python Unicode-dot hostname/parser gap. Python now uses the
SDK's httpx2 URL normalization before host classification and key binding; its U+3002, U+FF0E
and U+FF61 witnesses are rejected over HTTP. Swift checks its Foundation URL before sending.
The review also verified actual pydantic-ai Agent requests with a mock HTTP transport: matching
host gets the vLLM key, different host gets no Authorization, harmless headers survive.
Explicit Python OpenAI/Anthropic origins ignore ambient base-URL overrides, while missing keys
still fail as ConfigurationError. Both closure findings were accepted; sampled coverage does
not establish exhaustive URL-parser equivalence or live-provider acceptance.

Gateway/core work has independent acceptance. App implementation and real pod verification
continue under `docs/SWARM-PLAN.md`.

## Live Swift Hub proof, 2026-10-10

The Sol core agent ran accepted commit `602c60c` against the real Hub with synthetic images in
private dataset `RationallyPrime/conceptstudio-swift-smoke-20261010`. Commit
`a6aef9afa5ed209d11c1027ede2131ba4d6ad8c4` contains two images and their metadata captions/records.
The Hub advertised two LFS verify actions: both uploads returned 200, each verify POST returned
200, and the dataset commit returned 200 only afterward. Both downloaded image byte sequences
and their hashes/sizes matched, and the two source samples and metadata records round-tripped.
Credentials were neither printed nor written to project files. This establishes the core Hub
client path; app UI import/publication and model-provider requests have separate evidence.

## Live Swift model proof, 2026-10-10

The Sol core agent exercised the actual `Endpoints.resolve(vllm)` and OpenAI-compatible client
against the owned pod proxy, with an image and native structured-output schema. The request
returned HTTP 200 from requested/served `Qwen/Qwen2.5-VL-3B-Instruct`, describing the synthetic
blue circle on a white background; reported usage was 61 input and 16 output tokens. The
retained pod token was bound to its user-configured endpoint and never printed. The accepted
core source hashes remained unchanged. This proves one native vLLM image request from Swift;
the full concept-boundary prompt and training behavior are separate pod-stream checks.

A final native request against the owned `q833ws7hsuyrqn` proxy returned HTTP 200 from
requested/served `Qwen/Qwen3-VL-8B-Instruct`, with a decoded JSON caption for one synthetic
blue-circle image. The existing probe used a 128-token maximum; reported usage was
100 input and 17 output tokens. Its exact UTC start/end were
19:54:34.348241–19:55:47.535800, both after the pod owner's trainer exit at
19:53:59.942. This proves final 8B caption functionality and does not establish concurrent
inference during training. No retry or additional training/caption run was made.

## Live native pod-agent read proof, 2026-10-10

At 19:24:17–19:24:18 UTC, the Sol core agent compiled an exact copy of the current app's
`PodAgentClient.swift` with the current ConceptCore source in a temporary SwiftPM package
outside the repository. The copied client and all recorded native source hashes matched
the repository after the live read. Its authenticated, read-only requests to the owned pod
proxy returned HTTP 200 for `POST /plan`, `GET /services`,
`GET /services/trainer-ltx/logs`, and `GET /runs/tiny-flux-proof-20261010/events`.
The plan decoded sequential captioning/training on GPU 0; current service states retained
the completed LTX run ID, and current LTX logs decoded to 200 lines without retaining their
contents. The plan POST computes assignments and does not start or stop services.

The persisted FLUX run returned a real `scraped/loss` scalar at step 2, value
`0.05031000077724457`. The app's actual `latest()` decoder produced the matching
`TrainingPoint`, whose step/loss fields feed the Monitor curve. This proves native decoding
of one actual FLUX point and authenticated control reads; no GUI was launched or rendered,
no resource actions were made, and existing tests remain network-free. The token was read
only inside the probe and was not printed or retained in the receipt.

After the pod-stream owner repaired the LTX image's missing TensorBoard dependency,
a separate native read completed at 19:46:04–19:46:05 UTC against the owned two-GPU
`q833ws7hsuyrqn` agent. Exactly one authenticated
`GET /runs/tiny-ltx-default-proof-20261010/events` returned HTTP 200. The actual
`PodAgentClient.latest()` decoded `TrainingPoint(step: 2, loss: 0.04809999838471413)`,
exactly matching the real `scraped/loss` scalar. The response also contained `scraped/lr`.
Captured native source copies and executable hashes matched after the read, and the
pod owner was promptly notified that no Swift calls remained.

Native loss-point decoding is now demonstrated for both actual FLUX and LTX runs.
These receipts do not establish GUI rendering, a complete training curve or training
quality. Existing tests remain network-free; the native reads made no resource actions.

## Live direct Gemini proof, 2026-10-10

At 19:33:12–19:33:16 UTC, the Sol core agent made exactly one native request through the
actual `Endpoints.resolve(google)` and `GeminiClient`, using one bundled synthetic demo
image (`studio.png`) and the shared `Caption.jsonSchema` in native JSON mode. The
authenticated request returned HTTP 200; requested and served model were both
`gemini-3.8-flash`. The shared `Caption` decoder accepted a nonempty caption with
`usable: true` and `note: null`. Reported usage was 1,117 input and 36 output tokens.

The temporary SwiftPM probe used exact current ConceptCore source, whose copied files
matched the repository after the request. The receipt records source, image, schema,
request and response hashes, the HTTP outcome, decoded caption and usage. The authorized
key was read only inside the process; its value was not printed or retained, stored in
Keychain or written to the repository. Existing tests remain network-free.

This proves one native provider/image/schema/decode path with the current Gemini model.
It does not establish caption quality, the full training prompt, a comparative dataset
experiment or another model's behavior. No additional provider calls, GPU actions or GUI
launches were performed.

## Live native final shutdown proof, 2026-10-10

After the pod owner confirmed all functional outputs were secured, a temporary probe using
the exact current app `RunPodProvider` stopped only `q833ws7hsuyrqn`. Its authenticated
status GET at 19:58:05 UTC returned HTTP 200 and decoded `RUNNING` with two GPUs. The
single native stop POST at 19:58:06 returned HTTP 200 and `EXITED`; a separate fresh
status GET at 19:58:07 returned HTTP 200 and decoded `EXITED`. Captured native source and
executable hashes matched after shutdown. The pod owner received the result immediately.

An offline wrong-ID check rejected execution before credential reading or transport
creation. The live transport allowed only this pod's status reads and one stop action;
no other pod, create, restart or terminate action occurred. This demonstrates the native
provider's final stop/status path without a GUI launch. Existing tests remain network-free.

---

# POD-STATUS

Current verification state as of 2026-10-10 21:26 UTC. Real agent, caption, trainer,
checkpoint/curve/Hub and GPU isolation proofs are recorded below. All three task-created
pods are independently confirmed `EXITED`; no runtime work remains queued. The public
base template and all three public images are verified; actual anonymous pulls succeeded.
The latest billing read returns posted charges for all three stopped pods; the network
volume continues billing. Source,
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
| `ghcr.io/rationallyprime/concept-captioner-pod-aitoolkit` | `sha256:6fcdd6259987203bed61913dd8585eae60a18dc28b184e2545b202fe9c4baf7b` | 14,147,141,514 | public; actual anonymous Docker pull succeeded at 21:24:58Z with exact digest |
| `ghcr.io/rationallyprime/concept-captioner-pod-ltx` | `sha256:1d346fa7b00de3e95168929d838e39d52206af057e8fc35b5cf1aff35794f6ea` | 13,896,513,451 | public; actual anonymous Docker pull succeeded at 21:25:00Z with exact digest |

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
and resets did not recover it. The user subsequently made both trainer packages public,
and the parent independently read GitHub API visibility `public` for each. Fresh anonymous
pulls on cx53 at 21:24:57Z–21:25:00Z verified both exact published trainer digests and
their OCI revisions (`92136b1` ai-toolkit, `de6f152` LTX). The isolated Docker configuration
was empty before and after both pulls; no registry login or GPU/container launch was used.
Trainer public distribution is now verified despite the earlier browser transport failure.

## Live resources and cost state

Task-created durable volume `nydku2wmvd` is 200 GB Standard in EU-RO-1, freshly read back.
Its published rate is $0.07/GB/month ($14/month), including after compute stops. Checkpoints
and datasets remain on that volume; no volume or output has been terminated/deleted.

| pod | hardware actually observed | compute rate | state at this update |
| --- | --- | --- | --- |
| `iqs4zrmjf097hf` | 1 × RTX PRO 4500 Blackwell; 32,623 MiB VRAM, 62 GB RAM, 12 vCPU, CUDA 13.2 | $0.72/hour | `EXITED`; latest independent read 21:26:38Z |
| `q833ws7hsuyrqn` | 2 × RTX PRO 4500 Blackwell; distinct GPU UUIDs, 32,623 MiB each, 125 GB RAM, 56 vCPU, CUDA 13.2 | $1.44/hour | native stop 19:58:06Z, fresh native `EXITED` 19:58:07Z, latest independent read 21:26:38Z |
| `ey4f2374hd3y62` | A100 PCIe 80 GB; 117 GB RAM, 31 vCPU, CA-MTL-3, CUDA 13.2 | $1.79/hour | cancelled experiment; stopped/read back `EXITED` 19:28:52Z, latest independent read 21:26:38Z |

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

At 21:25:58Z exact-resource billing reads for the aligned 17:00–22:00 window returned:

| resource | records returned | posted USD |
| --- | --- | --- |
| one-GPU pod `iqs4zrmjf097hf` | 18:00 and 19:00 buckets | 0.6336929417448118 |
| two-GPU pod `q833ws7hsuyrqn` | 18:00, 19:00 and 20:00 buckets | 0.7390690299216658 |
| cancelled A100 `ey4f2374hd3y62` | 19:00 bucket | 0.05853498727083206 |
| network volume `nydku2wmvd` | 18:00, 19:00 and 20:00 buckets | 0.05833333544433117 |

The returned pod total is **$1.4312969589373097**; including posted network storage, the
task total is **$1.4896302943816409**. All three stopped pods now have returned charges,
closing the earlier missing-record limitation. The network volume continues to accrue
storage charges after this read. The original 20:00:31Z partial receipt, subtotal
$0.5535777229815722, is preserved rather than overwritten.

RunPod assigned $0.052838001400232315 of the pair's GPU charge to its 20:00–21:00 bucket.
The actual native stop and EXITED reads were at 19:58Z, and fresh independent reads at
21:26:38Z still show all three EXITED. These are the provider's returned billing buckets;
no later workload is inferred from their attribution. Rates and elapsed-time projections
remain separate from these recorded amounts. Rate fields on an `EXITED` pod do not
establish active compute billing. No pre-existing account resource was changed.

## Verified on a real pod

The seven demonstrations were executed in the brief's order. The base template was created
early as preparation and reread after trainer and device proofs for stage 6. Stage 1 built
and pushed all images and passed fake compose; stages 2–3 exercised authenticated real
agents and vision captioning; stage 4 produced both trainers' checkpoints, curves and Hub
roundtrips; stage 5 demonstrated sequential release and simultaneous isolated GPU
residency; stage 6 verified the public base template/image/token requirement; stage 7 is
this evidence and cost report. All three images are now public and anonymously pullable;
simultaneous caption computation during training was not established by the delayed native
request.

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
$0.0582859 compute; the later exact billing read returned $0.05853498727083206 for this pod.
Its 100 GB scratch container
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

Local receipts live under `~/Projects/concept-captioner-notes/evidence/2026-10-10/concept-captioner-pod-proof-20261010` (private directory).
Sanitized agent receipts, prepared-request witness, runtime flag probe and downloaded
FLUX/LTX Hub receipts are retained there. Build/push logs and isolated Docker configs are on
cx53 under `/home/hive/work/concept-captioner-pod-verify-20261010`; credentials are never
part of this document. The notes experiment retains the rejected caption drafts.

Principal local receipts:

- `final-stopped-template-receipt.json`: independent final three-pod EXITED states, final
  template read-back and storage scope; `final-task-billing-receipt.json`: exact resource
  billing records from 20:00:31Z, partial subtotal and separately labeled A100 elapsed-rate
  projection; `task-billing-refresh-2125-receipt.json`: later returned charges for all three
  pods plus network storage and fresh 21:26:38Z EXITED reads.
- `flux-hub-receipt.json`, `ltx-hub-receipt.json`, `ltx-default-hub-receipt.json`: downloaded
  checkpoint lengths, hashes and tensor headers; the adjacent directories contain weights.
- `flux-tensorboard-curve.json`, `ltx-default-tensorboard-curve.json`, and
  `ltx-default-stage4-{log,service,events}.json`: successful authenticated curve/run evidence.
- `topology-runtime-samples.json` and `gpu-busy-api-proof.json`: physical two-GPU observations
  and actual different-service reservation rejection.
- `ltx-tensorboard-review-build.log`, `vllm-removed-flags-source-probe.json` and
  `package-base-public.jpg`: causal repair/build, installed-wheel and public-package proof.
- `trainer-public-anonymous-pull-receipt.json`: successful anonymous pulls of both exact
  final trainer tags, matching digests/OCI revisions, empty isolated Docker config and
  corresponding cx53 pull-log paths.

Native receipts are separately at `~/Projects/concept-captioner-notes/evidence/2026-10-10/concept-captioner-swift-agent-flux-read.json`,
`~/Projects/concept-captioner-notes/evidence/2026-10-10/concept-captioner-swift-agent-ltx-read.json`,
`~/Projects/concept-captioner-notes/evidence/2026-10-10/concept-captioner-swift-qwen8-concurrent.json` (explicitly after trainer exit), and
`~/Projects/concept-captioner-notes/evidence/2026-10-10/concept-captioner-swift-native-stop.json`. The final native stop proved actual app
`RunPodProvider` status/stop/status, all HTTP 200, before independent MCP verification.

The public-distribution blocker is closed by both successful anonymous trainer pulls.
The refreshed task-only billing read returns charges for all three stopped pods, with the
earlier partial receipt preserved. Only the retained network volume continues billing.
No paid pod remains active or useful runtime
work queued. Real parquet transfer, FLUX resume and manual crash recovery remain unproven
historical checks. The five-image experiment is cancelled/deferred by the user; no rejected
caption batch was promoted into training data. All tiny trainer runs are functional proof
only and supply no scientific caption-quality comparison.
