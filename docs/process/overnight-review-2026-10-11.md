# Review of the overnight work, 2026-10-11

Scope: the eight commits the Codex seat pushed to `main` between `cd5f746` and `ffa225d`
(116 files, 8,168 lines added, 1,256 removed). Reviewed on 2026-10-11 from 13:00 UTC by
Claude: every suite run locally on `ffa225d`, then four reading agents (shared contract,
security surfaces, app claims, pod claims) and two refuting agents that tried to knock down
each finding. 36 findings were raised, 26 survived, 9 were refuted, 1 could not be settled
offline. The per-lane evidence is in the session's workflow journal; this file keeps what
matters.

## Verified on `ffa225d`

| Suite | Result |
| --- | --- |
| root: `pytest`, `ruff check`, `ruff format --check` | 94 passed; clean; clean |
| `pod/agent` | 628 collected, all pass, 1 skipped (TensorBoard not installed in this venv) |
| `pod/podctl` | 125 passed |
| `pod/scripts` | 264 passed |
| `pod/`: `ruff check`, `ruff format --check` | clean; clean |
| `app/`: `swift build`, `swift test` | build OK; ConceptStudio 163 tests in 23 suites, ConceptCore 242 tests in 35 suites, all pass |
| `app/`: `swiftlint lint --strict`, `swiftformat Sources Tests --lint` | clean; clean |

The counts she reports in APP-STATUS (402 Swift at her gate, 94 Python, 892 agent plus
scripts) match what the repository holds. The morning fix `ffa225d` added three app tests.

Live state read from RunPod during the review: both overnight proof pods (`c6xdg7goo1jpkm`,
`5bqs5hgvb166t5`) are `EXITED`, nothing is running, and the 200 GB volume `nydku2wmvd`
exists. Every receipt file POD-STATUS names exists under the private notes, and the pod ids,
rates, SHA-256 values and the $0.6232898 projection in POD-STATUS agree with those files.
The source files baked into the r2 images hash to the files at HEAD.

## Security: sound

- **OpenRouter sign-in.** The code verifier is 64 CSPRNG bytes, the challenge is S256, the
  state is random and checked before any exchange. The loopback listener is the fix-round one:
  `127.0.0.1`, ephemeral port, `/auth/callback` enforced, scheme, host, port, path and
  duplicate query parameters checked. The code exchange goes only to
  `https://openrouter.ai/api/v1/auth/keys` and the key is used only against
  `https://openrouter.ai/api/v1/key`, both through a session that refuses every redirect. The
  key is stored only in the Keychain, never in preferences, project files, logs or error
  text. Cancel, project release, Stop everything and the Settings view disappearing all close
  the listener.
- **ChatGPT sign-in** changed only two user-facing strings and one `try`. Loopback, PKCE,
  state and token handling are as the fix round left them.
- **Packaging**: only an AVKit link and a reworded photo-library usage string. No entitlement,
  Info.plist or URL-scheme change. The Photos entitlement did not come back.
- **Pod**: the new `generate-aitoolkit` and `generate-ltx` services are typed catalog entries
  with bounded parameters; the checkpoint selector resolves under the source run's `output/`
  and rejects absolute paths, dot segments and symlinks anywhere on the path; prompts never
  reach a shell (fixed argv, one element per prompt, no `shell=True`); the new
  `GET /runs/{id}/config` route is bearer-protected and strips tokens; resume cannot change
  the dataset, model or hyperparameters; `pull_dataset.py` keeps its path confinement for
  metadata-listed files.
- **App downloads**: generation galleries, history retrieval and model save all go through the
  one download path that keeps the `standardizedFileURL` prefix check and verifies SHA-256
  before the `.part` file is moved into place.
- **Fix-round protections** are untouched on both sides: `store: false`, the privacy body
  keys, the vLLM key bound to origin, the SSE parser, `Resolve.swift`.

## Confirmed findings

### Needs the owner

1. **APP-BRIEF lost the owner's decisions** (`app/docs/APP-BRIEF.md`, intent rewrite). All five
   `(Owner decision, 2026-10-11)` tags are gone, and with them: never silently switch to
   separately billed API credits; push the LoRA to a private repo by default; close the
   listener on timeout; the app drives the core and never reimplements it; the Mac only
   curates, captions, publishes and watches; the one-GPU versus several-GPU rule; cancel
   everything long-running; lint and format clean; the "Not in v1" list; and the old
   per-screen text (Apple Photos import, readable-text warnings, model-drafted concepts,
   mapping prefill and progress, the Demo badge, App Review, lead with one gateway key,
   sells nothing). Her brief asked for screen copy and five features, not for a rewrite of
   the app brief. Several of the dropped rules still hold in code and in v0.2-plan, so the
   loss is to the record, not the product. Recommendation: restore the decided text and its
   tags verbatim and add an "implemented" note per item; keep her additions (one concept by
   default, curation, video, runs, generation, OpenRouter) beside them.
