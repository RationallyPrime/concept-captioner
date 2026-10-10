# CORE-STATUS

State of the ConceptCore library on 2026-10-10, written by hand after its build workflow was
stopped during the last fix pass (to save session budget; nothing was lost).

## What exists

All nine modules of `CORE-SPEC.md` are implemented with tests: models (Job and friends, YAML),
skills (Agent Skills loader, bundled skill as a resource), prompt, triggers, images, model clients
(OpenAI-compatible, Anthropic, Gemini; structured output with one in-conversation retry;
`resolve` with the key-safety rule), runner (streaming outcomes, optional critic, response
records, human-final skip), sources (local folder, sidecar sink) and hub (Hub client with LFS
upload and verify, imagefolder source and sink).

Verification: `swift build` and `swift test` green, 183 tests in 26 suites; swiftformat and
swiftlint clean on the last run. The workflow's four review lenses (parity with the Python
reference, Swift 6 concurrency, API fitness for an app, wire formats of the three clients and the
Hub) produced 28 findings, 19 confirmed adversarially, 14 fixed inside the workflow. The fixer
on `HubClient.swift` was interrupted mid-edit; the missing call-site change was completed by hand
and the suite re-run.

Everything is fake-verified: model clients against a stubbed transport, the Hub client against a
stubbed transport, the runner against a fake model client. No call has been made to a real
provider or to the Hub from Swift.

## Open findings (confirmed by review, not yet fixed)

- `HubClient.swift` ~290 (medium): after the LFS PUT, POST the batch reply's `verify` action
  (`{oid, size}`, LFS media types, Hub token), as `huggingface_hub` does. The plumbing now exists
  (`verifyLFS`, `LFSUpload.verify`); confirm it is called after every PUT and tested.
- `AnthropicClient.swift` ~88 (medium) and ~103 (low): thinking is always sent as adaptive plus
  an effort, which older still-served models reject; `xhigh` exists only on newer models. Map
  thinking per model family or fall back to `budget_tokens`.
- `OpenAICompatibleClient.swift` ~92 (low): `reasoning_effort` is sent for every non-none thinking
  level; non-reasoning models reject the parameter and some values exist only on some models.
  Send it only where the model accepts it, or let the request fail with a clear message.
- `GeminiClient.swift` ~101 (low): `medium` thinking is not accepted by every Gemini model.

## Not done yet

- Gateway kinds `vercel` and `gateway/<provider>` in `resolve` (the Python reference has them).
- Parquet-backed Hub datasets (out of scope for v1; imagefolder convention only).
- A real-provider smoke run from Swift.
