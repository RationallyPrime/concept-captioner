# concept-captioner CLI

The Python package is the command-line and reference implementation used alongside the native macOS app, ConceptStudio. Both use the same `job.yaml`, skill/profile files, captions and response-record sidecars. Use the CLI for Python workflows, scripted captioning, prompt inspection, and Hugging Face dataset input/output; use ConceptStudio for the native project workflow, media review and editing, exact video-segment preparation, publishing, and GPU training.

Captioning is a conditioning strategy, not a guarantee of disentanglement. The prompts describe observable attributes outside the intended concept boundary and place the exact trigger in the caption, but correlations in a dataset can still confound what a LoRA learns. The CLI does not prove that a model learned the intended boundary or measure adapter quality.

## Install from a checkout

Python 3.11 or newer is required. The project is not yet published on PyPI. Clone or otherwise obtain this repository, then install its editable package with the repository's existing `uv` workflow:

```sh
cd concept-captioner
uv venv --python 3.11

# CLI and local-folder support:
uv pip install -e .

# Or, instead, add the optional Hugging Face dataset commands:
uv pip install -e '.[hf]'

source .venv/bin/activate
concept-captioner --help
```

Choose one of the two install commands. For repository development and tests, the project workflow is `uv pip install -e ".[dev,hf]"`. The `hf` extra installs `datasets` and `huggingface_hub`; local-folder use needs no extra.

## Quick start

A job describes the concept, where its trigger applies in each sample, the caption profile, and the model endpoints. The repository includes a fictional example at [examples/job.example.yaml](../examples/job.example.yaml). Copy it beside your real data and replace every example choice with your own.

```yaml
profile: h3-still

concepts:
  - trigger: NORA7
    class_noun: woman
    target_concept: facial_identity
    attributes_to_describe:
      - clothing and removable accessories
      - hair presentation
      - expression and gaze
      - pose
      - setting
      - lighting
      - framing and visible image treatment

samples:
  0001.jpg:
    NORA7: The only person in the crop.
  0002.jpg: null # held for review; no model request is made

endpoints:
  captioner:
    kind: google
    model: your-google-model
```

Set the provider credential in the environment, then validate and run:

```sh
export GOOGLE_API_KEY=...
concept-captioner validate job.yaml
concept-captioner run job.yaml --images ./images --out ./images
```

The local source accepts PNG, JPEG, WebP, MP4, MOV and M4V files in one folder (not recursively). It uses each media file's filename as its sample id and writes `<stem>.txt` captions plus `<stem>.json` response records. It rejects colliding file stems because their sidecars would be ambiguous.

Useful commands:

```sh
# Inspect mappings and the selected instructions without a model call.
concept-captioner run job.yaml --images ./images --out ./images --dry-run
concept-captioner show-prompt job.yaml 0001.jpg
concept-captioner show-prompt job.yaml 0001.jpg --critic

# Process a selected sample. --only selects work; --overwrite allows an existing
# model caption to be replaced. A human-final record is always protected.
concept-captioner run job.yaml --images ./images --out ./images \
  --only 0001.jpg --overwrite
```

`validate` checks the job, skill and profile. `show-prompt` prints the instructions for one mapped sample. `run --dry-run` lists the source count, mapped count, and samples that need mapping; it does not call a model. Captioning requires at least one concept. A draft job may have no concepts and can still be loaded or validated, but it cannot start a captioning run.

A sample with no mapping is reported as `needs_mapping` and receives no model request. If a caption already exists, it is skipped unless `--overwrite` is set. `--only ID...` restricts the run to those sample ids; to re-caption an existing model result, use it together with `--overwrite`. A response record with `"source": "human"` is final and remains skipped even when overwriting.

A run reports counts and per-sample statuses such as `written`, `skipped`, `needs_mapping`, `unusable`, `rejected` and `failed`. The JSON response record stores the requested/served models, attempts, requests and optional critic result. The only mechanical caption check is whole-token presence of mapped triggers and absence of unmapped triggers; the CLI does not semantically verify the rest of the caption.

An optional critic reviews the caption against the same media. If it rejects the caption, the captioner gets its notes and makes one revision, which the critic reviews again. A second rejection writes a response record without a new caption. A local run also writes `_summary.json` in the output folder.

## Models and endpoints

The job's `endpoints.captioner` is required for `run` unless `--endpoint` supplies an override. An optional `endpoints.critic` runs a second model review; `--critic-endpoint` overrides it. Endpoint specs use pydantic-ai's `provider:model` form.

| Job `kind` | Credential or endpoint |
| --- | --- |
| `google` | `GOOGLE_API_KEY` |
| `anthropic` | `ANTHROPIC_API_KEY` |
| `openai` | `OPENAI_API_KEY`; this kind is pinned to api.openai.com |
| `openrouter` | `OPENROUTER_API_KEY` |
| `vercel` | `VERCEL_AI_GATEWAY_API_KEY` |
| `gateway/<upstream>` | `PYDANTIC_AI_GATEWAY_API_KEY`; only the upstreams supported by pydantic-ai and this package are accepted |
| `vllm` | `base_url` in the endpoint or `VLLM_BASE_URL`; optional `VLLM_API_KEY` |