2. **The Python CLI crashes on a mixed image-and-clip Hub dataset the app can now publish**
   (`src/concept_captioner/sources/hf.py:103`). Swift's Hub source accepts `.mp4/.mov/.m4v`
   by file name; Python switches to video only when the whole column is a `datasets.Video`
   feature, so a mixed repo loads as images and the run dies on the first clip with
   `UnidentifiedImageError`. Reproduced offline. Recommendation: Python reads imagefolder
   repos by file name as Swift does; at minimum, a `ConfigurationError` naming the limit
   before captioning, and a line in CORE-SPEC.
3. **Which providers may receive video** (`GeminiClient.swift:50`,
   `OpenAICompatibleClient.swift:155`, `stages.py:62`). Swift sends clips only to Gemini
   routes, refuses the rest before any network call, and refuses a request body of 20 MiB or
   more. Python hands a `BinaryContent` to pydantic-ai, which also sends video to OpenRouter
   (as `video_url`) and Bedrock, with no size guard. One job can succeed in one tool and fail
   in the other. Recommendation: one rule written into CORE-SPEC; the simplest is "video goes
   to Gemini routes only" with Python refusing other providers before sending.
4. **The Caption schema still says a sample is unusable unless bound to one visible person**
   (`schemas.py:17`, `Schemas.swift:55`). The new task text tells the model a style applies
   to the whole target and motion binds to the movement; the JSON schema sent in the same
   request contradicts it for style, object and motion jobs. This is a shared-schema change,
   so it needs sign-off. Recommendation: make the `usable` description category-neutral in
   both, then update CORE-SPEC.
5. **The r2 images cannot be rebuilt from the repository** (`pod/images/README.md:14`). r2
   was made by layering two overlay Dockerfiles (copying `catalog.py` and
   `generate_results.py`) on earlier digest-pinned images. Those overlays and their base
   digests exist only in the private notes, and no clean build from HEAD has been made.
   Recommendation: one from-scratch build of all three images from HEAD on cx53, tagged, as
   the release the app defaults to; this was already queued as "rebuild images on cx53".
6. **Two stopped pods still carry live tokens** (`GPUProvider.swift:182`, predates this range).
   The Hub token and the agent bearer token are set as literal environment values, and the
   RunPod pod listing returns them in clear text to anyone who can read the account. The two
   overnight pods are stopped, not terminated. Recommendation: rotate the Hub token that was
   on them and terminate both pods once you agree the outputs are secured (the receipts say
   they are). Longer term, pass the Hub token as a RunPod secret reference. Unrelated, noticed
   in the same listing: older stopped pods from other projects are accruing disk charges of
   roughly $0.20 an hour in total.
7. **Each training run now pulls into its own dataset folder on the volume and nothing cleans
   them up** (`GPUWorkspace+Training.swift:101`, POD-SPEC §7 documents this as intended so
   Resume sees the exact dataset). Accept the growth, or add a cleanup or size indicator.

### Bugs to fix

- **The app ignores the pod's `comparison.json` state** (`GPUWorkspace+Generation.swift:68`,
  `TrainingRun.swift:120`). The state field is decoded but never read; success is judged by
  whether any `.png` or `.mp4` exists plus the in-memory service state, so a partly failed
  generation is shown as "Comparison saved in this project" with missing pairs labelled "not
  downloaded". Read the manifest state after download and mark the comparison failed with a
  visible message when it is not `complete`.
- **Stop leaves the private checkpoint copy on the pod** (`generate_results.py:231`,
  `supervisor.py:477`). The copy is removed only in a `finally` block; the agent stops a
  service with SIGTERM and the script installs no handler, so an ordinary Stop skips the
  cleanup. Two early failure paths also sit outside the `try`. Install a SIGTERM handler that
  raises, move the `try` up, and correct POD-SPEC's "forced process termination" wording.
- **Run IDs from the project record are not validated before use as folder names**
  (`GPUWorkspace+Results.swift:395`). Not exploitable today because the agent rejects bad IDs
  first, but local confinement should not depend on what the pod answers. Check IDs against
  the agent's pattern when loading the record and check the run folder against the results
  root.
- **Concepts lost its ⌘↩ primary action** (`ConceptsView.swift:38`). Every other screen kept
  the fix-round shortcut. Give the screen a primary action (save or confirm the concept).
