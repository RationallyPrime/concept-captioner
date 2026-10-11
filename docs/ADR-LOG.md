# Architecture decision log

This log preserves accepted owner decisions independently of implementation progress and
rewrites of the product brief. **Implemented does not mean superseded.** Keep accepted decision
text and its date. Change a decision only on the owner's instruction: add a dated superseding
record, link both records, and retain the original text. Correct factual implementation notes
separately; an implementation gap does not weaken the decision.

## Provenance and reading order

ADR-0001–ADR-0005 were accepted on **2026-10-11**. Their decision text is restored verbatim from
[the app brief before the overnight rewrite](https://github.com/RationallyPrime/concept-captioner/blob/36617c8/app/docs/APP-BRIEF.md).
The rewrite in [8c86061](https://github.com/RationallyPrime/concept-captioner/commit/8c86061dce1ca3b46dfc8d276c24c9d9053cdfad)
removed the explicit records; it did not supersede the decisions. The owner reaffirmed their
retention on the same date and asked for this durable log.

Read this log alongside [APP-BRIEF](../app/docs/APP-BRIEF.md). The brief describes the current
product; these records remain implementation constraints. [APP-STATUS](../app/docs/APP-STATUS.md)
tracks verification. Other owner decisions already recorded in [CLAUDE.md](../CLAUDE.md),
[the product plan](v0.2-plan.md), and [the overnight review decisions](process/overnight-review-2026-10-11.md#owner-decisions-on-the-items-above-2026-10-11-afternoon)
remain in force; this restoration does not replace or reopen them.

Implementation notes below are a source/evidence snapshot at `d184557` on 2026-10-11, not new
decisions or a claim that every requirement has passed a live user walkthrough. Dated follow-ups
record repairs without erasing that snapshot or changing the accepted decision text.

| Record | Decision | Decision status |
| --- | --- | --- |
| [ADR-0001](#adr-0001--project-files-and-custom-skills) | CLI-compatible project files and project-contained skills | Accepted |
| [ADR-0002](#adr-0002--chatgpt-plan-access-and-streaming) | ChatGPT plan captioning without a silent billing change | Accepted |
| [ADR-0003](#adr-0003--money-safety-and-running-computers) | Price, budget, idle, quit, stop, wake and reconciliation controls | Accepted |
| [ADR-0004](#adr-0004--delivery-of-the-trained-lora) | Private publication or local delivery, with result preservation | Accepted |
| [ADR-0005](#adr-0005--sandbox-compatibility-and-callback-lifetime) | Sandbox-compatible architecture and bounded sign-in listeners | Accepted |

## ADR-0001 — Project files and custom skills

**Status: Accepted. Decision date: 2026-10-11.**

### Decision (verbatim)

- **Project on disk in the same layout the CLI uses** (images, job file, caption sidecars with
  response records), so the app and the CLI interoperate and nothing is proprietary. A custom
  skill the user picks is copied into the project (`skill/<name>/`, written as `skill: ./skill/<name>`); the
  job never points outside the project. *(Owner decision, 2026-10-11.)*

### Implementation snapshot

**Implemented for project storage and copied skills.** The app writes the shared job,
sidecar and response-record formats. Selecting a custom skill copies it into the project and
saves the relative reference. The existing project-contract test checks that removing the
original skill and moving or publishing the project preserves that reference and its contents.
See [project storage](../app/Sources/ConceptStudio/StudioProject.swift) and
[project-contract tests](../app/Tests/ConceptStudioTests/ProjectContractTests.swift).

This does not establish complete interoperability for every media source. The Python CLI
resolves a relative skill from its working directory, so run it from the project folder.
Its [Hub loader](../src/concept_captioner/sources/hf.py) still cannot load the app's mixed
image/clip datasets correctly; that repair remains required by the
[overnight review decisions](process/overnight-review-2026-10-11.md#owner-decisions-on-the-items-above-2026-10-11-afternoon).

**Review repair, 2026-10-11:** Python now retains the loaded job's folder for relative skill
and `.md` profile paths. Explicit CLI overrides remain working-directory-relative. The Hub
imagefolder source reads images and clips by file name, and its sink updates the existing
metadata without forcing mixed media into an image column. Focused offline tests cover a
job loaded outside its folder and exact mixed-media bytes. See [CORE-SPEC](../app/docs/CORE-SPEC.md)
for the current contract and [APP-STATUS](../app/docs/APP-STATUS.md) for the final verification.

## ADR-0002 — ChatGPT plan access and streaming

**Status: Accepted. Decision date: 2026-10-11.**

### Decision (verbatim)

- **Log in with ChatGPT** as an alternative to a key: eligible users can caption with OpenAI
  models on their ChatGPT plan. Captions stream, so progress shows while each one is written.
  Show the active account, available models, plan usage and its management link. Keep
  credentials in Keychain; never silently switch to separately billed API credits.
  *(Owner decision, 2026-10-11.)*

### Implementation snapshot

**Implemented with two display gaps.** Browser sign-in, account selection, model discovery
and selection, plan-access status, Keychain storage, usage-limit errors and the Manage usage
link are present. Selecting the plan route uses its OAuth client or reports an error; it does
not fall through to API-key billing. See [account and model controls](../app/Sources/ConceptStudio/StudioChatGPTViews.swift),
[Keychain storage](../app/Sources/ConceptStudio/ChatGPTAccounts.swift) and
[endpoint selection](../app/Sources/ConceptStudio/StudioEndpointChoices.swift).
The production client's image-caption request succeeded in the
[recorded live check](../app/docs/APP-STATUS.md#chatgpt-connection-follow-up-2026-10-11);
the owner subsequently confirmed the native connection test succeeded.

The [client consumes streamed events](../app/Sources/ConceptCore/ModelClient/ChatGPTModelClient.swift),
but returns only the completed caption. [UI progress](../app/Sources/ConceptStudio/StudioActions.swift)
advances when each sample settles; visible progress from the stream while that caption is
being written is still missing. Plan usage currently has a management link and limit handling,
but no in-app usage/remaining-allowance display. Both remain requirements.

**Review repair, 2026-10-11:** real ChatGPT text deltas now flow through the client, structured
stage and runner to a display-only per-sample caption preview. Retries and settled, failed or
cancelled runs clear that preview; only a validated completed caption is saved. The owner has
confirmed native sign-in and live captioning with ChatGPT and OpenRouter. The remaining
in-app plan-usage/allowance display is still a requirement; this repair does not close it.

## ADR-0003 — Money safety and running computers

**Status: Accepted. Decision date: 2026-10-11.**

### Decision (verbatim)

- **Money safety**: price before creating a pod, running cost while it is up, a per-run budget cap
  that stops the pod, an idle watchdog, a warning on quit while a pod runs, and an always-visible
  stop-everything action. Keep the Mac awake while a pod runs; on launch, find pods this app
  created that are still running and show them. *(Owner decision, 2026-10-11.)*

### Implementation snapshot

**Implemented for the tracked rental, with budget and launch-discovery gaps.** The app shows
a price before rental, estimated GPU spend while running, budget and idle stops, quit warnings,
persistent Stop everything controls and a Mac idle-sleep assertion. Provider stop is followed
by status readback. See [rental controls](../app/Sources/ConceptStudio/GPU/GPUJourneyView.swift),
[monitor and stop logic](../app/Sources/ConceptStudio/GPU/GPUWorkspace.swift),
[quit handling](../app/Sources/ConceptStudio/AppLifetime.swift) and
[sleep/reconciliation logic](../app/Sources/ConceptStudio/GPU/GPUWorkspace+Results.swift).

The budget currently measures the rental from its start, so successive training runs share
one cap; it is not yet a per-run cap. [Automatic launch recovery](../app/Sources/ConceptStudio/StudioSession.swift)
only runs when local metadata already records a running/starting pod. With missing or stopped
metadata, discovery waits for GPU configuration through Settings or a GPU screen. Additional
owned running pods are shown with individual Stop controls, outside the tracked rental's cap.

These guards run on the Mac; they do not enforce limits while the app is absent or the Mac is
asleep. The spend figure excludes separately billed saved storage. Existing tests cover the
guard logic, and native provider stop/readback has live evidence; physical sleep behavior,
automatic budget expiry and missing-record discovery at actual launch are not live-verified.

## ADR-0004 — Delivery of the trained LoRA

**Status: Accepted. Decision date: 2026-10-11.**

### Decision (verbatim)

- **The trained LoRA reaches the user**: by default, if the user is signed in somewhere the
  LoRA can be pushed to, push it to a private repo there when training finishes; otherwise
  save the `.safetensors` file into the project. Many users have no GitHub or Hugging Face
  account, so saving to disk is a first-class outcome, not an error. Today the push target is a
  Hugging Face model repo, used when a Hub write token is configured. No stop discards a result
  that has been neither pushed nor saved. *(Owner decision, 2026-10-11.)*

### Implementation snapshot

**Delivery and preservation paths are implemented, with permission and privacy gaps.**
Training defaults to a private Hub destination when a token and destination are available.
Local retrieval saves the newest `.safetensors` and run files under the project's
`results/<run-id>/`, verifies their hashes and records the saved result. Ordinary stop is
guarded while finished outputs are uncollected. An explicit Stop anyway or budget stop leaves
those files on network storage and retains pending-result metadata for later retrieval.
See [training destination selection](../app/Sources/ConceptStudio/GPU/GPUWorkspace+Training.swift),
[local retrieval and preservation](../app/Sources/ConceptStudio/GPU/GPUWorkspace+Results.swift)
and the [stop guard](../app/Sources/ConceptStudio/GPU/GPUWorkspace.swift).

The app currently treats any nonempty Hub token as push-capable; it does not verify write
permission first. A failed push can fall back to local retrieval. Also,
[private repository creation](../pod/scripts/push_lora.py) does not privatize an existing
public destination. Neither qualification changes the accepted write-token/private-default
requirement. Earlier private Hub pushes and native FLUX/LTX checkpoint downloads with offline
reopening provide [live transfer evidence](../app/docs/APP-STATUS.md#live-evidence-and-remaining-acceptance).

## ADR-0005 — Sandbox compatibility and callback lifetime

**Status: Accepted. Decision date: 2026-10-11.**

### Decision (verbatim)

- **Sandbox-compatible from day one** so the Mac App Store stays an option: user-selected
  folders only, no subprocesses, outbound networking plus a temporary `127.0.0.1` callback
  listener for ChatGPT sign-in. Close the listener on completion, cancellation or timeout.
  *(Owner decision, 2026-10-11.)*

### Implementation snapshot

**Architecture implemented in source; signed sandbox execution remains unverified.** Projects
use user-selected folders, security-scoped access and bookmarks, releasing access on close.
The app source launches no subprocesses. The sign-in listener binds only to `127.0.0.1`;
completion, cancellation, errors and the 600-second timeout share cleanup of the listener and
pending connections. See [project access](../app/Sources/ConceptStudio/StudioSession.swift)
and [callback lifetime](../app/Sources/ConceptStudio/ChatGPTCallback.swift).

Sandbox entitlements are declared, but the preview build does not apply them or sign the
bundle. Native project reopening and browser cancellation have been exercised; those checks
do not prove signed sandbox behavior or an elapsed live timeout. The
[distribution acceptance limits](../app/docs/APP-STATUS.md#live-evidence-and-remaining-acceptance)
remain open. Signing work is deferred at the owner's request; the architectural decision
remains in force.