Hosted providers read credentials from their environment variables. Credentials are not job fields. For an OpenAI-compatible server other than api.openai.com, use `kind: vllm` and `base_url`. Custom URLs must use HTTPS, or HTTP to a loopback/private/link-local address, a single-label service hostname, a `.local`/`.internal` hostname, or `localhost.localdomain`. The saved `VLLM_API_KEY` is sent only when the destination origin matches the origin configured in `VLLM_BASE_URL`; a job-specified different host receives no authorization header.

An endpoint may also set `output_mode` (`native`, `prompted` or `tool`), pydantic-ai `settings`, and `concurrency` (1–64; default 4). `captioner_thinking` and `critic_thinking` accept `none`, `minimal`, `low`, `medium`, `high` or `xhigh`. CLI endpoint flags replace the matching job endpoint; other job settings remain in effect.

### Caption on the GPU that will train

On a machine with vLLM installed and enough GPU memory for the chosen vision model, start
the server in one terminal. This is an example model; vLLM is installed separately from this CLI:

```sh
vllm serve Qwen/Qwen3-VL-32B-Instruct --port 8000 --max-model-len 16384
```

In a second terminal on that machine, with the CLI environment active:

```sh
export VLLM_BASE_URL=http://localhost:8000/v1
concept-captioner run job.yaml --images ./images --out ./images \
  --endpoint vllm:Qwen/Qwen3-VL-32B-Instruct
```

After captioning finishes, press **Ctrl-C** in the server terminal and wait for it to exit
before starting training on the same GPU. This releases the captioning model's GPU memory.
For ConceptStudio-managed pods, use the app's GPU controls and the [pod guide](../pod/README.md).

## Skills and profiles

The bundled skill is [Diffusion Training Captioner](../src/concept_captioner/skills/diffusion-training-captioner/SKILL.md). It defines the captioning policy and may include named references. A custom skill is a directory containing a `SKILL.md`; see [the example skill](../examples/skill-example/).

The bundled profile files are:

- `h3-still` and `h3-video` — MiniMax H3 caption field formats for still targets and video clips.
- `flux-image` — FLUX image captions.
- `ltx-image` and `ltx-video` — LTX image and video captions.
- `plain` — descriptive prose without a trainer-specific wrapper.

Profiles describe caption shape; selecting a profile does not establish that a provider can inspect that media or that a trainer accepts that target. The profile names resolve to files under `references/profiles/` in the selected skill. Set `profile:` in the job, or pass `--profile`; a `.md` path can point at a custom profile. Use `skill:` or `--skill` to choose a skill directory.

The skill body is loaded with any explicitly named references, followed by the profile, `policy_overrides`, the mapped concepts and locators for the sample, and the response contract. The entire instruction set is supplied on each call. Use `show-prompt` to inspect the exact captioner or critic instructions for one sample; it does not print the media, user turn or provider output schema.

## Job fields and path resolution

| Field | Meaning |
| --- | --- |
| `skill` | Skill directory; omitted or null selects the bundled skill. |
| `profile` | Profile name in the skill, or a Markdown path. |
| `concepts[]` | One or more trigger definitions: `trigger`, `class_noun`, `target_concept`, `traits_to_learn`, `attributes_to_describe`, and `explicit_boundary_decisions`. Empty is valid for a draft; captioning requires a concept. |
| `samples{}` | Sample id → trigger-to-locator mapping, or `null` to hold it for mapping review. |
| `single_subject_only` | Asks the captioner to mark a sample unusable if it contains another person. |
| `endpoints` | Required `captioner` endpoint and optional `critic`; CLI endpoint flags override them. |
| `captioner_thinking` / `critic_thinking` | Provider thinking level. |
| `policy_overrides{}` | Additional instruction sections appended after the profile. |

A locator such as “the woman on the left” binds a trigger to its subject. The CLI never guesses a missing mapping. A sole style concept can describe the whole training target, but the job still needs a mapping entry for each sample to caption it.

When loaded with `Job.load("path/to/job.yaml")`, Python retains the job file's directory as loading context. Relative paths written in the job for `skill` and a Markdown `profile` resolve from that folder, even if the CLI is run elsewhere. Explicit CLI paths (`--skill DIR` and `--profile path/to/file.md`) resolve from the current working directory; a simple profile name still selects a file under the chosen skill. This lets a project keep its skill and profile beside its own `job.yaml`, while a one-off path override can be relative to the command being run.

## Hugging Face datasets

Install the `hf` extra and authenticate with `HF_TOKEN` or `hf auth login`. The `--repo` option reads a dataset. Without `--out`, it writes caption and response-record columns back to that dataset; with `--out`, it writes local sidecars instead. Use `--to-repo` to build a new dataset from a local image folder.

