# concept-captioner

Captions for diffusion LoRA training that put the *concept* in the trigger and everything else in words.

A likeness LoRA, a style LoRA or an object LoRA learns whatever co-occurs with its trigger. If every caption
says `NORA7` and nothing else, the trigger absorbs the hair, the jacket, the lighting and the film grain along
with the face. If the caption describes the hair, the jacket, the lighting and the grain, those attach to their
own words and stay controllable at inference, and the trigger is left holding only what you meant it to hold.

That is the whole idea. This package makes it repeatable:

- a **shared concept policy** (what belongs to a trigger, how to bind subjects, what counts as nuisance), with an
  explicit per-concept boundary you declare in the job;
- an **injectable caption profile** (the trainer's grammar: MiniMax H3 three-field stills, FLUX prose, LTX prose,
  plain prose, or your own from a directory);
- an **injectable model endpoint** (Gemini, any OpenAI-compatible server such as vLLM on your own GPU, or an
  in-process `transformers` model), so the same pipeline runs against a hosted API or an open-weights VLM on the
  pod that trains the LoRA afterwards;
- a **critic** that audits every caption against the image with a claim ledger and fails the sample on identity
  bleed, unbound subjects, invented detail or quoted text, and can run on a different model family than the
  captioner;
- **Hugging Face datasets in and out**, so anyone with a token can pull a dataset, caption it, and push the
  captions back as a column.

Nothing in the package knows who or what you are training. Triggers, class nouns, boundaries and per-image
subject mappings live in a **job file** you keep next to your data (or inside your dataset repo).

## Install

```bash
pip install concept-captioner              # core: pydantic, pyyaml, pillow, httpx
pip install "concept-captioner[gemini]"    # + google-genai
pip install "concept-captioner[hf]"        # + datasets, huggingface_hub
pip install "concept-captioner[local]"     # + torch, transformers (in-process VLM)
```

## Sixty-second tour

`job.yaml`:

```yaml
profile: h3-still
concepts:
  - trigger: NORA7
    class_noun: woman
    target_concept: facial_identity
    explicit_boundary_decisions:
      facial_geometry: Reserve for the trigger; do not describe facial morphology.
      eye_color: Reserve for the trigger.
      hair_color_and_styling: Describe visible presentation, including color.
samples:
  0001.png: { NORA7: "The only person in the crop." }
  0002.png: { NORA7: "The woman on the left; the man on the right has no trigger." }
  0003.png: null        # held for review until you map it; never guessed
endpoints:
  captioner: { kind: gemini, model: gemini-3.8-flash }
  critic:    { kind: openai, model: Qwen/Qwen3-VL-32B-Instruct, base_url: http://localhost:8000/v1 }
```

```bash
export GEMINI_API_KEY=...
concept-captioner run job.yaml --images ./crops --out ./captions
```

