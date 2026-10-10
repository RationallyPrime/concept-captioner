# FLUX and LTX profiles

Apply the concept partition in the Core Caption Policy above before choosing wording. A diffusion-transformer architecture does not imply shared caption grammar, text encoders, token budgets, or LoRA compatibility.

## FLUX image training

Use `flux-image` for ordinary image concept/identity captions. Introduce the exact trigger and class noun early; describe visible subject state, controllable presentation, surroundings, framing, light and image treatment in connected prose. Omit the concept's defining traits, audio, timelines, speaker IDs, H3 fields and alignment instructions.

Preserve an established trainer template when supplied. Paired edit training can require transformation instructions rather than target descriptions. Inspect that objective before changing captions.

BFL's FLUX.2 klein training documentation supports consistently using a trigger while describing visible attributes outside the intended concept. This supports the content policy, not a universal optimal caption length or identical behavior across all FLUX checkpoints.

## LTX image training

Use `ltx-image` for supported single-frame targets. Begin with the subject or a concrete visual fact and write one prose paragraph. Describe the visible moment under the same concept boundary. Omit shot tags, audio claims, temporal continuations and inventories of absent things.

## LTX video training

Use `ltx-video` for clips. Write one continuous chronological paragraph integrating visual and, when applicable, audio evidence. Include framing, actual camera changes, triggers and controllable appearance, actions, environment, lighting, real transitions and supported audio. Reserve distinctive identity or the target motion pattern according to the contract.

Do not include H3 fields, `[Shot N]`, `<Picture N>`, or H3 dialogue tags by default. Describe cuts in prose. Quote intelligible dialogue in the original language. For inspected audiovisual targets, mention meaningful absent audio categories when required by the established captioning instructions. For a visual-only objective, follow the trainer's audio-exclusion contract. Never infer silence from unavailable audio.

The inspected Lightricks LTX-2 captioner requests a JSON object containing `combined_caption_english`, then extracts its string. Distinguish the captioner response envelope from training conditioning. Return that object when integrating with the captioner; save only the string to raw caption sidecars unless the loader specifies otherwise.

This implementation establishes a version-specific prose convention. Do not assume older LTX-Video checkpoints support audio or every LTX trainer uses that envelope.

## Format selection

| Sample and objective | Default form |
| --- | --- |
| H3 single photo target | Three H3 fields, one `[Shot 1]`, audio fields `N/A` |
| H3 clip without conditioning images | Three H3 fields with actual timeline |
| H3 clip with verified first-frame conditioning | Native alignment line plus three fields |
| FLUX image concept | Plain visual prose |
| LTX single-frame concept | One visual paragraph |
| LTX audiovisual concept | One chronological audiovisual paragraph, optionally inside the captioner's required envelope |

Keep model profiles separate on export. Reuse observations and concept policy, not blind search-and-replace syntax conversion. Captions may be portable in meaning; weights and training configurations are not thereby portable.