- **Recent-project entries with a missing `job.yaml` get the wrong advice**
  (`ProjectAccess.swift:96`). The `ffa225d` fix works as claimed and its test is real, but a
  readable folder without `job.yaml` now reads as an access failure ("select the folder
  again") and there is no way to remove the entry.
- **Whole clips are read into memory** for hashing, Photos import and frame-time reading
  (`VisionInspector.swift:90`, `StudioActions.swift:427`, `MediaEditor.swift:184`). Works,
  but large clips cost memory and time. Hash by streaming, read timestamps without decoding
  every frame to BGRA.
- **Video suffixes now apply to every dataset pull** (`pull_dataset.py:52`). Generic pulls
  from the CLI and podctl also collect clips now, and POD-SPEC §7.1 does not say so. Either
  limit it to `only_metadata` or document it.
- **The pod does not check that Resume asks for more steps than the checkpoint has**
  (`catalog.py:629`). Only the app guards it; podctl and CLI callers get a no-op or a step
  regression.

### Docs and spec to bring current

- **CORE-SPEC contradicts the code in at least eleven places and the revisions table has no
  rows for this work** (`app/docs/CORE-SPEC.md:312, 416, 609, 627, 632, 638, 645, 676, 870,
  1449, 1512`). Stale: `classNoun` default and fixed trait defaults; the sample view's
  `audio_status` and `evidence` values; the profile list without `ltx-video`; the user-turn
  and critic-turn texts; the `isVideo` parameters; the "copied verbatim" task texts; the
  parity hashes and length; `UserContent` without `.video` and no `MediaInput`; the runner
  pseudocode; the sources section without video suffixes. Missing rows, all 2026-10-11:
  category-derived Concept defaults and the `TargetConcept` helpers; `wholeImageStyleMapping`;
  the category-aware task texts with new hashes; the Prompt `isVideo` parameter and video
  evidence fields; `UserContent.video` and `MediaInput`; video suffixes; `isImage` renamed
  `isMedia`; non-Gemini clients refusing video, Gemini `videoMetadata` at 24 fps and the
  20 MB guard; the `ltx-video` profile.
- **POD-SPEC is below the fix-round standard for the new services** (`pod/docs/POD-SPEC.md:187,
  513, 841, 858`). It still says the catalog has six names; `comparison.json` is mentioned
  but its keys are not specified; `only_metadata`, the video suffixes and
  `generate_results.py` are absent from §6.4 and §7.1.
- **POD-STATUS invites a misreading about FLUX on r2** (`pod/docs/POD-STATUS.md:5`). The FLUX
  generation and Resume proofs ran on the r1 aitoolkit image; the r2 aitoolkit image the app
  now defaults to has only a CPU witness, and the checkpoint-snapshot path has never run on a
  FLUX GPU. One sentence in the opening paragraph fixes it.
- **APP-STATUS overstates two things** (`app/docs/APP-STATUS.md:10, 69`). Glossary
  definitions with hover, click and keyboard exist on Welcome and Images only, not "the
  entire nine-screen flow"; later screens have tooltips at most. The render count is 116
  frames, not 114, and nothing captures an expanded Advanced section.
- **Photo-only wording remains where clips can appear** (`PublishView.swift:52`,
  `StudioActions.swift:166, 362`, `StudioAssistant.swift:114`,
  `GPUWorkspace+Training.swift:104`, `VisionInspector.swift:194`,
  `StudioChatGPTViews.swift:134`).

### Test gaps

- Parity tests pin only the old facial-identity still-image case
  (`PromptTests.swift:14`, comment still cites the CORE-SPEC commit). No cross-language check
  of the video instructions or of the category defaults for the other six categories.
- Sole-style reassignment on approval is implemented (`ProjectCuration.swift:117`) but no test
  approves a target while a sole style concept is active and checks the new mapping
  (`MediaWorkflowTests.swift:413`).
- Most numeric generation limits and several resume refusals have no test
  (`test_generation_resume.py:72`); they are declarative pydantic constraints, so the value is
  low.

### Could not be settled offline

- OpenRouter's documentation names `localhost` for callbacks; the app sends
  `http://127.0.0.1:<port>/auth/callback`. Only a live consent settles it; APP-STATUS already
  lists that as pending.

## Refuted, for the record

`wholeImageStyleMapping` as Python-only (it writes an ordinary mapping the CLI reads fine);
the aesthetics-score removal and the video item moving out of "Later" (both follow the
owner's overnight brief); DESIGN.md recording her choices as rules (the file says the two
marked owner decisions are the only closed ones); Mapping refusing an empty confirmation (the
shared contract already forbids empty mappings on both sides); the removed Welcome privacy
line (the owner asked for import reassurances to go); OpenRouter amounts bypassing
`StudioMoney` (same format, new file, nothing regressed); the POD-VERIFY-BRIEF rewrite (no
requirement weakened, section by section); settled billing exceeding the projection (the
projection was compute only and was conservative for compute).

## CI

The macOS job has never completed since it was added in the fix round. On `7b65fd9` every
core test passed in thirty seconds, then all app tests started at once and none finished;
the job sat idle until GitHub's default six-hour timeout. The same happened on every commit
since, so five runs were hanging during this review. The app tests use an in-memory secret
store, so the Keychain is not the blocker; most app tests are main-actor bound, so the likely
cause is the main thread not being serviced on the runner. Next step: add `timeout-minutes`
to the job, and take a process sample on the runner to find the blocked thread.
