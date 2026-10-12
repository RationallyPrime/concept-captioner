# Walkthrough repairs and glossary integration, 2026-10-12

The owner authorized implementation of the walkthrough findings and supplied a glossary with
177 dual-layer entries. The original walkthrough remains the decision record; this document
records the resulting behavior and its verification scope. APP-BRIEF and ADR-LOG owner decisions
are unchanged. No re-stage work or pod image publication belongs to this change.

## Result by finding

| Finding | Result |
| --- | --- |
| Welcome | A native project start screen with a three-part journey overview, ordinary New/Open/Demo actions and recent folder locations. The full training explanation stays on Images and in Help. |
| 1–2 | One captioning-account section switches between ChatGPT plan, OpenRouter and manual keys. Section copy explains purpose; connection mechanics are in help. Viewing an account section does not change billing routes. |
| 3 | Empty training-image preference remains empty and shows Automatic. The selected trainer’s current default is resolved when renting. |
| 4 | Closing the demo exits demo mode and restores real account controls without requiring a real project. |
| 5–6 | Hugging Face and RunPod have their own section. Saved keys receive read-only checks; the selected-model caption test is on Captioning. |
| 7 | New projects save an empty concept list. Images and Concepts remain accessible; captioning/publishing/training require a defined concept. The Python reference accepts the same draft contract. |
| 8 | Folder and selected-file import preserve matching caption/response companions. Matching uses original stems before normalization or collision renaming; ambiguous matches are refused. Human-final protection survives. |
| 9 | Dataset advice states how many examples it samples from the full set, chosen evenly, and does not imply exclusion from training. General advice works before a concept is defined. |
| 10 | The full disclosure row is a native button with an expanded/collapsed accessibility value. It applies to content sections in journey screens, Settings, Help and sheets. The sidebar retains the native disclosure style so all nine journey rows remain individually selectable. |
| 11–12 | A person concept with one detected face can use its class noun as locator. Model proposals can be accepted individually or together, with Undo, without replacing existing confirmations. Manual confirmation clears stale proposals. |
| 13 | Provider catalogs populate model menus, with reported media capabilities respected and a custom identifier escape. Provider changes select their default. Gemini normalizes `models/`. vLLM catalog target, credentials and cache context match captioning. |
| 14 | Captioning distinguishes uncaptioned, captioned, imported, final and actual failure/skip outcomes. Imported captions can be protected in bulk. |
| 15 | The multipart-upload repair from PR #3 is retained; no duplicate repair. |
| 16 | Publication progress belongs to a particular operation and project. Queued progress cannot replace its final outcome. |
| 17 | Access errors explain reselecting a folder/re-authorizing after a changed build identity. Release packaging requires an available Developer ID Application identity and verifies its signature. No Developer ID certificate is installed here, so signed-release persistence and notarization remain pending. |
| 18 | Saving/removing a Hub credential notifies the open Publish screen immediately. |
| 19–20 | Offers require stock in the selected volume’s data center with the requested GPU count; RunPod’s useful refusal details are retained. |
| 21 | No saved storage uses a 300 GB persistent pod disk. Stop preserves it; Remove deletes it. The same stopped computer can restart. Uncollected or uncertain outputs prevent removal. Stopped time is excluded from the GPU estimate. |
| 22–23 | H3 checkpoint cadence, retention and saved precision are editable; new H3 defaults are 300 steps, 40 retained and float32. Imported/Repeat settings retain their actual values. Other trainer defaults are unchanged. |
| 24 | The original comparison was with v1, while the app follows v2. Guidance loss stays off with the Circlestone adapter; this was not a default defect. See the adapter constraint below. |
| 25–26 | H3 exposes multiple image resolution buckets, initially 768/1024. Training steps have direct numeric entry. Approved video targets retain their own exact dimensions. |

## Glossary

The supplied JSON is bundled unchanged: 177 entries, 11 sections and 81 sources. Its SHA-256 is
`280934f36cc49a6ffb9e62f86c285bf06d687dea2524e9485140b428c1e810a7`.
Both **Plain language** and **Show me the good stuff** readings are available in contextual
popovers and the Help window. Search covers names, aliases and definitions; related entries
navigate within the same view. Product-specific meanings are marked. The visible scope note
makes clear that educational vocabulary does not promise an implemented feature.

Eighteen separate operational entries preserve explanations for app-specific accounts,
storage, caption controls and the trainer’s guidance-loss objective. They do not replace or
rewrite the supplied definitions. The original owner-written training explanation remains
unchanged and its italic terms link to canonical glossary IDs.

## H3 recipe and published image

The app uses the Circlestone training adapter. Its author explicitly excludes combining that
adapter with guidance preservation loss; the app’s off default matches v2 and the completed
v3 run. An explicit recipe without the adapter is a different configuration. The UI and
validation enforce that distinction rather than silently changing an imported recipe.
[Circlestone model card](https://huggingface.co/circlestone-labs/MiniMax-H3-Image-Training-Adapter)

The new checkpoint and resolution controls use the existing `extra` fields accepted by the
published v0.2.3 image. The canonical warm-start initializer retains the existing four-section
shape. The [offline compatibility witness](walkthrough-gpu-source-witness-2026-10-12.json)
executes the exact published source with edited settings. New pod-script defaults and extra
comparison receipt fields await the separate image publication; the native app sends explicit
settings and does not depend on those implicit defaults. This is source execution, not another
GPU run.

## Verification record

- Initial full local Swift run before the PR #6 follow-ups: 540 tests passed (279 app tests and
  261 Core tests). The later Help/search changes passed a focused 30-test run; final native UI
  changes compiled in the rebuilt app.
