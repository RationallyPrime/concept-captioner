# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

Recorded as `ios` because Impeccable's list names the design language the app renders (Apple's),
and has no macOS value. The app is a native **macOS** app in Swift and SwiftUI (macOS 15 or later,
Apple Silicon in development): apply Apple's semantic colour, labelling and native-control
principles, but Mac window, sidebar, pointer, keyboard and menu conventions, never phone
navigation or touch sizing. There is no Windows version; Linux users get the command-line tool.

## Users

- **Primary: a person with a MacBook on factory settings and no machine-learning or programming
  background.** They bring a folder of photos or clips and an intended result (a person, a pet, an
  object, a style or a movement a model should learn). Their job is to get a trained LoRA without a
  terminal, a graphics card or outside research, and without losing money to a computer they
  forgot to stop.
- **Secondary: the owner and other experienced users on repeat runs.** They know the model families
  and training settings and want direct controls, remembered choices and no repeated introductions.
  The app must stay useful enough that the owner prefers it to running trainers in a terminal.

## Product Purpose

ConceptStudio turns a folder of photos or clips into a trained diffusion LoRA, a small adapter that
teaches an image or video model one new concept. The Mac prepares the training data: it curates and
crops examples, names the concept with a trigger word, has a language model of the user's choice
caption every example, and lets the user review captions beside the media. A GPU computer the app
rents and controls does the training, within a budget and an idle limit set before renting, and
the trained adapter comes back to the user. Success: a beginner finishes a first run and gets an
adapter that has learned the concept, and knew what it cost before paying.

## Positioning

- **The concept boundary.** Captions name the concept with its trigger and describe everything
  outside it (clothing, setting, light, pose). That separation tells training what belongs to the
  concept and what does not. The caption instructions are a swappable Agent Skill, with one profile
  per caption style, shaped to the model being trained.
- **The whole job in one native app.** Curation, mapping, captioning, review, publishing, renting,
  training, monitoring and comparison run from one Mac app, with no terminal and no GPU of its own.
- **Any captioning model.** A ChatGPT plan, OpenRouter, a provider or gateway key, or the user's own
  vLLM server, chosen at run time.
- **Money handled in the design.** The price is shown before renting, spending is capped per run and
  per computer, an idle computer is stopped, and a computer holding an unsaved result cannot be
  removed.
- **Its own GPU images.** Every rented computer runs the project's own container images with a
  control agent that starts services from a fixed catalogue over one authenticated API. One model
  table, read by the app and the images, defines every supported model.

## Operating Context

- The user works alone at a MacBook, often across several sessions: preparing data one evening,
  renting and training another, checking results later. Training runs take tens of minutes to
  hours on a computer billed by the hour.
- Projects are ordinary folders the user chooses (media, captions, a job file, run records).
  Datasets and adapters move through Hugging Face when the user has an account, or directly
  otherwise.
- External services: RunPod (rented GPUs), Hugging Face (datasets, adapters, model downloads, gated
  licences), the captioning provider, and optionally Apple Photos for import.
- An offline demo with practice photos and simulated training runs without any account or charge.
- The nine screens, in order and grouped into three phases: Prepare training data (Images,
  Concepts, Mapping), Write captions (Captioning, Review, Publish), Train your model (GPU pods,
  Training, Monitor). Mapping appears only for concepts that need a locator. Settings and a Help
  window with a glossary sit outside the journey.

## Capabilities and Constraints

- **Import and curate.** Import images and clips from a folder, a Hugging Face dataset or Apple
  Photos. The app warns about duplicates, quality and readable text. Users approve crops and exact
  video segments, and curation can be undone.
- **Concepts.** One concept per LoRA by default: category, description, trigger, class noun, and
  model-drafted assistance. Identity, object and character concepts need a locator. The user
  confirms detected faces or model proposals, or types a locator. Style and motion concepts apply
  to the whole image.
- **Captioning and review.**
  - Captioning is per-image and arrives live, with an optional second-model review that can send a
    caption back once with notes.
  - The only mechanical check is that every trigger appears exactly.
  - Captions marked final are protected from later model runs.
