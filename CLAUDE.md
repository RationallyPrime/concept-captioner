# concept-captioner — notes for coding sessions

Public repo. Read `docs/v0.2-plan.md` before changing anything under `src/`.

## What this is, in the owner's words

A captioning pipeline for diffusion LoRA training sets where four things are injected, never
hard-wired:

1. **The language model.** Gemini, Claude, GPT, OpenRouter-hosted models, or local inference,
   as the brain behind the captions.
2. **The caption-writing instructions.** An Agent Skill (`SKILL.md` per the Agent Skills
   specification), supplied by the user. The package ships one as a default.
3. **The data source.** Images from a local folder or a Hugging Face dataset.
4. **The output destination.** Captions to local sidecars or back into the originating Hugging
   Face dataset, colocated with the images.

The *shape* of the caption (MiniMax H3 fields, FLUX prose, LTX prose, plain prose, or a user's
own) changes to fit the model being trained; that is the **profile**, a Markdown file in the
skill. An optional **critic** (a second model, on only when the job names a `critic` endpoint)
can reject a caption once with notes. The one mechanical check is that every mapped trigger
appears in the caption and no unmapped trigger does.
Stakes are low: captions get iterated on by running the tool again. Keep the pipeline simple.

## Who decides what

Product direction and design decisions belong to the owner. A session that believes a
requirement, invariant or layout should change writes the proposal down (in the plan or the PR
description) and stops there. It does not implement the change, rename the requirement, or
record its own preference as the project's intent. Routine engineering judgment inside the
stated design is the session's to make.

## Decisions already taken (do not reopen without the owner)

The app's five 2026-10-11 owner decisions are preserved verbatim in
[docs/ADR-LOG.md](docs/ADR-LOG.md). Read them before changing the app or its contracts.
Implementation does not retire a decision; retain it and record any owner-approved
supersession explicitly.

- **pydantic-ai is the model layer.** The injection point is a pydantic-ai model spec string
  (`google:`, `anthropic:`, `openai:`, `openrouter:`, `vllm:`, or any prefix pydantic-ai
  resolves) or a `Model` instance. No hand-rolled provider adapters.
- **Local inference is a vLLM server**, addressed as `vllm:<model>` with a `base_url`. There
  is no in-process transformers path.
- **Instructions follow the Agent Skills spec** and are loaded **eagerly** into the agent's
  instructions. The Harness `Skills` capability was considered and rejected for this use: it
  exposes skills as deferred capabilities the model must choose to load, which is wrong for a
  batch captioner and breaks receipt determinism.
- **Sources and sinks are the package's own protocols** (`ImageSource`, `CaptionSink`). No
  framework owns them.

## Deliberately not in this project (owner's decisions, 2026-10-10)

v0.1 carried machinery the owner has since cut. Do not reintroduce any of it.

- No served-model-vs-requested-model check. The served name may sit in a log; it fails nothing.
- No hash binding, no resume integrity. A caption that already exists is skipped unless
  `--overwrite` is passed; a record with `source: human` is never overwritten. One plain JSON
  response record per captioned image is kept because the owner wants it, not as an audit trail.
- No regex or format checks on caption text. The single exception is the exact-token trigger
  check. The model is trusted to follow the profile; if it does not, the fix is to rerun.
- No claim-ledger critic schema. The critic is `approved` plus `notes`, and it is optional.
- No "no real concept names" rule. Triggers are runtime inputs; example data is synthetic
  because there is nothing else it could be.

## Where this package sits (decided 2026-10-10)

The product is a native macOS app in Swift / SwiftUI, for people with a MacBook on factory
settings; GPUs are rented pods running our own container images; see the plan's "Beyond v0.2"
section. This Python package is the reference implementation and the CLI. Its job file, skill
directory, profile files and response record are the shared contract with the app: keep them
language-neutral, and do not add Python-only features to them.

## Tooling

- Python ≥ 3.11, `src/` layout, `pyproject.toml` with the extra `hf` and a `dev` dependency
  group; each Python project (root, `pod/agent`, `pod/podctl`) commits its `uv.lock`.
- Tool versions (uv, ruff, ty, swiftlint, swiftformat) come from `mise.toml`: `mise install`.
- `uv sync --all-extras`, then `uv run pytest`, `ruff check . && ruff format --check .` and
  `ty check`. ty checks source only, never tests. CI runs them on 3.11–3.13.
- A handful of unit tests, using pydantic-ai's `FunctionModel` / `TestModel` via
  `agent.override(model=…)`. The acceptance test is running the tool against a real provider.

## Layout (v0.2 target)

```
src/concept_captioner/
  job.py          Job / Concept / EndpointSpec (pydantic)
  schemas.py      Caption / Critique (model output types)
  skills.py       Agent Skills loader: SKILL.md (+ named references, profiles/) -> text
  skills/         bundled default skill: SKILL.md + references/profiles/*.md, formerly policy/
  prompt.py       assemble instructions: skill + profile text + job view + task text
  models.py       spec string / EndpointSpec -> pydantic-ai Model + settings + output mode
  stages.py       Captioner Agent (+ trigger output validator) and optional Critic Agent
  runner.py       orchestration: iterate source, caption, write to sink, skip existing
  sources/        ImageSource / CaptionSink: local folder, HF dataset
  cli.py          concept-captioner run | hf | show-prompt | validate
```
