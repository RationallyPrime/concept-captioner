# ConceptStudio interface

The audience, required features and nine-screen order are defined in [APP-BRIEF.md](docs/APP-BRIEF.md).
This document records the native interface direction applied with
[Impeccable](https://github.com/pbakaus/impeccable), using its Operate, polish and native audit
principles. It does not replace the product brief. The owner delegated this refinement on
2026-10-10; visual preferences remain open to the human walkthrough.

## Direction

A calm workspace for making deliberate choices about photos. The photographs and their
captions carry the visual interest. Give a beginner enough context to act; keep routine
controls quick for a returning user. The interface should feel at home on a Mac.

Hákon supplied [hakonfreyr.com](https://hakonfreyr.com/) as a quality reference: its drawing
sheet composition, rules, annotations and illustrations express one coherent idea. Apply that
discipline here through a photo workspace: a contact sheet, a visible learning boundary and
an image paired with its editable caption. Every visual detail should help the current decision.

- Keep the native sidebar, lists, split views, pickers, menus, sheets, keyboard focus and
  selection behavior. Retain the nine screen names and their order. Group their navigation
  into preparing photos, writing captions and training a model; step numbers describe order,
  never imply that work has been completed.
- Use the system font and SF Symbols. Page titles, section titles, field labels and supporting
  text have distinct, consistent roles. Reserve monospaced text for logs and monospaced
  numerals for prices and counts. Use sentence case.
- Use semantic macOS backgrounds and label colors in both appearances. One adaptive teal tint
  identifies actions and selection; filled buttons use a darker role so white labels retain
  contrast in dark appearance. Pair every status with words or an icon; color alone
  never identifies a warning, a final caption or a selected item.
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
