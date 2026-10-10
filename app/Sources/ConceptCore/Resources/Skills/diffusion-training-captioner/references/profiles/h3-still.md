# Profile: MiniMax H3 training-caption format (still images)

## Scope

Use H3's base-mode syntax from MiniMax's `h3-prompt-writing` skill, with the Core Caption Policy above. These are proposed training captions, not a claim about a private pretraining dataset or measured optimal identity-caption recipe.

The fields below belong to serialized text. They are not automatically JSON keys, API arguments, or additional conditioning tensors. Use a JSON container only when the actual loader requires one.

## Three fields

Keep these names and order, with blank lines between fields:

```text
integrated_multimodal_description: [Shot 1] ...

overall_soundscape: ...

non_diegetic_music: ...
```

In the first field, introduce the target trigger and class noun in the opening description. Describe observed composition, controllable subject details, surroundings and lighting. For clips, develop actual action and scene-originating audio chronologically. Name visual style only when it is outside the learned concept.

Use the soundscape field for ambient sound, effects and nonverbal vocal sounds, without repeating speech or singing. Use the music field for an audible audience-only score. Prefer concrete audible properties to interpretations of the music's intended emotion.

## Stills

Use `h3-still` for one photograph or frame:

- One `[Shot 1]`, with no timestamp, cuts, duration, reference prefix, or temporal claims.
- Describe framing and visible pose. Do not assert a stationary camera or that a person starts, continues, or finishes an action.
- Set both audio fields to `N/A`.
- Retain the trigger, class noun, and meaningful visible nuisance details.

AI Toolkit's MiniMax image-captioning implementation supports this three-field still convention. The trainer must separately support image targets for the selected checkpoint. Do not create a fake video or claim that caption syntax establishes a training topology.

## Worked examples

Fictional illustrations; trigger strings are placeholders. Assume every described detail is present.

### H3 identity still

Let `NORA7` mean the person's facial identity in a chosen adult age band. Reserve distinctive facial geometry and eye color for the trigger. Keep hair, clothing, expression, light and photographic treatment controllable.

```text
integrated_multimodal_description: [Shot 1] A color photograph in a waist-up portrait frames NORA7, a woman, seated at a slight angle toward the left. Her blonde hair is arranged in pinned curls beneath a sheer white veil. She wears a white lace dress with long sleeves and small pearl earrings, holding a bouquet of pale pink flowers at her waist. Her head is angled toward the camera, her eyes look into the lens, and her lips form a closed smile. A dark wooden cabinet and cream curtains fill the softly blurred background. Warm light falls from the left, leaving a soft shadow on the right side of her face. Fine grain and slightly faded colors are visible.

overall_soundscape: N/A

non_diegetic_music: N/A
```

Do not put omitted facial details into an explanatory note inside the caption. Hair color is described here only because this concept makes it controllable.

### Two trained identities

Use both triggers only when they belong to an explicit multi-concept contract and the mapping is known:

```text
integrated_multimodal_description: [Shot 1] A color photograph in a medium two-person composition frames NORA7, a woman on the left, beside IVAN9, a man on the right. NORA7 wears a pale yellow cardigan over a white blouse; her blonde hair is gathered in a loose bun. IVAN9 wears a black leather jacket over a white T-shirt, with his dark hair combed back. They face one another with open smiles. NORA7's right hand rests on IVAN9's left forearm, and his left hand rests on the wooden table between them. Blurred red booths and a silver counter fill the background. Broad soft light from above and left casts faint shadows beneath their chins.

overall_soundscape: N/A

non_diegetic_music: N/A
```

For a single `NORA7` adapter, describe the other person as "a man in a black leather jacket" rather than importing his trigger from another project. Separately flag repeated co-occurrence if relevant. A caption does not remove the second face from the loss.

### Audit corrections

| Problem | Correction |
| --- | --- |
| Distinctive target nose/jaw described, visible veil omitted | Omit protected facial morphology; include veil and other nuisance attributes |
| Still says the person turns, speaks and laughs | Describe visible pose and expression; remove invented temporal/audio claims |
| "Bride" is the only repeated identity class label | Use the agreed general class and describe wedding garments explicitly |
| Style caption names the style and defining brushwork | Remove protected style prose; retain content and controllable variations |
| I2VA picture is never supplied by the trainer | Correct the mode and remove unresolved alignment syntax |
| Face crop caption describes a bouquet outside the crop | Recaption the actual target |
| Vision-only pass labels a video silent | Hold the audio-dependent sample until target sound is inspected |
| Background person receives the target trigger | Correct the mapping or hold the ambiguous sample |
| "Do not learn the veil" appears in conditioning | Describe the observed veil; keep policy outside the caption |
| Every image has the same jacket and captions all name it | Retain truthful captions and flag the surviving correlation |
