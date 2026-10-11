# concept-captioner

Captions for diffusion LoRA training that put the *concept* in the trigger and everything else in words.

A likeness LoRA, a style LoRA or an object LoRA learns whatever co-occurs with its trigger. If every caption
says `NORA7` and nothing else, the trigger absorbs the hair, the jacket, the lighting and the film grain along
with the face. If the caption describes the hair, the jacket, the lighting and the grain, those attach to their
own words and stay controllable at inference, and the trigger is left holding only what you meant it to hold.

That is the whole idea. This package makes it repeatable, with four things injected rather than hard-wired:

- **the model**: any [pydantic-ai](https://ai.pydantic.dev) model. Gemini, Claude, GPT, anything on OpenRouter,
  or a vLLM server on the GPU that will train the LoRA afterwards;
- **the instructions**: an [Agent Skill](https://agentskills.io/specification) directory (`SKILL.md`). One is
  bundled; point `skill:` at your own;
- **the caption shape**: a *profile*, one Markdown file per target trainer (MiniMax H3 fields, FLUX prose, LTX
  prose, plain prose, or yours);
- **the data**: images from a folder or a Hugging Face dataset; captions to sidecar files or back into the
  dataset as a column, next to the images.

An optional **critic** (a second model, possibly a different family) reviews each caption against the image
and sends it back once with notes. One mechanical check runs on every caption: each mapped trigger appears,
and no unmapped trigger does.

Nothing in the package knows who or what you are training. Triggers, class nouns, boundaries and per-image
subject mappings live in a **job file** you keep next to your data (or inside your dataset repo).

## Install

```bash
pip install concept-captioner            # pydantic-ai with the openai, google, anthropic and openrouter extras
pip install "concept-captioner[hf]"      # + datasets, huggingface_hub
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
  captioner: { kind: google, model: gemini-3.8-flash }
  critic:    { kind: vllm,   model: Qwen/Qwen3-VL-32B-Instruct, base_url: http://localhost:8000/v1 }
```

```bash
export GOOGLE_API_KEY=...
concept-captioner run job.yaml --images ./crops --out ./captions
```

You get `captions/0001.txt` (the caption), `captions/0001.json` (the model's response, the critic's verdict,
which models served the calls) and `captions/_summary.json`. Rerunning skips samples that already have a
caption; `--overwrite` redoes them; `--only 0002.png` redoes one.

## Models

`kind` in the job, or the `--endpoint` string, is a pydantic-ai `provider:model` spec:

| spec | key |
| --- | --- |
| `google:gemini-3.8-flash` | `GOOGLE_API_KEY` |
| `anthropic:claude-opus-5-5` | `ANTHROPIC_API_KEY` |
| `openai:gpt-5.2` | `OPENAI_API_KEY` |
| `openrouter:anthropic/claude-sonnet-4-6` | `OPENROUTER_API_KEY` (one key, every model) |
| `vercel:anthropic/claude-sonnet-5-5` | `VERCEL_AI_GATEWAY_API_KEY` (Vercel AI Gateway; one key, every model) |
| `gateway/anthropic:claude-sonnet-5-5` | `PYDANTIC_AI_GATEWAY_API_KEY` (Pydantic AI Gateway; also `gateway/google:`, `gateway/openai:`) |
| `vllm:Qwen/Qwen3-VL-32B-Instruct` | `VLLM_BASE_URL` (or `base_url:` in the job), `VLLM_API_KEY` if the server wants one |
| any other pydantic-ai prefix | that provider's variable |

Keys are read by pydantic-ai from the environment. They are never job fields. If you would rather
hold one key than four, a gateway (OpenRouter, Vercel AI Gateway, Pydantic AI Gateway) reaches every
model with a single key; the gateway's host is fixed in code and cannot be changed by a job file. `kind: vllm` is
the kind for *any* OpenAI-compatible server you point at with `base_url` (vLLM, SGLang, Ollama,
a proxy); `kind: openai` always means api.openai.com and refuses a `base_url`, so a job file you
downloaded can never send your OpenAI key somewhere else. A custom `base_url` must be https, or
http only to localhost, a private address or a bare hostname such as a Docker service name.
The stored `VLLM_API_KEY` is sent only when the endpoint's host matches the host in the
user's `VLLM_BASE_URL`; other custom hosts receive no key. Job settings cannot supply
authentication headers or override the HTTP Host header.

Per endpoint you can also set `output_mode` (`native` default: the provider enforces the JSON schema;
`prompted` for a server that rejects schema-constrained decoding; `tool` for models that prefer tool calls),
`settings` (anything pydantic-ai's `ModelSettings` takes: `temperature`, `seed`, `max_tokens`, vLLM
`extra_body`), and `concurrency`. `captioner_thinking` / `critic_thinking` on the job set the thinking level.

### Running on the GPU that will train

```bash
vllm serve Qwen/Qwen3-VL-32B-Instruct --port 8000 --max-model-len 16384
export VLLM_BASE_URL=http://localhost:8000/v1
concept-captioner run job.yaml --images crops --out captions \
    --endpoint vllm:Qwen/Qwen3-VL-32B-Instruct
pkill -f "vllm serve"        # VRAM back; launch your trainer on captions/
```

For MiniMax H3 this has a side benefit: Qwen3-VL is the family of H3's own text encoder, so the captions arrive
in the encoder's vocabulary.

## Skills and profiles

The instructions are an Agent Skill directory:

```
my-captioning-skill/
  SKILL.md                    # frontmatter: name, description, metadata; body: the captioning policy
  references/
    profiles/
      h3-still.md             # a profile: the trainer's caption shape, with worked examples
      my-trainer.md
    glossary.md               # inlined only if metadata.references names it
```

`skill:` in the job (or `--skill`) points at the directory; omit it for the bundled
`diffusion-training-captioner`. `profile:` (or `--profile`) names a file under `references/profiles/`, or is a
path to any `.md`. The bundled profiles are `h3-still`, `flux-image`, `ltx-image`, `ltx-video` and `plain`.

The skill body is loaded in full on every call, followed by the profile, your job's `policy_overrides`, the
job's view of the sample (only the mapped concepts and their locators) and a short response contract. `concept-
captioner show-prompt job.yaml 0001.png` prints exactly what the captioner sees; `--critic` prints the critic's.

The bundled skill is the *Diffusion Training Captioner* policy: what belongs to a trigger, how to bind subjects,
what counts as a nuisance attribute, with H3, FLUX and LTX format references. See `examples/skill-example/`
for the smallest useful user skill.

## Hugging Face datasets

```bash
export HF_TOKEN=hf_...                         # or `hf auth login`
concept-captioner run job.yaml --repo you/faces                   # caption and push the column back
concept-captioner run job.yaml --repo you/faces --out captions    # dataset in, sidecars out
concept-captioner run job.yaml --images crops --to-repo you/faces # folder in, new dataset out
concept-captioner hf pull --repo you/faces --to crops             # just download the images
concept-captioner hf push-job job.yaml --repo you/faces           # keep the job with the data
concept-captioner hf fetch-job --repo you/faces --to job.yaml
```

A dataset sink writes `caption` and `caption_response` columns (names via `--caption-column`). Sample ids come
from `--id-column`, else `file_name`/`id`, else the row index; map them in `job.samples` like filenames.

## The job file

| field | meaning |
| --- | --- |
| `skill` | skill directory; omit for the bundled one |
| `profile` | profile name in the skill, or a `.md` path |
| `concepts[]` | `trigger`, `class_noun`, `target_concept`, `traits_to_learn`, `attributes_to_describe`, `explicit_boundary_decisions` |
| `samples{}` | sample id → `{trigger: locator sentence}` or `null` (held for review) |
| `single_subject_only` | tells the captioner any second person makes a sample unusable |
| `endpoints` | `captioner` and optional `critic`; CLI flags override |
| `captioner_thinking` / `critic_thinking` | `none` … `xhigh` |
| `policy_overrides{}` | extra instruction sections appended after the profile |

Locator sentences ("the woman on the left") bind a trigger to its subject. A sole style concept
can be assigned to the whole training target; it does not require a face locator. They are never
guessed; an unmapped sample is `needs_mapping` and costs no model call. `--dry-run` lists them.

## Project folder

The CLI and the macOS app in `app/` (ConceptStudio) use one project layout on disk:

```
my-project/
  job.yaml              the job file
  images/               included training images or clips, each with its sidecars
    0001.png
    0001.txt            the caption
    0001.json           the response record (models, critic verdict, or source: human)
  skill/<name>/         optional: a custom skill, copied in; job.yaml says skill: ./skill/<name>
                        (no skill key means the bundled default)
  references/           app only: reference images for subject concepts; never published
  results/<run-id>/     app only: a trained LoRA, when it was downloaded rather than pushed
  .conceptstudio/       app only: app settings, saved runs, excluded media, edit backups and caches; never published
```

Either tool can pick up where the other left off: `concept-captioner run job.yaml --images images
--out images`, run from the project folder, captions the same project the app opens, and each
reads the captions and records the other wrote. Neither overwrites a record with
`source: human`. The job file, skill directory, profile files and response record are the
shared contract; neither side adds fields the other cannot read. Publishing from the app pushes
the images and sidecars to the dataset root with `concept-captioner/job.yaml` and, beside it, the
project's skill folder; reference faces and `.conceptstudio/` never leave the Mac. The app resolves a
relative `skill:` against the job file's folder and the CLI against the working directory, so
run the CLI from the project folder.

Where things stand: [app](app/docs/APP-STATUS.md), [Swift core](app/docs/CORE-STATUS.md),
[pod](pod/docs/POD-STATUS.md).

## What happens per training sample

1. The captioner gets the instructions and the image (resized under provider limits and re-encoded, which
   drops EXIF) and returns `{caption, usable, note}`. If a mapped trigger is missing or an unmapped one appears,
   pydantic-ai sends that back and the model gets one more try.
2. If a critic is configured it reviews the caption against the image. On rejection the captioner gets the
   notes as the next turn of the same conversation and tries once more; the critic reviews again.
3. The caption is written, or the sample ends `unusable` / `rejected` / `failed` with its record and no caption.

Video inputs carry the complete selected clip to a video-capable captioning provider; a poster
frame is not a substitute. The app prepares exact segments and uses the LTX video profile.
Local and Hub imagefolder sources retain media bytes. The Python tabular Hub path supports
pure video columns with `datasets.Video(decode=False)`; mixed image/video tabular output is
rejected explicitly. The native app's mixed imagefolder workflow remains supported.

## Library use

```python
import asyncio
from concept_captioner import Job, Runner, resolve, LocalFolderSource, SidecarSink

job = Job.load("job.yaml")
runner = Runner(
    job=job,
    captioner=resolve("google:gemini-3.8-flash", thinking=job.captioner_thinking),
    critic=resolve("anthropic:claude-opus-5-5", thinking=job.critic_thinking),
)
summary = asyncio.run(runner.run(LocalFolderSource("crops"), SidecarSink("captions")))
print(summary.counts())
```

`runner.stream(source, sink, only=[...])` yields each sample's outcome as it finishes.

## Provenance

The bundled skill descends from the *Diffusion Training Captioner* standalone instructions (2026-10-09); its
`references/sources.md` lists what was read. v0.1 of this package had hand-written provider adapters, a
claim-ledger critic and hash-bound receipts; v0.2 replaced the adapters with pydantic-ai, made the instructions
an injectable skill, and removed the rest.

MIT licensed.
