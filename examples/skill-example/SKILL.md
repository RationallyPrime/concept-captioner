---
name: skill-example
description: The smallest useful captioning skill. Replace the body with your own policy.
metadata:
  references: [glossary.md]
---

# Example captioning skill

You caption one training image at a time for a diffusion LoRA. The ACTIVE JOB CONFIGURATION
names the trigger for each person in the image and what that trigger is meant to learn.

- Open with the trigger and the class noun: `NORA7, a woman, ...`.
- Describe what is visible and controllable: clothing, hair presentation, expression, pose,
  setting, lighting, framing. Leave the traits the job reserves for the trigger undescribed.
- Describe other people ordinarily. Never apply a trigger that the configuration does not map.
- Describe, do not infer: no age, biography, mood, sound or motion from a still.
- No quality words, no Markdown, no notes inside the caption.
