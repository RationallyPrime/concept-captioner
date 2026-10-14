# Model table

The supported training models are the rows of one JSON file. The app and the pod read the same
file, so a model is added in one place.

The file is `app/Sources/ConceptStudio/Resources/Training/model-table.json`. The app bundles it
(`Bundle.module`, subdirectory `Training`). Both pod images `COPY` it to
`/opt/pod/scripts/model-table.json`; `pod/scripts/model_table.py` reads that path when it exists,
and otherwise the file in the repository checkout. Wrapper scripts and the agent load
`model_table.py` by path.

Code does not branch on a model's name. Where a model genuinely behaves differently, its row
names a **hook** (see [Hooks](#hooks)). Code may still branch on the trainer (`aitoolkit`, `ltx`):
each has its own image, services, launcher and checkpoint layout.

## Format

```json
{
  "format": "conceptstudio-model-table",
  "version": 1,
  "default_model": "flux1-dev",
  "trainers": { "aitoolkit": {...}, "ltx": {...} },
  "models": [ row, row, ... ]
}
```

| Field | Meaning |
| --- | --- |
| `format`, `version` | `conceptstudio-model-table`, `1`. |
| `default_model` | Row id a new project and an unknown caption profile start with. |
| `trainers.<name>.min_cuda` | Lowest host CUDA the trainer image needs, as `major.minor`. |
| `trainers.<name>.default_model` | Row selected when the trainer changes, and the row a custom base model on that trainer borrows its defaults from. |
| `models` | Rows. Order is the picker order, the order of video formats in the media editor, the order of names in messages and the order of family matching. |

Every row field is required unless marked optional; `null` is written where a field does not
apply.

| Row field | Meaning |
| --- | --- |
| `id` | Row id, used inside the table. |
| `display_name`, `short_name` | Names in pickers and messages (`FLUX.1-dev` / `FLUX`). |
| `trainer` | `aitoolkit` or `ltx`. |
| `model_ref` | The `base_model` value in run.json, a Hub id. Unique across the table. |
| `source.revision` | Pinned Hub revision, or `null` when the trainer resolves the name itself. |
| `source.gated` | The Hub repo needs an accepted licence before a token can download it. |
| `source.first_download_gb` | Size of the first model download on a fresh volume, decimal GB. Shown in the picker for rows whose licence notice is on. |
| `source.download_note` | What that size covers. |
| `architecture.arch` | AI Toolkit `model.arch`; `null` for the LTX trainer. |
| `architecture.dtype`, `quantize`, `quantize_text_encoder`, `gradient_checkpointing` | Training precision and memory settings. AI Toolkit: `train.dtype`, `model.quantize`, `model.quantize_te` (written when not `null`), `train.gradient_checkpointing`. For the LTX row they describe the settings in `trainer_options.run_extra`. |
| `architecture.model_extra` | Further AI Toolkit `model` keys, in order (FLUX: `is_flux: true`). |
| `family_match` | `substrings` and `tokens` that match a custom base model to this row's AI Toolkit `model` block; `null` for none. Tokens must not touch another letter or digit. |
| `resolution.choices`, `default` | Selectable training resolutions and the ones applied when the model is selected. |
| `resolution.multiple` | `true`: Advanced shows one toggle per resolution bucket. `false`: a single picker. |
| `recipe.length` | `{unit, value}`: the default training length in `steps`, or in `epochs` (passes over each training image and clip). |
| `recipe.learning_rate`, `rank`, `alpha`, `batch_size`, `gradient_accumulation` | Defaults for the editable Advanced fields. |
| `recipe.optimizer` | AI Toolkit `train.optimizer`; for LTX it describes `run_extra.optimization`. |
| `recipe.checkpoints` | `every` (steps), `keep` (`max_step_saves_to_keep`; 0 keeps all), `dtype` (saved precision, `null` when the trainer has none) and `editable` (Advanced shows the three checkpoint controls and the app sends their values). |
| `trainer_options` | Optional. `run_extra`: the exact `extra` object the app sends for an LTX run (key order matters). `process`: AI Toolkit `process` keys the typed fields do not cover; the pod deep-merges them over the generic config and under run.json `extra`, which still wins. The app does not read `process`. |
| `gpu.min_vram_gb` | GPU offers with less memory are not shown. |
| `gpu.verify_on_pod`, `verify_message` | Before uploading inputs, training, resuming or generating, ask the agent for the real GPU memory and refuse with `verify_message` when it is below `min_vram_gb`. |
| `gpu.note` | The sentence after "These have at least N GB of memory per GPU." |
| `video` | `null` for an image-only model, else the clip training support: `title` (media editor), `frame_law` (`first + k × step` frames), `fixed_fps` (or `null` for any constant rate), `min_frames`, `initial_frames`, `duration_choices` (a fixed list, or `null` for every count on the law) and `select_whole_clip`. |
| `preview` | `training_samples` (the launcher can sample during training), `still` (comparison may produce one still frame) and `video` (`min_frames`, `max_frames`, `choices`, `default_frames`; `null` for images only). |
| `captions` | `image_profile`, `video_profile`, `profile_prefix` (a project caption profile starting with it selects this model) and `titles` (display names of this row's profiles). |
| `selection.follows_project_profile` | The selection may move to the project's profile model when the project's caption profile changes. |
| `license` | `id`, `name`, `url`, `notice`, `show_notice`. With `show_notice` the picker shows the notice, a link and the download size, and the pushed model card carries the licence. |
| `usage_note` | Optional. A sentence about using a LoRA trained on this model, shown under the picker and in the model card's `## Use` section. |
| `hooks` | Concern to hook name; an absent concern is the generic behaviour. |
| `notes` | Free text for maintainers. Not displayed. |

Readers keep the order of `architecture.model_extra` and `trainer_options.run_extra`: use an
order-preserving parser (the app uses `JSONValue(parsing:)`).

### Training length

A row in `epochs` shows passes over each image and clip, and the app sends
`steps = ceil(epochs × items / (batch_size × gradient_accumulation))`, where `items` is the
number of included training images and clips. run.json always carries `steps`; Resume and saved
runs work on steps.

## Lookup rules

- **Exact row**: the row whose `model_ref` equals `base_model` (case-sensitive) on the given
  trainer. Hooks, generation, GPU verification and project-profile following use it.
- **Effective row**: the exact row, else the row `trainers[trainer].default_model` names. Defaults
  and capabilities use it, so a custom base model behaves like the trainer's default model.
- **Family match** (pod, AI Toolkit `model` block only): without an exact row, the first row in
  table order whose `family_match` matches the lowercased `base_model`, so custom paths such as
  `/workspace/models/MiniMax-H3` still get the right `arch`. It supplies the `model` block and
  nothing else.

## Hooks

A hook is a named strategy for one concern. The row names it; the app (`ModelHooks`) and the pod
(`model_table.HOOKS`) each register the names they know, and a name that is not registered is an
error.

| Concern | Name | What it does |
| --- | --- | --- |
| `trainer_config` | `minimax_h3` | The pod builds H3's whole AI Toolkit config (quality recipe, dataset groups, initialization, guidance check) instead of the generic mapping, and fetches its pinned assets before launch. |
| `native_recipe` | `minimax_h3` | The app imports a native AI Toolkit recipe and warm-starts a new run from LoRA weights; the guidance rules go with it. The agent admits external initialization only for such a row. |
| `generator` | `aitoolkit_image` | Comparison stills through AI Toolkit's `StableDiffusion` class, with the row's model settings (FLUX). |
| `generator` | `aitoolkit_arch_image` | Comparison stills from the model class AI Toolkit registers for the row's `arch`, with the trained LoRA bound as a network; for architectures that are their own class (Z-Image). Needs the source run's saved `native-config.json`. |
| `generator` | `ltx_one_stage` | LTX's official one-stage CLI. |
| `generator` | `minimax_h3` | H3's registered model with the trained network recipe. Needs the source run's saved `native-config.json`. |
| `run_extra` | `ltx_video_buckets` | When the inputs contain video, the app sets `preprocess` to `{"buckets_from_media": true, "args": ...}`. |

A row without a `generator` hook does not support comparison generation.

## Adding a model

1. **Check the trainer pin.** For AI Toolkit the `arch` must exist at `AI_TOOLKIT_COMMIT` in
   `pod/images/Dockerfile.aitoolkit`.
2. **Write the row.** Append it to `models` (order is picker order). Fill it from a training
   config that works: `architecture`, `resolution` and `recipe`; `gpu.min_vram_gb` and
   `gpu.note`; `source.first_download_gb` from the Hub file sizes; `license` from the model page,
   with `show_notice` true when users should read it before training.
3. **Choose caption profiles.** Reuse an existing profile when the model reads the same prose, or
   add a profile file to the bundled caption skill (the Python package and the app both carry
   it) and name it in `captions`. Give a `profile_prefix` only when projects should select the
   model from their profile.
4. **Comparison.** `aitoolkit_image` builds AI Toolkit's legacy `StableDiffusion` class, which
   serves only the legacy architectures (`LEGACY_ARCHS` in `toolkit/util/get_model.py`; FLUX is
   one). Newer architectures load through `get_model_class` and use `aitoolkit_arch_image`. Leave
   `generator` out, and `preview` off, for a model whose comparison has not been shown to work;
   it still trains.
5. **Hooks only for behaviour data cannot express.** Add the name to both registries and to the
   table above. A value that can be data is an optional row field instead
   (`trainer_options.process` is one for AI Toolkit `process` keys).
6. **Rebuild the pod images** so they carry the new row, and try the model through the app on a
   rented pod.
