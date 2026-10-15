---
target: ConceptStudio app
total_score: 25
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:/Users/hakonfreyrgunnarsson/Projects/concept-captioner-worktrees/ltx-23/app/Sources/ConceptStudio/StudioRootView.swift"
target_fingerprint: "sha256:058882325db90b35afb60099c06d7b15275b894bd1985df06c6fd18b652e5cab"
target_path: /Users/hakonfreyrgunnarsson/Projects/concept-captioner-worktrees/ltx-23/app/Sources/ConceptStudio/StudioRootView.swift
timestamp: 2026-10-15T13-26-47Z
slug: app-sources-conceptstudio-studiorootview-swift
---
Method: dual-agent (A: design review · B: detector + measured evidence), on 145 offscreen renders of the current code (demo data, light and dark, 1240×820 and 980×680).

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Status pairs and footer GPU spend work; finished Training shows a raw /var/folders path; captioning failures not visible per sample |
| 2 | Match System / Real World | 2 | Sidebar says "GPU pods", body says "computer"; model identifiers, "1 · caption, then train", "Published revision" on the default path |
| 3 | User Control and Freedom | 3 | Back/Next, undo curation, discard edits, Stop everything; no undo after re-caption |
| 4 | Consistency and Standards | 2 | System blue leaks past the one-teal rule (links, sliders, Mapping checks); training model chosen on two screens; misaligned Settings fields |
| 5 | Error Prevention | 3 | Final captions protected, price in the Rent label, safe alert defaults; Rent has no total-cost estimate |
| 6 | Recognition Rather Than Recall | 2 | Review lists filenames with no thumbnails or state; primary actions below the fold |
| 7 | Flexibility and Efficiency | 3 | ⌘1–9, ⌘[ ], ⌘↩, multi-select; no Save-and-next or not-final filter in Review |
| 8 | Aesthetic and Minimalist Design | 2 | ~135 pt of header prose on every screen; flat but bland, nothing emphasised but teal pills |
| 9 | Error Recovery | 2 | Blocking failures land in a generic "Could not complete the operation" alert |
| 10 | Help and Documentation | 3 | Definitions on every screen, glossary with two readings; help is a separate window |
| **Total** | | **25/40** | **Acceptable** |

## Design Specificity Verdict

LLM assessment: category-interchangeable. Every screen is the same large-title header, grey sentence, Definitions disclosure, demo capsule and Help pill, flat sections of Form pickers, teal pills, and a Stop/Back/Next footer. System font throughout, teal is the only colour decision, the app mark is a stock SF Symbol. None of the portfolio's drawing-set vocabulary survives, and DESIGN.md is part of the cause: it cites the portfolio only as "discipline", then mandates system font, SF Symbols and semantic backgrounds. Its own substitute idea (contact sheet, one defined concept, image paired with its caption) is not realised: Review lists filenames, Images is a form with pictures. The one product-specific graphic is Mapping's numbered face locator, which is literally the portfolio's locator bubble.

Deterministic scan: impeccable detect has no Swift support. Directory scan of app/Sources/ConceptStudio: 0 findings (skips .swift); all 87 files passed by name: 0 findings (web regex only). Not a native audit.

Measured evidence (B): text contrast passes everywhere outside the sidebar (body 14.9/12.4, supporting 7.2/8.0, tinted buttons 7.9/7.0, filled buttons 8.5/6.5). Non-text affordances fail 3:1: tinted button and picker fills 1.09, demo badge fill 1.18, text-field border 1.40 (light), filled teal button in dark 2.62. Fields are 64–65% of the window for 18–24% content. Disabled "Save caption" keeps a teal fill (3.9:1 against the page) and can read as enabled. No clipping at minimum size outside the advanced-training harness render.

Visual overlays: none (native target, no browser).

## Overall Impression

Honest, careful operating copy and solid keyboard structure inside an interface with no identity, whose core task (editing a caption) happens in a field you cannot see, and whose primary actions mostly sit below the fold. Biggest opportunity: give the app a world of its own and fix the affordances in the same pass.