- Python reference: 118 tests passed. Pod scripts: 315 tests passed. The full pod-agent suite passed with one skip after its
  initializer fixture was restricted to the canonical four sections. Strict SwiftLint, SwiftFormat,
  Ruff checks/format checks and `git diff --check` passed. Release packaging without a Developer
  ID correctly refuses before building; shell syntax validation passed.
- Independent source reviews covered accounts, project/import/mapping, GPU/training, the glossary,
  Welcome, signing and final interaction repairs. Reported findings were repaired and accepted.
- Actual SwiftUI offscreen rendering covered all nine journey screens, Welcome, Settings,
  concept/media editors, Help, both glossary reading levels, Advanced training, account states,
  empty states and progress/results states in light/dark and minimum/default sizes. The main pass
  produced 126 PNGs; 16 later captures cover Help/training and eight cover navigation/empty
  captioning. A final isolated renderer run also produced 126 PNGs and proved its unique demo path.
- In the running rebuilt app, all nine sidebar rows were selectable. The native demo completed
  captions, review, simulated publication, simulated rental/training, saved-result history and
  Stop. The computer ended Stopped and its run Finished. Concepts' command-return action worked;
  mapping suggestions reported agreement; caption labels changed from Ready to Captioned and
  the simulated failure showed its actionable message. Step-specific footer messages cleared.
- Native Help search ranked LoRA first, both reading levels worked, related-term navigation
  selected the target and cleared the filter, source links appeared, and clicking the far end of
  a disclosure row toggled it. Settings showed each connection section and restored real account
  controls after closing the demo, without changing the project's billing route.
- The native pass found a sidebar styling regression and a renderer/live-demo temporary-folder
  collision; both were repaired. The renderer now has an isolated fixture directory. A failed
  caption row was below the offscreen capture's viewport, so failure-layout acceptance comes from
  the native check. Offscreen video frames do not establish video playback.
- Remote CI, including the older runner Swift compiler, is checked on the pull request separately
  from these local receipts. The first remote pass caught two pod-agent fixtures constructing a
  five-section initializer; the fixtures were repaired without widening the four-section contract.
  No local pass is presented as a remote result.

**Pre-merge preview (2026-10-12):** the rebuilt `app/dist/ConceptStudio.app` in the owner's
primary checkout contained this branch's application changes while PR #6 awaited merge.

## Merge closure (2026-10-12)

[PR #6](https://github.com/RationallyPrime/concept-captioner/pull/6) merged to `main` at
`2b4f15c`; [main CI passed](https://github.com/RationallyPrime/concept-captioner/actions/runs/38291540781).
This closes the pre-merge status above. The final post-follow-up local Swift run is recorded
below; the merge does not expand the
separate runtime and distribution evidence.

## Runtime boundaries

No new paid caption request, pod, GPU training run or family-media inspection was performed by
this repair session. The owner/Claude's completed H3 still-image run and live ChatGPT/OpenRouter
sign-in and captioning are recorded separately in the original walkthrough and reflected in
APP-STATUS and POD-STATUS. Live acceptance of the new account-key checks, new H3 settings,
pod-disk restart/retrieval, H3 clips, external warm-start, same-run Resume and matched H3
generation remains distinct from
offline fixtures. A stable Developer ID certificate and signed sandbox/Photos/bookmark/Keychain
acceptance remain required for distribution.

## Review follow-ups (2026-10-12)

The owner authorized repairing the PR #6 review findings on this branch.

| Finding | Repair |
| --- | --- |
| H3 project defaults | Opening an `h3-` (or `ltx-`) profile project now goes through the model picker's path, so H3 gets 300/40/float32/[768, 1024] with guidance off. Running pods, imported recipes, custom models and preserved trainers are untouched as before. |
| Stopped pod with unsaved outputs | Removal is still blocked by default; the message states the disk's estimated monthly cost (300 GB at RunPod's published $0.20/GB/month stopped-pod rate, labelled as an estimate). A separate confirmation, naming the runs and comparisons that would be lost, removes the computer anyway. |
| H3 recipe adapter | A native recipe without `use_training_adapter` uses the adapter only when it names `assistant_lora_path`, as before PR #6. The import writes that choice explicitly; guidance loss stays refused whenever the adapter is on. |
| Single-file import | Choosing individual images or clips imports without companions when their folder cannot be listed (as in a sandboxed build). Folder import still requires its listing. |
| Custom-server key check | Settings tests the saved key against the Settings URL only, never a project's server or a rented computer's caption server. |
| ChatGPT plan notice | The one-time "You're using your ChatGPT plan" alert is shown again in Settings after a first sign-in. |
| OpenAI model list | Embedding, speech, transcription, image/video generation, moderation, realtime/audio, search and legacy completion models are left out by name; "Other model…" remains. |
| Provider-change comment | Describes the reset to the new provider's default. |
| Publishing refusal | The real reason (for example, no images) is shown instead of "Cancelled". |
| Mapping bulk actions | While the open sample has unconfirmed edits, Accept all skips it and neither Accept all nor Undo replaces the draft. |
| No saved storage | The explicit choice is remembered across launches; picking a volume, or saving a volume ID in Settings, replaces it. |
| Training-image preference | Once per install, a stored value exactly matching the shipped default pattern `ghcr.io/rationallyprime/concept-captioner-pod-{trainer}:<tag>` is cleared to Automatic. |

Each behavior change has a focused test. Full local Swift run: 550 tests passed (289 app,
261 Core); strict SwiftLint and SwiftFormat lint passed. No Python or pod code changed; POD-SPEC
gained one sentence on the adapter rule.
