# CORE-STATUS

State of ConceptCore, the Swift captioning library, after the 2026-10-11 fix round;
live checks date from lab commit `e620882` (2026-10-10). The
contract is [CORE-SPEC.md](CORE-SPEC.md). The day-by-day record is in
[status-history-2026-10-10.md](../../docs/process/status-history-2026-10-10.md).

## What exists

All nine modules of CORE-SPEC, with tests:

- **Models and skills:** Job and friends with YAML round trip; the Agent Skills loader with the
  bundled skill as a resource; prompt assembly; the exact-token trigger check.
- **Model clients:** OpenAI-compatible (vLLM and any compatible server), OpenAI Responses,
  Anthropic, Gemini, and a ChatGPT-plan client that streams from the Responses endpoint with
  `store: false`. Structured output with one in-conversation retry. Gateways: OpenRouter, Vercel
  AI Gateway and Pydantic AI Gateway, each with a fixed host and its own key.
- **Key safety:** `resolve` never lets a job choose where a key goes. The vLLM key is sent only
  to the user-configured origin (scheme, host and port; CORE-SPEC Deviation 9); jobs cannot set
  authentication headers.
- **Runner:** streamed per-image outcomes through an awaited callback, optional critic,
  response records, skip of human-final captions; cancellation drains before returning.
- **Sources and sinks:** local folder, sidecar sink; Hub client with LFS upload and verify,
  imagefolder source and sink.

## Verified live

- **Hub:** upload, LFS verify (each verify before the commit) and download of a private
  synthetic dataset; bytes, hashes and records round-tripped.
- **vLLM on an owned pod:** image caption requests with native structured output from
  Qwen 2.5 VL 3B and Qwen3 VL 8B, key bound to the configured host.
- **Gemini:** one direct request with the shared Caption schema (`gemini-3.8-flash`).
- **Pod agent and RunPod**, through app code compiled with this library: training-event reads
  for FLUX and LTX, and a real pod stop (details in APP-STATUS and POD-STATUS).

## Verified offline only

- **238 Core tests in 34 suites pass**; strict lint and format clean.
- OpenAI, Anthropic and all three gateway routes, including thinking settings and request
  wire formats, against stubbed transports.
- The ChatGPT client: streamed, interrupted, failed, incomplete and malformed responses,
  image and schema bodies, cancellation, usage-limit handling. Independent review accepted it.
- Key routing: outgoing auth headers for matching and different hosts, and sampled ambiguous
  URL inputs (sampled, not an exhaustive parser equivalence).

## Open

- **Live OpenAI, Anthropic and gateway requests.** One gateway key is the default path for
  app users and has not been run against a real gateway.
- **Real ChatGPT-plan inference** needs a user's sign-in.
- **Streaming on a real stream.** The transport now hands the body over as raw bytes and a
  WHATWG server-sent-event parser frames it (CORE-SPEC Transport, Server-sent events), so
  events no longer merge. This is verified offline through `URLSessionTransport` served by a
  `URLProtocol` stub, not against a live ChatGPT or OpenAI stream.
- Parquet-backed Hub datasets are out of scope for v1; imagefolder only.
