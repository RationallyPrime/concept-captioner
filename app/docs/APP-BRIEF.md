# ConceptStudio app: brief

Working name ConceptStudio; Hákon may rename it.

The five standing owner decisions are preserved verbatim in [ADR-LOG](../../docs/ADR-LOG.md).
They remain required when implemented; this brief summarizes them and does not supersede them.

## What it is

A native Mac app that takes images or clips to a diffusion LoRA trained on a rented GPU, without
a terminal. Training teaches a base model a person, object, style or activity; the resulting LoRA
is a small adapter used with a compatible image or video model.

The default is **one concept per LoRA**. Captions name it with a trigger and describe the observable
details outside it. This separation is the concept boundary. Captioning guides learning; it does
not guarantee that correlated details in the dataset are disentangled.

## Who it is for

Someone with no programming or ML knowledge, an ordinary MacBook, training examples and an
intended result. They should need no outside research to operate the app. Hákon should prefer it to transformers in a terminal: remembered choices, direct controls and
inspectable projects matter as much as first-run guidance.

Preserve the owner's substantive introduction to diffusion models, training data, captions and
concept boundaries. Real terminology has definitions on hover, selection and keyboard focus.
Every screen, menu, sheet, empty state and error explains the actual operation, its inputs and
consequences. Buttons name actions. Do not write marketing copy, slogans or calls to action.
Keep substantive explanations; follow the native design conventions.

## The nine-screen journey

1. **Images**: explain the process; import, preview and curate images or clips, approve crops or segments, exclude duplicates and request dataset advice.
2. **Concepts**: choose one category, describe the concept and set its trigger; multiple concepts and detailed boundary overrides belong in Advanced settings.
3. **Mapping**: identify the person, object, character or motion in each sample; a single whole-image style applies without face mapping.
4. **Captioning**: select the captioning provider, model, instructions, format and optional reviewer; start, cancel and inspect per-sample outcomes.
5. **Review**: inspect the actual training target beside its caption, edit and protect final text, re-caption selections or compare captioning models.
6. **Publish**: upload the included targets and saved captions to the user's Hub dataset, with progress and a recorded revision.
7. **GPU pods**: inspect provider status, hardware and price; rent, see running cost, stop or explicitly terminate a computer.
8. **Training**: choose a supported trainer and settings, inspect the GPU allocation and cost, start or repeat a saved run, or resume a supported checkpoint.
9. **Monitor**: inspect curves, logs and TensorBoard; retrieve the LoRA, select a checkpoint and generate matched base-versus-trained comparisons.

Welcome offers projects and the demo; Settings manages connections. Experts navigate directly
without replaying the introduction.

## Required features

- Share an inspectable project contract with the CLI. Custom captioning instructions travel
  with projects; credentials stay in Keychain.
- Support gateways, direct-provider keys under Advanced, and eligible ChatGPT-plan access.
  OpenRouter uses documented browser OAuth/PKCE, then direct API calls. Show available usage;
  cancellation closes callback listeners. Never reuse another application's credentials.
- Use an explicitly synthetic demo with prepared captions/advice and simulated services.
  No network or charges. Never imply live evaluation or ask for real photos in the prepared lesson.
- Categories guide questions, mapping help and caption/reviewer prompts.
  Keep “learn these traits” and “describe these details” lists out of the ordinary flow.
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
- Show price before rental, running cost, a budget cap, idle stop, quit choices and Stop everything.
  Keep the Mac awake during rented work and reconcile this app's running pods on launch.

## Constraints and done

Swift 6, macOS 15, SwiftPM, Yams only, Swift Testing; no network in tests. Remain sandbox-compatible:
user-selected folders, no app subprocesses, outbound networking and temporary loopback sign-in.
RunPod is the first GPU provider; the app uses the pod agent's HTTP API.

Done means checks pass, the double-clickable app builds, every UI surface has been reviewed,
and beginners can complete the demo while repeat users retain direct control.
Distinguish offline, live and pending human checks. Document signing/notarization. Re-staging
and the caption-policy experiment remain deferred until the owner starts them.
