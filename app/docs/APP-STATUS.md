# ConceptStudio app status

State after the 2026-10-11 fix round; live checks date from lab commit `e620882`
(2026-10-10). How to run it: [RUNNING.md](RUNNING.md). The day-by-day record is in [status-history-2026-10-10.md](../../docs/process/status-history-2026-10-10.md).
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
  CLI (layout in the [README](../../README.md#project-folder)). A chosen custom skill is copied
  into the project as `skill/<name>/`; app-only state lives in `.conceptstudio/`.
- **Money controls.** Price before renting, running cost, per-run budget cap, idle stop,
  quit/close warnings, Stop everything, keep-awake while a computer runs and a reconcile of
  the app's own pods on launch. Pods use the public trainer images by default.
- **Training result.** A finished LoRA is pushed to a private Hub model repo when a Hub write
  token is set, otherwise downloaded into `<project>/results/<run-id>/`; Stop refuses while a
  result is neither pushed nor saved unless the user chooses to discard it.
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

- **346 Swift tests pass** (108 app/GPU/auth in 17 suites, 238 Core in 34 suites); one opt-in
  render test is skipped in an ordinary run. Strict SwiftLint: zero violations. SwiftFormat:
  clean on 105 files. The bundle
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
- **2026-10-11 fix round, verified offline only:** the ChatGPT route streams through the fixed
  server-sent-event parser (see CORE-STATUS); the custom skill is copied into the project; the
  LoRA push-or-download path, keep-awake and the launch reconcile; the TensorBoard session
  handshake and the run-file download against the pod agent's new endpoints. None of these has
  run against a real pod or account yet.
- **Cost guards and the crash window.** While a computer is running, ConceptStudio keeps the
  Mac from idle sleep and checks the spending limit and idle stop every five seconds. On every
  launch it asks RunPod for the computers it created (named ConceptStudio-<project>) and puts
  any running one back under these guards. Billing is not stopped while the app is not running
  or the Mac is asleep: if the app crashes or is force-quit, or the Mac sleeps anyway (lid
  closed without an external display, low battery, or a manual Sleep), the computer keeps
  billing until the app is opened again. At that point the spending limit is applied
  immediately, using wall-clock time since the computer started, so the overspend equals the
  time away. There is no stop on the RunPod side; RunPod's REST v2 API offers no stop-after or
  terminate-after setting. A computer found on launch whose local record was lost has its
  spending limit counted from the moment it is found.
