# Handoff, updated 2026-10-12

Read CLAUDE.md, docs/v0.2-plan.md and [ADR-LOG](ADR-LOG.md) first.
Accepted decisions remain in force after implementation; preserve their text and record any
owner-approved replacement as a dated superseding decision. Ordinary verified commits and pushes to main are
authorized in this lab repository. Preserve concurrent work; curated history remains deferred.

## What exists

The Python CLI/reference, Swift captioning core, nine-screen Mac app and pod agent exist.
The app manages projects, captions, Hub datasets, rented computers and trained results; the demo
works offline. Current public images include the hardening and new generation/video services.

Claude's seven hardening lanes were fully pushed through 36617c8: Core, Python, pod, project
contract, GPU module, interface and docs/process. The overnight start condition is satisfied.
Reuse their storage, output retrieval, UI and transports. Status documents distinguish source, image and live evidence; an app
build does not prove live success.

## Three standing rules

1. Provider credentials go only to their intended origins. OpenAI uses its fixed service;
   custom OpenAI-compatible endpoints use vLLM with a separately configured key. Downloaded
   job data cannot redirect stored credentials or supply authorization headers.
2. Gateways have fixed service origins and separate credentials. Browser authorization uses
   documented consent flows and Keychain storage. Never borrow another application's tokens
   or silently substitute separately billed API access for a subscription.
3. The pod runs only validated commands from its fixed catalog. Client parameters cannot
   become arbitrary command arguments, filesystem destinations or network/authentication changes.

## Two parallel streams

**Mac application:** live ChatGPT and OpenRouter sign-in/captioning and one H3 still-image training
run on `v0.2.3-clean-20261011` are complete. PR #6 merged to `main` on 2026-10-12. Next is the
owner's native walkthrough of the merged repairs, followed by VoiceOver and signed-sandbox
Keychain, Photos and bookmark checks when a Developer ID Application identity is available.
Direct upload, storage cleanup, in-run TensorBoard rendering and the repaired generation/Resume
paths still need live acceptance. Keep the workflow accessible without programming or ML
knowledge, with direct expert controls.

**Pod services:** the H3 still-image run verifies one 69-still, 3,000-step train/publish/stop path.
H3 clips, external warm-start, same-run Resume and matched generation still need live acceptance.
Maintain exact dataset pulls and the shared authenticated HTTP contract. Rebuild published images
when their code changes. Secure outputs and stop paid pods as soon as useful work ends.

## Conventions

Use uv/pytest/Ruff and Swift 6/SwiftPM/Yams/Swift Testing. Tests make no external network requests.
Keep credentials out of output/configuration and private evidence outside the repository. Use Codex agents: Sol for nontrivial
implementation and independent review, Luna for mechanical work. Resolve routine decisions and
continue autonomously; report concrete blockers rather than declaring unfinished work complete.

The caption-policy comparison experiment remains deferred until the owner starts it with an
appropriately sized dataset.

## Re-stage rule (owner instruction, 2026-10-11)

Do not prepare, maintain, synchronize or publish a re-stage until Hákon explicitly says it is
time to re-stage the app. Decide the granularity and commit partition with him then. Existing
narrative commits and decision sheets are historical drafts, not an agreed partition or
maintenance obligation. This applies to all agents. Continue ordinary lab commits and pushes.
