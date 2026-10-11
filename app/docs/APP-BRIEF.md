# ConceptStudio app: brief

Working name ConceptStudio; Hákon may rename it. Read `docs/v0.2-plan.md` ("Beyond v0.2" in
particular), `app/docs/CORE-STATUS.md` and `pod/docs/POD-STATUS.md` first. The ConceptCore
library in this package is the pipeline; the app drives it and never reimplements it.

## What it is

A native macOS app for people with a MacBook on factory settings and no GPU, that takes them from
a folder of photos to a trained diffusion LoRA on a rented GPU pod, with no terminal involved.
Captions follow the concept-boundary policy (the trigger holds only the concept; everything else
is described) and can be checked by a second model. Training happens on a pod; the Mac only
curates, captions, publishes and watches.

## Who it is for

Someone with no programming or ML knowledge, using an ordinary MacBook. They bring photos and
an intended result; no development environment or knowledge of model families is assumed.

Throughout the project's lifetime, that person must be able to finish, and Hákon must find the
same app useful enough to prefer it to running transformers in a terminal for convenience.
Use guidance and sensible defaults for first runs; direct controls and remembered choices for
efficient repeat runs. Keep model, skill, profile and training controls available without
requiring beginners to configure everything or experts to repeat introductory guidance.

Lead with intent: what should be learned, what should stay changeable, and what it costs.
Explain necessary terms in place; require no outside research. Every screen explains itself
in a sentence, has one obvious next action, gives actionable errors without stack traces, and
shows money before spending it. Preserve meaningful control and inspectable project data.
Use the native interface conventions in [DESIGN.md](../DESIGN.md) when implementing these rules.

## The user journey (one screen each, in this order)

1. **Images**: import from a folder, a Hugging Face dataset or Apple Photos; see the set with
   duplicate, low-quality and readable-text warnings; ask for a dataset-level critique before
   spending anything.
2. **Concepts**: define each trigger, its class noun, one reference face, and the boundary
   decisions, with help text and an option to have a model draft them from a plain description.
3. **Mapping**: for each image, which trigger is who. Detected faces and a model's proposal
   pre-fill the answer; the user confirms with one click or types a locator. Progress is visible;
   unmapped images are easy to find.
4. **Captioning**: pick model, skill, profile and whether a critic runs; start, cancel, and watch
   per-image outcomes arrive live with their notes.
5. **Review**: see image and caption together; edit; mark as final so no model run overwrites it;
   re-caption one image; compare two models side by side.
6. **Publish**: push the project to a Hub dataset, with progress.
7. **GPU pods**: provider key status, GPU type with price, 1/2/4 GPUs, create, running cost,
   stop, terminate with confirmation.
8. **Training**: choose trainer and run settings with sane defaults; read the plan in plain words
   (one GPU: caption then train; several: captioning on GPU 0, training on the rest); start; see
   status and logs.
9. **Monitor**: training curves in-app, TensorBoard from the pod in a tab.

Plus a Welcome window (recent projects, new, open, try the demo) and Settings (keys, test
connection, demo mode).

## Required features

- **Project on disk in the same layout the CLI uses** (images, job file, caption sidecars with
  response records), so the app and the CLI interoperate and nothing is proprietary. A custom
  skill the user picks is copied into the project (`skill/<name>/`, written as `skill: ./skill/<name>`); the
  job never points outside the project. *(Owner decision, 2026-10-11.)*
- **Keys in the Keychain**, entered once in Settings. For key-based access, lead with "one gateway key" (OpenRouter,
  Vercel AI Gateway, Pydantic AI Gateway) and put direct provider keys under Advanced. The app
  sells nothing; users bring accounts they already hold.
- **Log in with ChatGPT** as an alternative to a key: eligible users can caption with OpenAI
  models on their ChatGPT plan. Captions stream, so progress shows while each one is written.
  Show the active account, available models, plan usage and its management link. Keep
  credentials in Keychain; never silently switch to separately billed API credits.
  *(Owner decision, 2026-10-11.)*
- **Demo mode**: a bundled sample project and fake model, provider and pod backends that walk the
  entire journey, every status included, with a visible Demo badge and no network use. This is
  for first runs, screenshots and App Review.
- **Money safety**: price before creating a pod, running cost while it is up, a per-run budget cap
  that stops the pod, an idle watchdog, a warning on quit while a pod runs, and an always-visible
  stop-everything action. Keep the Mac awake while a pod runs; on launch, find pods this app
  created that are still running and show them. *(Owner decision, 2026-10-11.)*
- **The trained LoRA reaches the user**: by default, if the user is signed in somewhere the
  LoRA can be pushed to, push it to a private repo there when training finishes; otherwise
  save the `.safetensors` file into the project. Many users have no GitHub or Hugging Face
  account, so saving to disk is a first-class outcome, not an error. Today the push target is a
  Hugging Face model repo, used when a Hub write token is configured. No stop discards a result
  that has been neither pushed nor saved. *(Owner decision, 2026-10-11.)*
- **GPU provider abstraction** with RunPod first; the app creates pods from the project's own
  images and talks to the pod only through the control agent's HTTP API.
- **Sandbox-compatible from day one** so the Mac App Store stays an option: user-selected
  folders only, no subprocesses, outbound networking plus a temporary `127.0.0.1` callback
  listener for ChatGPT sign-in. Close the listener on completion, cancellation or timeout.
  *(Owner decision, 2026-10-11.)*
- **Cancel everything long-running**, and nothing left running when a project closes without
  the user knowing.
- Not in v1, leave room for: Google Photos (via the Picker), Google Drive, Gemini batch.

## Constraints

Swift 6 language mode, macOS 15 minimum, SwiftPM only (Xcode opens the package), Yams is the only
third-party dependency, Swift Testing, no network in tests. Lint and format clean. Verify through
tests, builds and GUI walkthroughs. A script must produce a
double-clickable `.app`; signing and notarization are documented, not done.

## Done means

Build, tests and lint green; the `.app` bundle builds; a user with no programming or ML knowledge
can complete the whole journey in demo mode without outside research or a dead end; repeat
users can reuse choices and reach the required controls without replaying introductory guidance;
`app/docs/APP-STATUS.md` says what is really verified,
what is fake-verified, what signing needs, and how to do a first run.
