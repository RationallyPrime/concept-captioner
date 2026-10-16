# ConceptStudio interface

The audience, required features and nine-screen order are defined in [APP-BRIEF.md](docs/APP-BRIEF.md).
This document records the native interface direction applied with
[Impeccable](https://github.com/pbakaus/impeccable), using its Operate, polish and native audit
principles. It does not replace the product brief. The owner delegated this refinement on
2026-10-10; visual preferences remain open to the human walkthrough.

## Direction

A calm workspace for preparing images and video clips for diffusion training. The photographs and their
captions carry the visual interest. Give a beginner enough context to act; keep routine
controls quick for a returning user. The interface should feel at home on a Mac.

The owner supplied a portfolio site as a quality reference: its drawing
sheet composition, rules, annotations and illustrations express one coherent idea. Apply that
discipline here through a photo workspace: a contact sheet, one clearly defined concept and
an image paired with its editable caption. Every visual detail should help the current decision.

- Keep the native sidebar, lists, split views, pickers, menus, sheets, keyboard focus and
  selection behavior. Retain the nine screen names and their order. Group their navigation
  into preparing training data, writing captions and training a model; step numbers describe order,
  never imply that work has been completed.
- Use the system font and SF Symbols. Page titles, section titles, field labels and supporting
  text have distinct, consistent roles. Reserve monospaced text for logs and monospaced
  numerals for prices and counts. Use sentence case.
- Colour follows the Instant Print language below (it replaced the adaptive teal tint in 2026-10).
  Pair every status with words or an icon; colour alone never identifies a warning, a final
  caption or a selected item.
- Group related controls tightly and leave more room between sections. Prefer headings and
  dividers over a stack of decorative cards. Use a contained surface for an image, a meaningful
  example or a notice, not around every paragraph.
- Keep one visually prominent task action per area. Journey navigation remains available but
  should not compete with Import, Confirm, Start or Save. Keep costs, cancellation and Stop
  everything findable while work runs. Explain separately billed storage beside the price.
- Introduce unfamiliar terms where they are used. Show intent and practical consequences
  first; keep model identifiers, skills, profiles and low-level training controls available
  through clearly named disclosures. Never silently substitute a model or remove a control.
- Empty states explain how to get started. Working, error and stopped states explain what
  happened and what can happen next. Protect caption work during navigation. Respect native
  keyboard and VoiceOver behavior; editor fields and row controls need real labels.
- Layout must work at the supported 980 × 680 minimum and 1240 × 820 default window sizes,
  and expand naturally. Allow scrolling and wrapping; long filenames, notes and user text
  must not force the window wider. Avoid decorative animation.

## Instant Print (owner's choice, 2026-10-15)

The owner chose the Instant Print direction and approved its Review comp
(`.impeccable/mocks/review-approved.png`). The user's photos are prints on a table; the app is the
film back around them. Tokens live in `InstantPrint.swift`.

- **Frame.** A film-back charcoal sidebar, title strip and footer surround a light grey work surface
  (dark grey in dark appearance). The title strip names the screen in one sentence and opens its
  Definitions. The footer carries the project name, the screen's progress ("19 of 24 final",
  "24 of 24 confirmed"), GPU spend and Stop everything while a computer runs, and Next.
- **Prints.** Wherever a photo stands for a sample (Images, Mapping, Captioning, Review, Publish,
  generated results) it is a print: warm white paper, the photo cropped from the top so faces stay
  in frame, and the sample's name, caption or state written in the deep bottom margin. Prints stay
  white in both appearances. Excluded samples are struck through; never tinted.
- **One accent.** Developing orange marks the selected print, the face box and the one primary
  action of an area (filled buttons and Next). Links, symbols and controls are ink.
- **State labels** are neutral grey chips. Only "Needs attention" (curation warnings, failed or
  rejected captions) is coloured, in pink with the reason written beside it.
- **The trigger** is set in Ubuntu Sans Bold (bundled, Ubuntu Font Licence) where it is a title,
  and marked in peach inside caption text. Everything else uses the system font.
