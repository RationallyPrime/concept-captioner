# ConceptStudio app: brief

Working name ConceptStudio; Hákon may rename it. Read `docs/v0.2-plan.md` ("Beyond v0.2" in
particular), `app/docs/CORE-STATUS.md` and `pod/docs/POD-STATUS.md` first. The ConceptCore
library in this package is the pipeline; the app drives it and never reimplements it.

The five standing owner decisions are restored verbatim below and also preserved in
[ADR-LOG](../../docs/ADR-LOG.md). Implemented does not mean superseded. The dated records
below identify only explicit owner-approved changes; retain the original text when a decision
changes. Read the [overnight review, owner decisions and fix-round partition](../../docs/process/overnight-review-2026-10-11.md)
before working on the assigned repairs.

## What it is

A native macOS app for people with a MacBook on factory settings and no GPU, that takes them from
a folder of photos to a trained diffusion LoRA on a rented GPU pod, with no terminal involved.
Captions follow the concept-boundary policy (the trigger holds only the concept; everything else
is described) and can be checked by a second model. Training happens on a pod; the Mac only
curates, captions, publishes and watches.

The owner-approved workflow also accepts clips. Training teaches a base model a person,
object, style or activity; the resulting LoRA is a small adapter used with a compatible image
or video model. These Mac roles include preparing approved targets, controlling remote work
and collecting its results; GPU training and inference remain on the rented computer.

The default is **one concept per LoRA**. Captions name it with a trigger and describe the observable
details outside it. This separation is the concept boundary. Captioning guides learning; it does
not guarantee that correlated details in the dataset are disentangled.

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

Preserve the owner's substantive introduction to diffusion models, training data, captions and
concept boundaries. Real terminology has definitions on hover, selection and keyboard focus.
Every screen, menu, sheet, empty state and error explains the actual operation, its inputs and
consequences. Buttons name actions. Do not write marketing copy, slogans or calls to action.
Keep substantive explanations; follow the native design conventions.

## The user journey (one screen each, in this order)

The nine screen names remain unchanged. Mapping is conditional on a concept needing a locator;
style and motion skip that screen under the owner’s 2026-10-11 afternoon decision. The direct
no-Hub upload path is an approved requirement pending Thread 6, not existing release behavior.

1. **Images**: import from a folder, a Hugging Face dataset or Apple Photos; see the set with
   duplicate, low-quality and readable-text warnings; ask for a dataset-level critique before
   spending anything.

   Also import and curate clips, approve crops or exact segments, inspect frames, exclude
   duplicate candidates and Undo curation. Use concrete capture-quality warnings, not a generic
   aesthetics score. Captioning and training use the included approved targets.

2. **Concepts**: choose one category, describe the concept, its trigger and class noun, with
   help and model-drafted assistance from a plain description. Offer a reference when the
   identity, object or character needs one. Multiple concepts and detailed boundary decisions
   belong in Advanced settings; a reference face is not required for every category.

3. **Mapping**: show this step only for concepts that need a locator, including identity,
   object and character. Detected faces and model proposals assist where applicable; the user
   confirms an assignment or types a locator. Progress is visible and unmapped samples are easy
   to find. Style and motion map to the whole target automatically, without a face locator.

4. **Captioning**: pick model, skill, profile and whether a critic runs; start, cancel, and watch
   per-image outcomes arrive live with their notes.

   Keep provider, model, skill, profile/format and optional reviewer controls available.
   Show per-sample partial text while a caption is written as well as its settled outcome;
   this is an app-only progress hook through ConceptCore, not a shared job/CLI field.

5. **Review**: see image and caption together; edit; mark as final so no model run overwrites it;
   re-caption one image; compare two models side by side.

   Inspect the actual approved image or playable segment, protect saved final text,
   re-caption a selection and compare captioning models. Explain any caption reset before
   replacing a target.

6. **Publish**: prepare the included targets, saved captions, response records and job for
   training. With a Hub account, publish to its dataset with progress and a recorded revision.
   Without a Hub token, upload to the pod’s network volume through the authenticated,
   path-confined, size-limited endpoint in the same layout used by dataset pull before training.
   This direct-upload path is required by the owner and is not implemented yet (Thread 6).

7. **GPU pods**: provider key status, GPU type with price, 1/2/4 GPUs, create, running cost,
   stop, terminate with confirmation.

   Show hardware, price, running spend, saved-storage cost separately, budget and idle controls,
   and the app’s running computers. Keep Stop everything accessible.

