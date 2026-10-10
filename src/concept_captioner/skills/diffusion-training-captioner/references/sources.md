# Sources and evidence boundaries

Reviewed 2026-10-09. Prefer inspected behavior and source paths over UI labels. Recheck the actual model and trainer when using a different revision.

## MiniMax H3 formatting foundation

- [Official h3-prompt-writing skill](https://github.com/MiniMax-AI/MiniMax-H3/blob/a107547fa669c509b8e6363fe18378d46ab3066c/skills/h3-prompt-writing/SKILL.md)
- [Official base-mode guide](https://github.com/MiniMax-AI/MiniMax-H3/blob/a107547fa669c509b8e6363fe18378d46ab3066c/skills/h3-prompt-writing/references/base-en.txt)
- [Separate Ref2VA guide](https://github.com/MiniMax-AI/MiniMax-H3/blob/a107547fa669c509b8e6363fe18378d46ab3066c/skills/h3-prompt-writing/references/ref-en.txt)

The inspected skill's latest path-specific commit was `a107547fa669c509b8e6363fe18378d46ab3066c`, dated 2026-08-11. The base skill and base-mode guide were read in full. The Ref2VA link is optional provenance for a mode outside the supported standalone profiles; no retrieval is required for routine use.

H3's field names, keyframe instructions, shot timing, dialogue tags and speaker labels come from this generation-prompt guide. The concept partition and observational training policy are adaptations. Do not attribute them or training guarantees to MiniMax.

## Concept omission and independent controls

- [BFL: FLUX.2 klein Training](https://docs.bfl.ai/flux_2/flux2_klein_training), Caption Writing and Dataset Diversity.
- [BFL-authored practical LoRA guide](https://huggingface.co/blog/black-forest-labs/flux-2-klein-lora), published 2026-06-04.

The official page supports detailed captions, consistent triggers, describing attributes outside the intended concept, and dataset variation. The practical guide illustrates style training and separately named variations. Applying the principle to facial identity, physique, voice and motion requires the explicit concept boundary introduced here. Treat separation as a training rationale, not a guarantee of identifiability.

## MiniMax captioner implementation

- [AI Toolkit captionOptions.ts](https://github.com/ostris/ai-toolkit/blob/a9e7752178182e7a17db5b649ed8d7297f4060f8/ui/src/helpers/captionOptions.ts), especially `minimaxT2VCaptionPrompt` and `minimaxImageCaptionPrompt`.

The inspected file's latest path-specific commit was `a9e7752178182e7a17db5b649ed8d7297f4060f8`, dated 2026-09-17. It includes a three-field audiovisual caption and a one-shot still adaptation with `N/A` audio. Current UI labels say MiniMax H4 while comments reference the H3 guide. Use the inspected text convention; do not claim the label establishes a particular H3 training topology.

This skill's still profile describes a visible moment without inferring a temporally stationary camera. The syntax does not prove a checkpoint's support for image training or configure audio loss.

## LTX captioner implementation

- [Lightricks LTX-2 captioning.py](https://github.com/Lightricks/LTX-2/blob/main/packages/ltx-trainer/src/ltx_trainer/captioning.py), image/video instruction constants and caption-response parser.

The inspected implementation requests observed-only content in one prose paragraph and extracts `combined_caption_english` from a captioner response envelope. This supports the LTX profile and the separation between raw caption text and JSON transport. It does not establish identical behavior or audio support for every LTX version.

## Added design decisions

The following are adaptations, not experimental findings: reserve designated defining traits for the trigger; retain nuisance context in image-conditioned captions; keep ambiguous identity/audio labels outside the ready set; audit correlations separately from caption completeness; and inspect serialized conditioning before diagnosing caption behavior. The user's requested principle governs the design. Installing or validating this skill does not imply model training or a likeness benchmark.

## Portable export

This standalone export embeds the full policy and format references. Its added job configuration, delivery instructions, capability checks and explicit advanced-format boundaries adapt the original skill for general multimodal interfaces. The examples remain illustrative, not observations about supplied media.
