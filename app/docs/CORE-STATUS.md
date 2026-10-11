# CORE-STATUS

State of ConceptCore, the Swift captioning library, during the 2026-10-11 overnight integration;
earlier live checks date from lab commit `e620882` (2026-10-10); the approved-video
Gemini proof below is from 2026-10-11. The
contract is [CORE-SPEC.md](CORE-SPEC.md). The day-by-day record is in
[status-history-2026-10-10.md](../../docs/process/status-history-2026-10-10.md).

## What exists

All nine modules of CORE-SPEC, with focused tests:

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

## Overnight extensions

- Category-derived concept defaults and category-aware caption/reviewer instructions preserve
  one shared job contract. A sole style uses whole-image/clip mapping without face identity.
- Local and Hub imagefolder inputs retain clips as clips. `UserContent.video` carries the full
  approved target to direct Gemini and the Pydantic Google gateway route. Unsupported native
  transports reject video before network use; no poster-frame fallback implies motion evidence.
- The LTX video profile describes action over the exact chosen segment. Image and video
  prompts distinguish the attached evidence; video audio is not assumed inspected.
- HEIC/TIFF normalization and editing happen in the app before the core captions a target.
  Only included targets reach publication and training.

## Verified live

- **Hub:** upload, LFS verify (each verify before the commit) and download of a private
  synthetic dataset; bytes, hashes and records round-tripped.
- **vLLM on an owned pod:** image caption requests with native structured output from
  Qwen 2.5 VL 3B and Qwen3 VL 8B, key bound to the configured host.
- **Gemini:** the earlier direct image request and a 2026-10-11 native video request with
  the shared Caption schema (`gemini-3.8-flash`). The exact approved synthetic MP4 contained
  nine frames at 512 × 288; production returned HTTP 200 and a usable Caption, with 4,389
  input / 76 output tokens. A controlled repair added explicit 24 FPS video sampling after
  the default-sampling request returned 400. The private notes receipt at
  `evidence/2026-10-11-video-native-proof/README.md` records all three requests. This
  establishes functional decoding, not caption quality or every-frame observation.
- **Pod agent and RunPod**, through app code compiled with this library: historical training-event
  reads and pod stop; current native model/comparison downloads for both FLUX and LTX with
  matching hashes and offline project reopen. The operator also verified current GPU training,
  resume, generation and stop separately (details in APP-STATUS and POD-STATUS).

## Verified offline only

- **242 Core tests in 35 suites pass** in the current full integration. Native-media and
  category checks include exact video bytes, 24 fps request metadata and unsupported transports.
  Strict lint and format are clean.
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