- **What each screen leads with.** Images: the contact sheet with warnings stamped on prints.
  Concepts: the concept as a print with its trigger, beside what the trigger holds and what
  captions describe. Mapping: a strip of small prints and the open print with its face box.
  Captioning: the contact sheet filling with captions, settings in a column beside it. Review: the
  open print and the sheet. Publish: the included prints stacked beside three counts. GPU pods: the
  price, spending limit and idle stop set large. Training: the plan as a receipt. Monitor: the
  learning curve in ink, and base and trained outputs as print pairs.
- **Sections stay flat** under the owner's layout grammar below; paper is for prints and for the
  training plan, which is a receipt. Notices sit on a light grey slip.
- **App icon.** A developing print on the charcoal tile, with the orange trigger mark in its margin.
  It is drawn by `scripts/draw-app-icon.swift`; `Packaging/ConceptStudio.icns` is made from it.

## Interface rules (fix round 2026-10-11)

These apply the direction above. The two marked owner decisions are not open to a session.

- **One layout grammar** (owner decision, keep-unify-flat). Every screen, including GPU pods,
  Training, Monitor and Settings, uses the custom header and footer with flat `StudioSection`
  headings and dividers. Field groups use a columns form inside a section, never grouped cards.
- **One failure path.** A blocking failure raises the window alert. Progress, success and
  recoverable states stay inline beside the action they describe.
- **Confirmations are window alerts.** Discarding caption edits, closing, quitting, stopping with
  an uncollected trained model and raising a spending limit are SwiftUI alerts driven by the
  session's pending prompt; nothing blocks the whole app modally. The default button is the safe
  choice: Return keeps the edits ("Keep editing") and keeps the current limit ("Cancel"); it
  stops a billing computer and retrieves an uncollected model.
- **Quitting with a running computer** (owner decision, offer-keep-running). Stop stays the
  default. "Keep the computer running" is offered as a secondary choice with the hourly price,
  the spend so far and a plain warning that the app must be reopened to stop it.
- **Keyboard.** ⌘[ and ⌘] move Back and Next; ⌘1 to ⌘9 open each screen; ⌘↩ runs each screen's
  primary action (Import folder, Confirm and next, Start captioning, Re-caption,
  Publish, Start training, Retrieve now). Renting a computer starts billing and has no shortcut.
  File › Open Recent lists recent projects.
- **Selection.** Lists use native selection. Review selects several photos with ⌘- or ⇧-click.
- **Suggestions prefill, people confirm.** Person, object, character and custom-concept
  proposals fill the editor and require confirmation. Style and motion are assigned directly
  to each whole target. Mapping appears only when a concept needs a locator; mixed jobs merge
  the automatic entries into the confirmed mapping. This follows the owner's afternoon
  review decision on 2026-10-11 and supersedes the earlier motion-confirmation/sole-style rule.
- **One concept by default.** Category, a description and a trigger define the ordinary flow.
  Multiple concepts and detailed caption-policy overrides live under Advanced settings.
- **Operating copy.** Every surface explains its inputs, operation and consequences. Menus and
  buttons name their actions. No sales-page copy or vague substitutes for technical terms.
  Preserve the owner's introductory explanation, with hover/click/keyboard definitions.
- **Honest examples.** Demo photographs are synthetic, captions and advice are prepared, and
  service states are simulated. Never label them as live inference or training-quality evidence.
- **Photos** are decoded as downsampled thumbnails off the main thread and cached in memory.
- **Money** has one format, US dollars in the reader's locale.
- **Settings** has one entry per context: the toolbar in a project, the link on Welcome, and the
  app menu (⌘,).

## Method and evidence

Apply a bounded pass: inspect the existing task flow, critique independently, make one coherent
set of refinements, inspect the built result in both appearances and at the supported sizes,
then repair what that inspection reveals. Preserve model, job, publication and GPU lifecycle
contracts. Do not rent a GPU or run a caption-quality experiment for visual verification.

Impeccable's web HTML/CSS detector does not apply to SwiftUI. Its native platform references
currently cover iOS and Android; use the relevant semantic-color, labeling and native-control
principles while retaining macOS window, pointer and keyboard conventions. Do not impose
phone navigation or touch sizing on this app.

Offscreen renders of the actual SwiftUI views are layout evidence, not proof of live window
interaction, VoiceOver operation, Photos access or signed sandbox behavior. Current outcomes
and remaining checks belong in [APP-STATUS.md](docs/APP-STATUS.md).