```sh
export HF_TOKEN=hf_... # or run: hf auth login

# Read a dataset and write caption / caption_response columns back.
concept-captioner run job.yaml --repo you/faces

# Read a dataset but write local sidecars.
concept-captioner run job.yaml --repo you/faces --out ./captions

# Build a dataset from a local image folder.
concept-captioner run job.yaml --images ./images --to-repo you/faces

# Download the images from a dataset.
concept-captioner hf pull --repo you/faces --to ./images

# Keep the job with the dataset under concept-captioner/job.yaml.
concept-captioner hf push-job job.yaml --repo you/faces
concept-captioner hf fetch-job --repo you/faces --to job.yaml
```

For tabular datasets, `--split`, `--image-column` and `--id-column` select the input. Sample ids use the chosen id column, then a `file_name`, `filename`, `image_id`, `id` or `name` field when present, and otherwise the row index. Put those ids in `job.samples`. The default caption column is `caption`; `--caption-column` also names the response record column, which is `<caption-column>_response`.

The Hub source supports imagefolder media and tabular image columns. Tabular `datasets.Video(decode=False)` input is supported for video datasets; a local-folder-to-Hub output cannot mix still images and clips in a tabular dataset. The native app has a separate mixed imagefolder publishing flow. Use `--no-push` to avoid the final Hub push; it does not write a local output directory by itself.

## Shared project folder

The CLI and ConceptStudio use the same project layout and file contract:

```text
my-project/
  job.yaml              concepts, per-sample mappings, skill/profile and endpoints
  images/
    0001.png
    0001.txt            caption
    0001.json           response record, including source: human for final edits
  skill/<name>/         optional project-owned custom skill
  references/           ConceptStudio only: reference images; never published
  results/<run-id>/     ConceptStudio only: downloaded training result
  .conceptstudio/       ConceptStudio only: local settings, caches and edit backups
```

Both tools can continue the same local captioning work: from the project folder, run `concept-captioner run job.yaml --images images --out images`. They read the same job, skills, profile files, captions and response records. Python does not read ConceptStudio's references or app-local files. Neither tool overwrites a response record marked `"source": "human"`. The app resolves its job-defined skill and profile paths from `job.yaml` too. When ConceptStudio publishes a dataset, it includes approved project media and sidecars, `concept-captioner/job.yaml`, and the project's skill folder; local reference images and `.conceptstudio/` files stay on the Mac.

## Video inputs and native-app limits

The CLI accepts video files as samples and sends the actual clip bytes on supported video provider routes; a still frame is not sent in their place. In Python, the Gemini and OpenRouter routes (and the Google gateway routes) are video-enabled when the selected model accepts video. The pydantic-ai vLLM route currently refuses video, even though the native app has a video-capable vLLM route. Python refuses unsupported video routes before sending. Video requests of 20 MiB or more, including the encoded clip and request instructions/schema, are refused.

Choose `h3-video` or `ltx-video` to shape a caption for a video target. The Python CLI treats the file you provide as the target; it does not cut, preview or approve an exact segment. For an H3 or LTX training target, prepare the exact segment in ConceptStudio, inspect it, and caption the resulting file.

ConceptStudio's video editor ties segment constraints to the selected training model. LTX accepts 9–257 frames in steps of eight (`8n+1`); H3 accepts 5–243 frames in steps of seventeen (`17n+5`) at exactly 24 fps. LTX training refuses selected portions with variable frame timing; H3 refuses frame rates other than 24 fps. The app writes the exact approved segment used by captioning and training. Native video caption routes include Gemini, OpenRouter and vLLM when the chosen model supports video; OpenAI and Anthropic routes refuse video. Provider-route support does not guarantee that every model on that route accepts clips.

Read [ConceptStudio's running guide](../app/docs/RUNNING.md) for the native workflow, [its current status](../app/docs/APP-STATUS.md), and the [shared Python/Swift contract](../app/docs/CORE-SPEC.md).

## Python API

The library API composes the same job, model, source and sink used by the CLI:

```python
import asyncio

from concept_captioner import Job, LocalFolderSource, Runner, SidecarSink, resolve

job = Job.load("job.yaml")
runner = Runner(
    job=job,
    captioner=resolve("google:your-google-model", thinking=job.captioner_thinking),
)
summary = asyncio.run(
    runner.run(LocalFolderSource("images"), SidecarSink("images"))
)
print(summary.counts())
```

An optional critic can be added with `resolve(...)` and `critic=`. `Runner.stream(source, sink, only=[...])` yields each sample outcome as it completes. A source implements `ImageSource`; a sink implements `CaptionSink`. For Hub work, import `HFDatasetSource` and `HFDatasetSink` from `concept_captioner.sources.hf`; those require the optional `hf` extra.

## Provenance

The bundled skill descends from the *Diffusion Training Captioner* standalone instructions
(2026-10-09); [its source notes](../src/concept_captioner/skills/diffusion-training-captioner/references/sources.md)
record what was read. Version 0.1 used hand-written provider adapters, a claim-ledger critic and
hash-bound receipts. Version 0.2 replaced the adapters with pydantic-ai, made the instructions
an injectable skill, and removed the ledger and receipts. The accepted boundaries remain in
[the architecture decision log](ADR-LOG.md) and [repository instructions](../CLAUDE.md).

For the repository overview, see [README](../README.md).
