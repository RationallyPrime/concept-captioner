# Handoff, updated 2026-10-11

Read CLAUDE.md and docs/v0.2-plan.md first. This repository is the lab notebook: ordinary
verified commits and pushes to main are authorized. Preserve concurrent work. Curated history
is deferred under the re-stage rule below.

## What exists

The Python CLI/reference, Swift captioning core, nine-screen Mac app and pod agent exist.
The app manages projects, captions, Hub datasets, rented computers and trained results; the demo
works offline. Original public images and FLUX/LTX proofs predate the latest hardening.

Claude's seven hardening lanes were fully pushed through 36617c8: Core, Python, pod, project
contract, GPU module, interface and docs/process. That satisfied the overnight start condition. Reuse their project storage, output retrieval,
UI and transport work. Status documents distinguish source, image and live evidence; an app
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

**Mac application:** implement the owner-approved introduction and single-concept flow, review
all UI surfaces as operating software, and integrate curation/video, saved runs, result generation
and OpenRouter. Keep the ordinary workflow accessible without programming or ML knowledge,
while retaining direct controls for repeat users.

**Pod services:** implement and verify exact dataset pulls, supported training/resume and actual
base-versus-LoRA generation. Rebuild published images when their code changes. Meet the app at
the existing authenticated HTTP API and shared project/training contracts. Secure outputs and
stop paid pods as soon as useful work ends.

## Conventions

Use uv/pytest/Ruff and Swift 6/SwiftPM/Yams/Swift Testing. Tests make no external network requests.
Keep credentials out of output/configuration and private evidence outside this public repository. Use Codex agents: Sol for nontrivial
implementation and independent review, Luna for mechanical work. Resolve routine decisions and
continue autonomously; report concrete blockers rather than declaring unfinished work complete.

The real user training run belongs to the next human walkthrough. The caption-policy comparison
experiment remains deferred until the owner starts it with an appropriately sized dataset.

## Re-stage rule (owner instruction, 2026-10-11)

Do not prepare, maintain, synchronize or publish a re-stage until Hákon explicitly says it is
time to re-stage the app. Decide the granularity and commit partition with him then. Existing
narrative commits and decision sheets are historical drafts, not an agreed partition or an
ongoing maintenance obligation. This rule applies to all agents. Continue ordinary commits
and pushes in this lab repository; it remains the exploration record.
