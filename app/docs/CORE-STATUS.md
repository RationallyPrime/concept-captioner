# CORE-STATUS

State of ConceptCore on 2026-10-10 after the handoff repairs and independent acceptance.

## What exists

All nine modules of `CORE-SPEC.md` are implemented with tests: models (Job and friends, YAML),
skills (Agent Skills loader, bundled skill as a resource), prompt, triggers, images, model clients
(OpenAI-compatible, Responses, Anthropic, Gemini; structured output with one in-conversation retry;
`resolve` with the key-safety rule), runner (streaming outcomes, optional critic, response
records, human-final skip), sources (local folder, sidecar sink) and hub (Hub client with LFS
upload and verify, imagefolder source and sink).

Handoff baseline: `swift build` and `swift test` green, 183 tests in 26 suites; swiftformat and
swiftlint clean. Current acceptance is the 207-test run recorded below. The workflow's four review lenses (parity with the Python
reference, Swift 6 concurrency, API fitness for an app, wire formats of the three clients and the
Hub) produced 28 findings, 19 confirmed adversarially, 14 fixed inside the workflow. The fixer
on `HubClient.swift` was interrupted mid-edit; the missing call-site change was completed by hand
and the suite re-run.

The offline suite covers stubbed model transports and the runner. The Swift Hub client and
owned vLLM endpoint have also passed the live checks below. Direct-provider and gateway
requests remain verified offline only.

## Accepted gateway and provider work, 2026-10-10

The Sol core author implemented Vercel and Pydantic AI Gateway routes alongside OpenRouter.
Each has its own key and fixed origins. Pydantic routing uses native Vertex, Anthropic,
Responses (the default OpenAI route), or explicit Chat Completions, matching the finite
supported Python routes. Job URLs cannot redirect gateway keys. Unsupported upstreams and
key regions fail with configuration errors.

Independent coordinator review accepted the frozen changes after source inspection, outgoing
request tests and a complete isolated core run: **207 tests in 30 suites passed**. The isolated
SwiftPM package uses the exact repository source/tests and existing Yams checkout; it establishes
core behavior while app screens are still being edited. The author’s strict SwiftLint and
SwiftFormat checks passed on all eleven changed source/test files. These are offline checks;
live direct-provider/gateway acceptance remains outstanding. Subsequent live Hub and owned
vLLM evidence is below.

The remaining handoff findings are dispositioned:

- Hub LFS verification was already called after every pending PUT. New tests verify ordering,
  object IDs/sizes, headers and that verification failure prevents the commit. No Hub code rewrite.
- Claude thinking uses model-family budget/adaptive capabilities, only supported effort values,
  and sufficient output-token space; explicit insufficient limits fail clearly.
- Gemini thinking uses 2.5 budgets or the family’s supported levels, with old non-thinking
  models omitted and the Developer/Vertex distinction retained.
- OpenAI-compatible thinking rejection retains the provider response and names the model,
  selected effort and corrective setting action. This does not claim every model accepts thinking.

`Runner.run` now provides an awaited async outcome callback for the app. Tests demonstrate
updates before completion and cancellation draining an uncooperative provider before returning;
no source access is released while a child can still write.

## Not done yet

- Live direct-provider and gateway requests; no authorized key source was established.
- Parquet-backed Hub datasets remain out of scope for v1; imagefolder convention only.

## Accepted key-routing repair, 2026-10-10

The key-routing finding is repaired and independently accepted by the Sol key-review agent:
the vLLM key is bound to the user-configured host in Python and Swift;
job authentication/routing headers and sampled ambiguous URL inputs are rejected. The Swift
KeyStore now carries the user-configured vLLM endpoint separately from the job.

Local checks after this repair: all 186 Swift tests in 26 suites passed (stub transports only),
strict swiftlint and formatting clean; all 48 Python tests passed, with focused Ruff checks
clean. The new tests observe outgoing authentication headers for matching and different hosts.
Independent review reproduced a Python Unicode-dot hostname/parser gap. Python now uses the
SDK's httpx2 URL normalization before host classification and key binding; its U+3002, U+FF0E
and U+FF61 witnesses are rejected over HTTP. Swift checks its Foundation URL before sending.
The review also verified actual pydantic-ai Agent requests with a mock HTTP transport: matching
host gets the vLLM key, different host gets no Authorization, harmless headers survive.
Explicit Python OpenAI/Anthropic origins ignore ambient base-URL overrides, while missing keys
still fail as ConfigurationError. Both closure findings were accepted; sampled coverage does
not establish exhaustive URL-parser equivalence or live-provider acceptance.

Gateway/core work has independent acceptance. App implementation and real pod verification
continue under `docs/SWARM-PLAN.md`.

## Live Swift Hub proof, 2026-10-10

The Sol core agent ran accepted commit `602c60c` against the real Hub with synthetic images in
private dataset `RationallyPrime/conceptstudio-swift-smoke-20261010`. Commit
`a6aef9afa5ed209d11c1027ede2131ba4d6ad8c4` contains two images and their metadata captions/records.
The Hub advertised two LFS verify actions: both uploads returned 200, each verify POST returned
200, and the dataset commit returned 200 only afterward. Both downloaded image byte sequences
and their hashes/sizes matched, and the two source samples and metadata records round-tripped.
Credentials were neither printed nor written to project files. This establishes the core Hub
client path; app UI import/publication and model-provider requests have separate evidence.

## Live Swift model proof, 2026-10-10

The Sol core agent exercised the actual `Endpoints.resolve(vllm)` and OpenAI-compatible client
against the owned pod proxy, with an image and native structured-output schema. The request
returned HTTP 200 from requested/served `Qwen/Qwen2.5-VL-3B-Instruct`, describing the synthetic
blue circle on a white background; reported usage was 61 input and 16 output tokens. The
retained pod token was bound to its user-configured endpoint and never printed. The accepted
core source hashes remained unchanged. This proves one native vLLM image request from Swift;
the full concept-boundary prompt and training behavior are separate pod-stream checks.

## Live native pod-agent read proof, 2026-10-10

At 19:24:17–19:24:18 UTC, the Sol core agent compiled an exact copy of the current app's
`PodAgentClient.swift` with the current ConceptCore source in a temporary SwiftPM package
outside the repository. The copied client and all recorded native source hashes matched
the repository after the live read. Its authenticated, read-only requests to the owned pod
proxy returned HTTP 200 for `POST /plan`, `GET /services`,
`GET /services/trainer-ltx/logs`, and `GET /runs/tiny-flux-proof-20261010/events`.
The plan decoded sequential captioning/training on GPU 0; current service states retained
the completed LTX run ID, and current LTX logs decoded to 200 lines without retaining their
contents. The plan POST computes assignments and does not start or stop services.

The persisted FLUX run returned a real `scraped/loss` scalar at step 2, value
`0.05031000077724457`. The app's actual `latest()` decoder produced the matching
`TrainingPoint`, whose step/loss fields feed the Monitor curve. This proves native decoding
of one actual FLUX point and authenticated control reads; no GUI was launched or rendered,
no resource actions were made, and existing tests remain network-free. The token was read
only inside the probe and was not printed or retained in the receipt.

LTX curve decoding remains unproved. The pod-stream owner reported that the completed LTX
run produced no TensorBoard events because its trainer environment lacked TensorBoard.
A separate native LTX read awaits that image repair and an actual loss scalar; the FLUX
point does not establish LTX curve behavior.
