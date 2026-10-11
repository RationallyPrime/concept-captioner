# ConceptStudio app status

State at lab commit `e620882` (2026-10-10). How to run it: [RUNNING.md](RUNNING.md). The
day-by-day record is in [status-history-2026-10-10.md](../../docs/process/status-history-2026-10-10.md).
The library underneath is in [CORE-STATUS.md](CORE-STATUS.md); the pod side in
[POD-STATUS.md](../../pod/docs/POD-STATUS.md).

## What exists

An unsigned macOS 15 Swift 6 / SwiftUI app, built by script into `app/dist/ConceptStudio.app`.
Yams is its only third-party dependency.

- **Welcome and Settings.** New, open and recent projects; an offline demo; keys in the
  Keychain, gateway-first, with direct provider keys under Advanced; a captioning connection
  test; **Log in with ChatGPT** (PKCE, signed identity, Keychain credentials, model discovery,
  explicit choice between ChatGPT plan usage and OpenAI API credits, never switched silently).
- **The nine-screen journey.** Images (folder, selected files, Apple Photos, Hub imagefolder;
  duplicate, face-quality and readable-text warnings), Concepts, Mapping, Captioning (live
  per-image outcomes, optional critic, cancel), Review (drafts kept across navigation, mark
  final, re-caption one, compare two models), Publish (one Hub commit), GPU pods, Training,
  Monitor (in-app curves, authenticated TensorBoard).
- **Shared formats.** Projects use the same job file, sidecars and response records as the
  CLI (layout in the [README](../../README.md#project-folder)).
- **Money controls.** Price before renting, running cost, per-run budget cap, idle stop,
  quit/close warnings, Stop everything. Pods use the public trainer images by default.
- **Demo mode.** Every screen and status with fake model, provider and pod backends; no
  Keychain reads and no network.

## Verified live

Through code paths the app uses, run as headless probes against real services (not through
the app window):

- Swift Hub upload, LFS verify and download; native RunPod catalog and network-volume reads.
- One Gemini structured caption request; vLLM image captions from the owned pod (Qwen 2.5 VL 3B
  and Qwen3 VL 8B).
- `PodAgentClient` reads of plan, services, logs and training events; the loss point decoded
  from both a real FLUX run and a real LTX run.
- `RunPodProvider` status, stop and status against a real two-GPU pod.

In the window itself: Welcome, demo Images and Concepts were reached, and Hákon confirmed the
app responds normally.

## Verified offline only

- **276 Swift tests pass** (59 app/GPU/auth, 217 Core); one opt-in render test is skipped in an
  ordinary run. Strict SwiftLint: zero violations. SwiftFormat: clean on 94 files. The bundle
  builds with an arm64 executable and valid Info and entitlement plists.
- ChatGPT sign-in and captioning: PKCE and callback state, identity claims, separate accounts,
  token refresh, sign-out ordering, streamed completion, usage-limit cancellation. Independent
  review accepted the code after rerunning 22 auth and 12 Core tests.
- Layout: offscreen renders of all screens at two window sizes in light and dark. These do not
  show focus, scrolling, input, VoiceOver or native sidebar vibrancy.

## Open

- **Full interactive walkthrough** of all nine screens in the window, including keyboard, menus,
  dialogs and VoiceOver. Agent GUI control failed (`cgWindowNotFound`, closed transport pipe).
- **ChatGPT with a real account:** browser consent, Keychain persistence in the signed app and
  one plan-billed caption are unverified. They need a user to authorize the app's registration.
- **Real app-driven rental:** create pod, caption, train, publish, stop, all from the window.
- **Live OpenAI, Anthropic and gateway requests** (see CORE-STATUS).
- **Signing, notarization and sandbox runtime checks:** documented in RUNNING.md, not done.
- **Decided 2026-10-11, being implemented:** captions stream from the ChatGPT route with a
  fixed stream parser; a chosen custom skill is copied into the project; a finished LoRA is
  pushed to a private Hub model repo when a Hub write token is configured, otherwise downloaded
  into the project, and is never stopped away before one of the two; the Mac is kept awake
  while a pod runs, and on launch the app finds pods it created that are still running. After
  that, if the app crashes or the Mac loses power, a running pod keeps billing until the app is
  opened again; the pod has no self-stop.