- **Training.**
  - The app shows the hourly price and separately billed storage, and sets a run budget, a whole
    computer budget and an idle limit.
  - Training starts from each model's tested recipe. More than twenty further architectures are
    available only behind an Advanced user switch, labelled as unverified recipes.
  - Monitor shows the learning curve and log, retrieves the adapter, and compares base and trained
    models on the same prompts and seeds.
- **Native and private.**
  - The app is sandboxed, keeps credentials in the Keychain and starts no subprocesses.
  - It has full keyboard operation: ⌘1–⌘9 for screens, ⌘[ ⌘] for back and next, ⌘↩ for each
    screen's main action.
  - Window sizes: 980 × 680 minimum, 1240 × 820 default.
- **Owner decisions in force.** These are recorded in `app/docs/APP-BRIEF.md` and `docs/ADR-LOG.md`;
  the design must not reopen them:
  - the nine screen names and their order;
  - confirmations as window alerts with the safe choice as default;
  - quitting with a running computer offers "keep running", with the price;
  - one failure path through the window alert.
- **Open product facts.**
  - The name is a working name and may change.
  - Distribution is open source today, with a commercial version possible later.
  - There is no public download yet.

## Brand Commitments

- Working name ConceptStudio. The design language must not depend on the wordmark.
- No binding logo or icon. The two drafts in the repository root (`ConceptStudio Cat Annotation
  Icon.png`, `ConceptStudio-Icon.png`) are explorations only.
- The owner wants a design language of the app's own, created with him through Impeccable's full
  direction workflow with image mockups. The owner's portfolio (hakonfreyr.com, an engineering
  drawing set) is his quality bar for coherence, one idea expressed through every detail. It is
  not a style to copy.
- **Voice.**
  - Plain, exact operating copy.
  - Every screen explains itself in a sentence and names the consequence of each action,
    including what it costs.
  - Real terms are defined where they are used.
  - No marketing copy, slogans or calls to action inside the app.
  - Sentence case.

## Evidence on Hand

- **Offline demo.** Synthetic practice photos (`app/Sources/ConceptStudio/Resources/Demo/images/`)
  with the trigger NORA7, and simulated GPU services.
- **Offscreen renders.** Renders of every screen and state, light and dark, at both window sizes,
  come from `scripts/render-app-preview.sh`. The sidebar column does not render faithfully offscreen.
- **First run through a signed, notarised build (14 October 2026).**
  - The app published the dataset and rented one RTX PRO 6000.
  - It drew 40 regularisation images.
  - It trained Qwen-Image-2.1 for 10,004 steps in 1 h 19 min, for US$3.99 of GPU against a US$10
    run budget.
  - The adapter was pushed to Hugging Face and the idle computer stopped by itself.
- **Likeness adapter on the project's GPU images (15 October 2026).** On Qwen-Image-2.1, face match
  to held-out photos went from 0.05 to 0.34 after 2,500 steps.
- **Glossary.** 177 entries, each in a plain and a technical reading.
- **Critique of the incumbent interface (2026-10-15).** It scored 25/40 and is saved in
  `.impeccable/critique/`.
- **Must not be fabricated.** There are no users, testimonials, download counts, prices for a
  commercial version, or reviews.

## Product Principles

1. **Money before spending.** The user sees the cost of a step, and how it stops, before committing
   to it.
2. **The concept boundary is the product.** The interface makes visible what the trigger holds and
   what the caption describes, because that separation is what the user is actually authoring.
3. **One obvious next action.** Every screen has one primary action in view and explains itself in
   a sentence. Depth is available, never in the way.
4. **The user's media leads.** Photos, clips and their captions carry the interest. The interface
   frames them rather than competing with them.
5. **Beginner first, expert fast.** Guidance and defaults on the first run; remembered choices,
   shortcuts and direct controls on every run after.

## Accessibility & Inclusion

- WCAG 2.2 AA contrast for text, plus 3:1 for controls and boundaries in both appearances.
- Full keyboard operation and VoiceOver labels on every control.
- Status is never carried by colour alone.
- Users include non-native English speakers.
