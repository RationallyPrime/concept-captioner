# Handoff, 2026-10-10

Read `CLAUDE.md` and `docs/v0.2-plan.md` first. This repository is the lab notebook: commit and
push to `main` freely and often, as-is. The curated, narrative history is re-staged later in a
separate repository, so nothing here needs to be tidy.

## What exists

| Area | Where | State |
|---|---|---|
| Python reference and CLI, v0.2 | `src/`, `tests/`, `README.md` | done, tests green, verified live against Gemini |
| Swift core library | `app/` (ConceptCore), `app/docs/CORE-SPEC.md`, `CORE-STATUS.md` | built, tests green; status doc is the last thing its build writes, so if it is missing the build was interrupted |
| Pod side | `pod/`, `pod/docs/POD-SPEC.md`, `POD-STATUS.md` | built, tests green in fake mode; images never built |
| App | `app/docs/APP-BRIEF.md` | brief only; the app is a placeholder |
| Pod verification | `pod/docs/POD-VERIFY-BRIEF.md` | brief only |

## State at handoff (both build workflows were stopped deliberately during their last fix pass)

- Swift: build and 183 tests green; `app/docs/CORE-STATUS.md` lists five confirmed review
  findings still open. The key-safety rule (item 1 below) was carried into `Resolve.swift` by the
  workflow; verify rather than redo.
- Pod: all three test trees (agent 722+, podctl, scripts) and lint green; `POD-STATUS.md` is the
  interim version written mid-run. One confirmed finding is still open: `podctl` treats the
  RunPod proxy's Cloudflare statuses (520-526, notably 522 while a pod boots and 524 on timeout)
  as agent errors instead of "cannot reach the agent". The vLLM extra-flags allowlist was done by
  the workflow; check the LTX preprocess arguments were too.

## Do first

1. The Swift model resolver must enforce the same key-safety rule as the Python one: the
   OpenAI kind never takes a custom base URL; custom OpenAI-compatible servers are the vLLM kind
   with their own key; a custom base URL is https, or plain http only to local or private hosts.
   A job file is data that may have been downloaded; it must never be able to redirect a stored key.
2. The Swift resolver must support the three gateways the Python package already does
   (OpenRouter, Vercel AI Gateway, Pydantic AI Gateway), each with a fixed host and its own key,
   because one gateway key is the default path for the app's users.
3. The two free-form argument lists on the pod side must become allowlists (first item of the
   pod brief).

## Then

Two independent streams, in parallel if two seats are available: the app, per its brief, on this
Mac; the pod verification, per its brief, on cx53 and real pods. They meet at the control agent's
HTTP API, which both briefs point at.

## Conventions

Python: `uv`, `pytest`, `ruff`. Swift: Swift 6, macOS 15, SwiftPM only, Yams the only
dependency, Swift Testing, no network in tests. Keys come from the environment or the Keychain,
never from config, never printed. Private material (market notes, outreach drafts) lives outside
the repo. Orchestration, if any: coding on Opus or Sonnet; Fable only for judgement-heavy,
coding-light steps.

## Working style

Work down this file item by item and keep going. When one stream is blocked (waiting on a pod,
a build, a credential), switch to the other and come back. Do not stop to ask whether to
continue; stop only for something irreversible or something only Hákon can decide, note it, and
carry on with the rest.

## Then keep going: the experiment and the re-stage

When both streams work, run the end-to-end experiment yourself: the same images captioned
trigger-only and concept-boundary, two LoRAs, an inference grid that shows the difference, and
write it up. Then prepare the history rebuild for the second repository: from `v0.1.0`, a
proposed sequence of narrative commits, each building and passing its tests, ending in a tree
identical to the verified one, with a one-page decision sheet per commit (what, why, alternatives
rejected). The walkthrough of those sheets is done together with Hákon before that repository is
published; preparing them is not. This repository stays as the exploration record.