## What's Working

1. Honest consequence copy: every action states what it does and costs ("No model request or charge"; storage billed while stopped); Rent carries the price and has no shortcut.
2. Native structure: three-phase sidebar with step numbers and "step n of 9" accessibility labels, ⌘1–9, ⌘[ ], ⌘↩, Mapping's "Confirm and next ⌘↩" with a face locator.
3. Appearance-aware colour: one teal plus a darker action tint so white labels keep contrast in dark; warnings pair an icon with words.

## Priority Issues

[P1] Primary actions below the fold. Publish's button is cut by the footer at 1240×820; Rent, Start training and Retrieve now are not visible at either size. Fix: each screen's primary action in the footer's trailing slot (Concepts already does this), Next secondary until the step is done, header prose folded into one line. /impeccable layout

[P1] Invisible surfaces and affordances. canvas and surface are both white in light (StudioStyle.swift:19-20), so the Review caption editor and every notice have no boundary; measured: field border 1.40:1, button fills 1.09:1, badge 1.18:1. Fix: 1px separator stroke and focus ring on the editor, distinct canvas/surface tokens, Review rows with thumbnails and Final/edited markers. /impeccable polish

[P1] No product identity. Proposed (owner's call): keep native controls, adopt three or four drawing-set signatures: a title-block header (project · step n/9 · trigger · model · spend), numbered locator bubbles as the shared sample marker across Images/Mapping/Review, dimension-figure treatment for price/budget/spend/loss, a contact sheet with frame numbers on Images; amend DESIGN.md's system-font-only clause for one condensed face on titles and figures. /impeccable shape, then /impeccable bolder

[P2] The money moment lacks a total. GPU pods shows an hourly rate and a budget field; the per-run estimate lives on Training, after renting. Fix: "Rent · about $X for this run" with duration and the stop-at limit beside it. /impeccable clarify

[P2] Sidebar evidence is unreliable and has shipped. Every render shows the selected row as a black fill with 0 label pixels, light icons on white, and black text in dark mode; the explicitly coloured sidebar text renders correctly and the same List in the detail pane selects normally, so this is most likely the offscreen renderer dropping sidebar vibrancy, not the code. The README hero images come from the same harness and show the broken sidebar. Live selection colour is probably the system accent, not teal. Fix: one real-window capture to settle it, retake the README images from a real window, have the harness flatten or exclude the sidebar. /impeccable audit

## Persona Red Flags

Jordan (first-timer): "LoRA" before it is defined on Concepts; editable "Model identifier" on the default captioning path; "Number of GPUs: 1 · caption, then train"; sidebar "GPU pods" vs body "computer"; Stop everything prominent on step 1 with nothing running; Publish half hidden; the journey ends on a temp path.

Sam (accessibility): caption editor fails 3:1 non-text contrast (has a label); 9 pt white-on-teal locator tag in Mapping; disabled Save caption reads as enabled; ChatGPT black button in dark at 1.23:1 against the page.

Alex (power user): ~135 pt of repeated header prose, not hideable; no Save-and-next in Review; captioning setup re-presented every visit; Monitor results behind a five-segment control.

## Minor Observations

Raw /var/folders path on finished Training; crop sheet clips its Width slider row; Mapping progress bar grey and checks system blue; "1,50 US$/GPU/hour" reads badly; Welcome is empty below the project list; untracked app icons exist but the sidebar mark is an SF Symbol; captioning-failed render is identical to captioning (the harness exercises no visible failure); one fixed-size font (WelcomeView.swift:52, 36 pt).

## Questions to Consider

1. If the header became a title block, does the app gain its identity and lose 50 pt of prose at once?
2. Why does Review, the core of the product, list filenames instead of photographs?
3. What if GPU pods asked "Train this concept: about 40 minutes, about $2, stops at $5" instead of asking for a computer?
4. What if Mapping's numbered locator became how every screen refers to a sample?
5. Should Stop everything carry equal weight when nothing is billing?