8. **Training**: choose trainer and run settings with sane defaults; read the plan in plain words
   (one GPU: caption then train; several: captioning on GPU 0, training on the rest); start; see
   status and logs.

   Preserve settings and dataset revision in saved runs. Repeat with changes creates a new run;
   Resume requires the selected trainer’s actual checkpoint/state support. The pod agent owns
   GPU allocation; the app does not implement the training pipeline.

9. **Monitor**: training curves in-app, TensorBoard from the pod in a tab.

   Collect the LoRA, select a checkpoint, generate matched base-versus-trained comparisons,
   inspect saved galleries and offer Save trained model to this Mac. Use real output files;
   simulated services do not establish training or generation success.

Plus a Welcome window (recent projects, new, open, try the demo) and Settings (keys, test
connection, demo mode).

Experts navigate directly without replaying the introduction.

### Dated supersessions of the original screen wording

The following clauses from `36617c8` are retained verbatim as the 2026-10-11 record, not
instructions to restore superseded defaults. The owner-approved overnight flow keeps one
concept in the ordinary interface and multiple concepts in Advanced; categories use references
only when appropriate. The [afternoon decisions](../../docs/process/overnight-review-2026-10-11.md#owner-decisions-on-the-items-above-2026-10-11-afternoon)
replace person-only Mapping with locator-only Mapping and automatic whole-target style/motion.
The [final fix-round decision](../../docs/process/overnight-review-2026-10-11.md#fix-round-decisions-decided-2026-10-11-afternoon)
adds training without a Hub account. The current rules above govern those changes.

Original Concepts clause:

```text
2. **Concepts**: define each trigger, its class noun, one reference face, and the boundary
   decisions, with help text and an option to have a model draft them from a plain description.
```

Original Mapping clause:

```text
3. **Mapping**: for each image, which trigger is who. Detected faces and a model's proposal
   pre-fill the answer; the user confirms with one click or types a locator. Progress is visible;
   unmapped images are easy to find.
```

Original Publish clause:

```text
6. **Publish**: push the project to a Hub dataset, with progress.
```

## Required features and implementation notes

The five tagged paragraphs retain their exact original wording. Notes describe the current
partial or implemented state without retiring any requirement; the ADR log holds the longer
implementation snapshots. These notes are the 2026-10-11 snapshot at `ce52a22`, before the
assigned fix-round repairs.

- **Project on disk in the same layout the CLI uses** (images, job file, caption sidecars with
  response records), so the app and the CLI interoperate and nothing is proprietary. A custom
  skill the user picks is copied into the project (`skill/<name>/`, written as `skill: ./skill/<name>`); the
  job never points outside the project. *(Owner decision, 2026-10-11.)*

Implementation: **Implemented for project storage and copied skills; partial CLI interoperability.** Relative skill/profile resolution and mixed image/clip Hub intake remain assigned repairs. See [ADR-0001](../../docs/ADR-LOG.md#adr-0001--project-files-and-custom-skills).

- **Keys in the Keychain**, entered once in Settings. For key-based access, lead with "one gateway key" (OpenRouter,
  Vercel AI Gateway, Pydantic AI Gateway) and put direct provider keys under Advanced. The app
  sells nothing; users bring accounts they already hold.
- **Log in with ChatGPT** as an alternative to a key: eligible users can caption with OpenAI
  models on their ChatGPT plan. Captions stream, so progress shows while each one is written.
  Show the active account, available models, plan usage and its management link. Keep
  credentials in Keychain; never silently switch to separately billed API credits.
  *(Owner decision, 2026-10-11.)*

Implementation: **Sign-in, model selection, Keychain storage and separate billing routes are implemented.** Visible partial caption text is assigned to Thread 3; in-app plan usage/remaining allowance is still missing. See [ADR-0002](../../docs/ADR-LOG.md#adr-0002--chatgpt-plan-access-and-streaming).

- **Demo mode**: a bundled sample project and fake model, provider and pod backends that walk the
  entire journey, every status included, with a visible Demo badge and no network use. This is
  for first runs, screenshots and App Review.
- **Money safety**: price before creating a pod, running cost while it is up, a per-run budget cap
  that stops the pod, an idle watchdog, a warning on quit while a pod runs, and an always-visible
  stop-everything action. Keep the Mac awake while a pod runs; on launch, find pods this app
  created that are still running and show them. *(Owner decision, 2026-10-11.)*

Implementation: **Tracked-rental controls are implemented; the full decision is partial.** The current cap is per rental, not per training run; launch discovery depends on saved active-pod metadata. Guards run on the Mac, and separately billed storage is outside the GPU estimate. See [ADR-0003](../../docs/ADR-LOG.md#adr-0003--money-safety-and-running-computers).

- **The trained LoRA reaches the user**: by default, if the user is signed in somewhere the
  LoRA can be pushed to, push it to a private repo there when training finishes; otherwise
  save the `.safetensors` file into the project. Many users have no GitHub or Hugging Face
  account, so saving to disk is a first-class outcome, not an error. Today the push target is a
  Hugging Face model repo, used when a Hub write token is configured. No stop discards a result
  that has been neither pushed nor saved. *(Owner decision, 2026-10-11.)*

Implementation: **Private Hub delivery, local collection and pending-result preservation are implemented, with admission gaps.** Hub write permission is not checked before choosing push, and an existing public destination is not made private. Training-data upload without a Hub account is approved but remains assigned to Thread 6. See [ADR-0004](../../docs/ADR-LOG.md#adr-0004--delivery-of-the-trained-lora).

- **GPU provider abstraction** with RunPod first; the app creates pods from the project's own
  images and talks to the pod only through the control agent's HTTP API.
- **Sandbox-compatible from day one** so the Mac App Store stays an option: user-selected
  folders only, no subprocesses, outbound networking plus a temporary `127.0.0.1` callback
  listener for ChatGPT sign-in. Close the listener on completion, cancellation or timeout.
  *(Owner decision, 2026-10-11.)*

Implementation: **The architecture and callback cleanup are implemented in source; signed sandbox execution is unverified.** The preview is unsigned, and signing/notarization remain deferred at the owner’s request. See [ADR-0005](../../docs/ADR-LOG.md#adr-0005--sandbox-compatibility-and-callback-lifetime).

- **Cancel everything long-running**, and nothing left running when a project closes without
  the user knowing.
- Not in v1, leave room for: Google Photos (via the Picker), Google Drive, Gemini batch.

## Owner-approved overnight additions and current requirements

These additions remain alongside the restored decisions; implementation status is recorded in
[APP-STATUS](APP-STATUS.md), [CORE-STATUS](CORE-STATUS.md) and [POD-STATUS](../../pod/docs/POD-STATUS.md).
Assigned repairs are requirements, not claims of completed behavior.

- OpenRouter uses documented browser OAuth/PKCE, then direct API calls. Show available usage;
  cancellation closes callback listeners. Never reuse another application's credentials.
- The explicitly synthetic demo uses prepared captions/advice and simulated services, with no
  network or charges. Never imply live evaluation or ask for real photos in the prepared lesson.
  The owner-approved badge reads **Demo · no charges**; that label update is assigned to Thread 5.
- Categories guide questions, mapping help and caption/reviewer prompts.
  Keep “learn these traits” and “describe these details” lists out of the ordinary flow.
  A sample is unusable when its declared training target cannot be found; person-only schema
  wording must not contradict style, object or motion jobs. The shared-schema/mapping repair
  is assigned to Thread 4.
- Curation groups duplicate candidates and supports Keep/Exclude with Undo, reliable HEIC/TIFF
  intake, approved crop previews, clip trimming and frame inspection. Captions, publication and
  training use the exact included crop or segment. No generic aesthetics score.
- Distinguish real video training data from still-image training of a video model. Caption
  observed motion; inspect audio before describing it. Explain unsupported combinations;
  never substitute poster frames for clips.
- Preserve run settings, dataset revision, outputs and available cost information across
  reopening. Repeat with changes starts a new run; Resume requires actual trainer support.
- Provide actual generation, saved galleries and base/LoRA comparisons with matched prompts
  and seeds, checkpoint choice and Save trained model to this Mac. Preserve private publication
  and local retrieval; never discard an unsaved result.
- Training without a Hub account is a required input path: the app uploads approved images or
  clips, captions and the job to the network volume through the authenticated agent. Keep the
  same dataset layout and path/size limits; do not require a Hub account or silently upload
  elsewhere. Thread 6 implements this after Thread 2.

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

Every UI surface must be reviewed. Distinguish offline, live and pending human checks; a demo,
a build or an output file alone does not establish the full real-data journey. Document
signing/notarization and its unverified distribution state. Re-staging and the caption-policy
experiment remain deferred until the owner starts them.
