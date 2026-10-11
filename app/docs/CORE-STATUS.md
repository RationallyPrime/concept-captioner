# CORE-STATUS

State of ConceptCore, the Swift captioning library, after the 2026-10-11 review repairs;
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
- **Runner:** per-sample outcomes through an awaited callback, optional critic,
  response records, skip of human-final captions; cancellation drains before returning.
- **Sources and sinks:** local folder, sidecar sink; Hub client with LFS upload and verify,
  imagefolder source and sink.

## Overnight extensions

- Category-derived concept defaults and category-aware caption/reviewer instructions preserve
  one shared job contract. Style and motion use whole-target mappings; locator categories
  retain explicit confirmation. The shared Caption schema's usable rule is category-neutral.
- Local and Hub imagefolder inputs retain clips as clips. `UserContent.video` carries the full
  approved target to Gemini routes, OpenRouter and vLLM. Unsupported native
  transports reject video before network use; no poster-frame fallback implies motion evidence.
- The LTX video profile describes action over the exact chosen segment. Image and video
  prompts distinguish the attached evidence; video audio is not assumed inspected.
- HEIC/TIFF normalization and editing happen in the app before the core captions a target.
  Only included targets reach publication and training.
- Actual ChatGPT text deltas flow through an optional app-only progress callback. The runner
  projects the partial caption string for display and clears it on settlement; retries clear
  the previous preview. Only completed, decoded and validated captions reach the sink.
- Python now matches job-relative skill/profile loading and file-name dispatch for mixed Hub
  imagefolders. Both clients cap encoded video requests below 20 MiB, including prompts,
  schema and retry history. Python Gemini/OpenRouter stay on pydantic-ai; its vLLM video route
  is explicitly refused until the library carries that content type.

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

- **260 Core tests in 38 suites pass** in the review-repair integration gate. The Python
  reference suite passes **116 tests** after the mixed-metadata and unrelated-Parquet closures. These are offline
  checks. Native-media and category cases include exact video bytes, 24 fps metadata,
  OpenRouter/vLLM video wire bodies, encoded-size refusal and all seven categories in both
  media modes. Strict lint and format are clean.
- OpenAI, Anthropic and all three gateway routes, including thinking settings and request
  wire formats, against stubbed transports.
- The ChatGPT client: streamed, interrupted, failed, incomplete and malformed responses,
  image and schema bodies, cancellation, usage-limit handling. Actual URLSession SSE deltas
  reach the runner before sidecar creation; retry/failure/cancellation clear the preview.
  Independent source review accepted the media/progress repair.
- Key routing: outgoing auth headers for matching and different hosts, and sampled ambiguous
  URL inputs (sampled, not an exhaustive parser equivalence).

## Open

- Direct OpenAI API-key, Anthropic and other unexercised gateway routes still need live
  acceptance. The owner confirmed native sign-in and live image captioning with ChatGPT and
  OpenRouter on 2026-10-11; [APP-STATUS](APP-STATUS.md#chatgpt-connection-follow-up-2026-10-11)
  also records the production ChatGPT stream fix and live HTTP 200. That acceptance predates
  the new partial-preview hook, whose current proof is offline URLSession-to-runner streaming.
- The newly admitted OpenRouter/vLLM video paths have offline wire/refusal checks, not a new
  live video-provider acceptance claim.
- Parquet-backed Hub datasets are out of scope for v1; imagefolder only.