You get `captions/0001.txt`, `captions/_receipts/0001.json` (every attempt, both models' raw responses, the
critic's claim ledger) and `captions/_summary.json`.

## The pipeline

```
ImageSource ──▶ Captioner ──▶ mechanical validation ──▶ Critic ──▶ CaptionSink
   (folder,        (endpoint      (trigger present,        (endpoint     (sidecars,
    HF dataset)    + profile)      format, counts,          + profile)    HF column)
                                   quoted text)
```

A caption is committed only when:

1. the captioner's structured reply validates and the caption passes the profile's format check, every mapped
   trigger appears exactly, and no unmapped trigger appears;
2. the critic approves it with a **non-empty claim ledger** in which every claim is verified, and all of these are
   false: `concept_boundary_violation`, `unsupported_inference`, `subject_ambiguity`, `image_caption_mismatch`,
   `another_person_described_as_trigger`, `trigger_subject_visible_but_unbound`, `quoted_text_present`;
3. the model that **served** each call is the model that was **requested** (`require_model_match`, default on).
   A provider silently downgrading your critic to a lite preview is a failed sample, not a log line.

Failures feed back into the next attempt as codes; after `max_caption_attempts` the sample is `needs_review`
with its receipt, and nothing is written to the caption slot.

## ModelEndpoint

One coroutine, provider-neutral types:

```python
class ModelEndpoint(Protocol):
    name: str
    model: str
    capabilities: Capabilities          # images, structured_output, thinking, seed, max_images
    async def describe(self, request: Request) -> Response: ...
```

`Request` carries system text, user text, in-memory `ImageRef`s (never paths; the pipeline sends a
metadata-stripped derivative), an optional pydantic `response_schema`, and a `thinking` hint. `Response` carries
the text, the parsed schema object, `requested_model` **and** `served_model`, usage, latency, a request hash and
the raw provider payload for receipts.

Cross-cutting behaviour is composition, not inheritance:

```python
Retrying(RateLimited(Recording(SchemaEnforcer(GeminiEndpoint("gemini-3.8-flash")))))
```

`SchemaEnforcer` gives structured output to backends without constrained decoding (prompt-side schema, parse,
validate, retry with the error quoted back). `Recording` writes one receipt per call. `build_endpoint(spec)`
assembles the stack from a spec string:

| spec | adapter |
| --- | --- |
| `gemini:gemini-3.8-flash` | `google-genai`, native JSON schema, thinking levels |
| `openai:http://localhost:8000/v1#Qwen/Qwen3-VL-32B-Instruct` | any `/v1/chat/completions`: vLLM, SGLang, Ollama, OpenRouter, OpenAI |
| `transformers:Qwen/Qwen3-VL-8B-Instruct` | in-process, no server |
| `fake:name` | deterministic, for tests |

Adding a provider is one class with `describe()` and a `register("kind", factory)` call.

### Running on the GPU that will train

```bash
vllm serve Qwen/Qwen3-VL-32B-Instruct --port 8000 --max-model-len 16384
concept-captioner run job.yaml --images crops --out captions \
    --endpoint "openai:http://localhost:8000/v1#Qwen/Qwen3-VL-32B-Instruct" \
    --critic-endpoint "openai:http://localhost:8000/v1#Qwen/Qwen3-VL-32B-Instruct"
pkill -f "vllm serve"        # VRAM back
# ... launch your trainer on captions/ ...
```

For MiniMax H3 this has a side benefit: Qwen3-VL is the family of H3's own text encoder, so the captions arrive
in the encoder's vocabulary.

## CaptionProfile

A profile is the trainer's grammar and nothing else:

```python
class CaptionProfile(Protocol):
    name: str
    media: str
    def format_instructions(self) -> str: ...   # prompt section
    def examples(self) -> str: ...              # prompt section
    def check(self, caption: str) -> FormatCheck: ...   # failures + unwrapped body
    def wrap(self, body: str) -> str: ...
```

Built-ins: `h3-still`, `flux-image`, `ltx-image`, `plain`. A user profile is a directory:

```
my-trainer/
  profile.yaml     # name, media, optional wrapper "{body}", optional regex `pattern` with a (?P<body>) group, `forbid`
  format.md        # what the captioner must follow
  examples.md      # worked examples (fictional)
```

```bash
concept-captioner run job.yaml --images crops --out captions --profile ./my-trainer
```

The concept policy itself (`src/concept_captioner/policy/core.md`) is shared by every profile. It is the
format-agnostic half of the *Diffusion Training Captioner* skill; the H3 and FLUX/LTX halves are in sibling
files that the built-in profiles pull from.

## Hugging Face datasets

```bash
export HF_TOKEN=hf_...                         # or `huggingface-cli login`
concept-captioner hf pull --repo you/faces --to crops           # images to a folder
concept-captioner hf run job.yaml --repo you/faces \
    --endpoint gemini:gemini-3.8-flash --caption-column caption  # caption and push the column back
concept-captioner hf push-job job.yaml --repo you/faces          # keep the job with the data
concept-captioner hf fetch-job --repo you/faces --to job.yaml
```

`hf run` reads any dataset with an image column, writes `caption` and `caption_receipt` columns, and pushes to the
same repo or `--target-repo`. Sample ids come from `--id-column`, else `file_name`/`id`, else the row index; map
them in `job.samples` the same way as filenames.

## The job file

| field | meaning |
| --- | --- |
| `profile` | built-in name or profile directory |
| `concepts[]` | `trigger`, `class_noun`, `target_concept`, `traits_to_learn`, `attributes_to_describe`, `explicit_boundary_decisions` |
| `samples{}` | sample id → `{trigger: locator sentence}` or `null` (held for review) |
| `single_subject_only` | any second person makes a sample unusable |
| `endpoints` | `captioner` and optional `critic` specs; CLI flags override |
| `captioner_thinking` / `critic_thinking` | `none` … `high`; the critic defaults to `high` |
| `require_model_match` | fail on served ≠ requested (default true) |
| `minimum_caption_words`, `max_caption_attempts` | thresholds |
| `policy_overrides{}` | extra policy sections appended to the prompt |

Locator sentences ("the woman on the left") are how the captioner binds a trigger to a face. They are never
guessed; an unmapped sample is `needs_mapping` and costs no provider call. `concept-captioner run --dry-run`
lists them.

## Receipts

`_receipts/<id>.json` binds the result to the image bytes (SHA-256), the exact prompt and schemas (policy hash),
both model ids, and records every attempt: captioner response, validation codes, critic response with its claim
ledger, and which model actually served each call. `--receipts calls.jsonl` additionally logs one line per
provider call. A rerun against the same output directory keeps a committed caption only if its receipt still
binds; a changed image or job fails that sample rather than overwriting.

## Security

- Credentials are read from the process environment only (`GEMINI_API_KEY`, `OPENAI_API_KEY`, `HF_TOKEN`). They
  are never config fields and never appear in receipts; provider errors are classified to a code and redacted.
- Images are re-encoded in memory with EXIF/IPTC/XMP removed (ICC kept) before leaving the machine.
- Gemini requests set `store: false`.

## Library use

```python
import asyncio
from concept_captioner import Job, Runner, build_endpoint, load_profile, LocalFolderSource, SidecarSink

job = Job.load("job.yaml")
runner = Runner(
    job=job,
    profile=load_profile(job.profile),
    captioner_endpoint=build_endpoint("gemini:gemini-3.8-flash"),
    critic_endpoint=build_endpoint("openai:http://localhost:8000/v1#Qwen/Qwen3-VL-32B-Instruct"),
)
summary = asyncio.run(runner.run(LocalFolderSource("crops"), SidecarSink("captions")))
print(summary.counts())
```

## Provenance

The policy text descends from the *Diffusion Training Captioner* standalone instructions (2026-10-09) and the
`people_lora_corpus` pipeline, whose captioner/critique split, receipt binding and credential boundary this
package keeps. What changed: the endpoint and profile seams, the claim-ledger critic with the two flags a yes/no
critic cannot express, served-model verification as a failure condition, and Hugging Face as a first-class source
and sink.

MIT licensed.
