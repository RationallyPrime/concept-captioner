# Worked caption examples

These are fictional illustrations, not captions for uninspected user assets. Assume every described detail is present. Trigger strings are examples, not verified tokenizer additions.

## Contents

- [H3 identity still](#h3-identity-still)
- [H3 video with actual first-frame conditioning](#h3-video-with-actual-first-frame-conditioning)
- [Two trained identities](#two-trained-identities)
- [FLUX and LTX](#flux-and-ltx)
- [Style concept](#style-concept)
- [Object concept](#object-concept)
- [Motion concept](#motion-concept)
- [Audit corrections](#audit-corrections)

## H3 identity still

Let `NORA7` mean the person's facial identity in a chosen adult age band. Reserve distinctive facial geometry and eye color for the trigger. Keep hair, clothing, expression, light and photographic treatment controllable.

```text
integrated_multimodal_description: [Shot 1] A color photograph in a waist-up portrait frames NORA7, a woman, seated at a slight angle toward the left. Her blonde hair is arranged in pinned curls beneath a sheer white veil. She wears a white lace dress with long sleeves and small pearl earrings, holding a bouquet of pale pink flowers at her waist. Her head is angled toward the camera, her eyes look into the lens, and her lips form a closed smile. A dark wooden cabinet and cream curtains fill the softly blurred background. Warm light falls from the left, leaving a soft shadow on the right side of her face. Fine grain and slightly faded colors are visible.

overall_soundscape: N/A

non_diegetic_music: N/A
```

Do not put omitted facial details into an explanatory note inside the caption. Hair color is described here only because this concept makes it controllable.

## H3 video with actual first-frame conditioning

Assume a four-second clip and its first conditioning image have been inspected. The woman lowers a cup, turns, then speaks. The audio contains a ceramic tap, room hum and the exact line below; no score is audible.

```text
For the target video, at 0.00 seconds into the target video, <Picture 1> (from [Shot 1]) is fully referenced.

integrated_multimodal_description: [Shot 1] Live-action, a medium shot frames NORA7, a woman in a blue knitted cardigan over a white blouse, seated to the left of a wooden kitchen table. Her dark hair is tied back, and she holds a white cup near her mouth in the opening frame. Pale cupboards and a tiled wall stand behind her under soft light from the left. She lowers the cup to the table, turns her head toward the person beyond the right edge, and opens her mouth in a smile. NORA7 (S1) says in a quiet voice: <d>[English] Shall we begin?</d> The framing tightens slightly as she rests her hand beside the cup.

overall_soundscape: A low, steady room hum continues beneath a light ceramic tap as the cup meets the table.

non_diegetic_music: N/A
```

For the same target trained without conditioning images, select T2VA and remove the alignment line. Retain the initial-state nuisance details. Do not introduce a picture reference just because a photo exists elsewhere in the dataset.

## Two trained identities

Use both triggers only when they belong to an explicit multi-concept contract and the mapping is known:

```text
integrated_multimodal_description: [Shot 1] A color photograph in a medium two-person composition frames NORA7, a woman on the left, beside IVAN9, a man on the right. NORA7 wears a pale yellow cardigan over a white blouse; her blonde hair is gathered in a loose bun. IVAN9 wears a black leather jacket over a white T-shirt, with his dark hair combed back. They face one another with open smiles. NORA7's right hand rests on IVAN9's left forearm, and his left hand rests on the wooden table between them. Blurred red booths and a silver counter fill the background. Broad soft light from above and left casts faint shadows beneath their chins.

overall_soundscape: N/A

non_diegetic_music: N/A
```

For a single `NORA7` adapter, describe the other person as "a man in a black leather jacket" rather than importing his trigger from another project. Separately flag repeated co-occurrence if relevant. A caption does not remove the second face from the loss.

## FLUX and LTX

Use the same observations and concept partition with the corresponding prose form.

### FLUX image

```text
NORA7, a woman, sits at a slight angle toward the left in a waist-up color portrait. Her blonde hair is arranged in pinned curls beneath a sheer white veil. She wears a long-sleeved white lace dress and small pearl earrings, holding pale pink flowers at her waist. She looks into the camera with a closed-lip smile. A dark wooden cabinet and cream curtains are softly blurred behind her. Warm light comes from the left, with soft facial shadow on the right, fine grain and slightly faded colors.
```

### LTX video

For the kitchen clip, with audio inspected and included in the objective:

```text
NORA7, a woman in a blue knitted cardigan over a white blouse, sits on the left of a wooden kitchen table in a live-action medium shot, her dark hair tied back and a white cup held near her mouth. Soft light from the left illuminates pale cupboards and a tiled wall behind her. A low room hum continues as she lowers the cup, which makes a light ceramic tap against the table, then turns her head toward someone beyond the right edge. Her mouth opens in a smile and she says quietly in English, "Shall we begin?" The framing tightens slightly as she rests her hand beside the cup; no background music is audible.
```

Wrap this string in `combined_caption_english` only when the caller expects that captioner envelope. Do not save the JSON envelope as raw training text accidentally.

## Style concept

Let `WASH4` learn a particular watercolor treatment, including its texture and palette. Describe content without naming the treatment or enumerating its defining effects:

```text
WASH4. A small stone cottage stands beyond a wooden gate, with three tall trees on the left and a winding path leading to its front door. Two rectangular windows flank the doorway, and a chimney rises above the sloping roof. An overcast sky fills the upper third of the composition.
```

If object color is separately controllable instead of protected by `WASH4`, describe it. For H3, wrap the body in the appropriate fields; do not automatically add "watercolor" because the upstream generation guide begins with style.

## Object concept

Let `CUP8` mean a particular mug design, including its silhouette, glaze and decoration. Keep presentation and surroundings controllable:

```text
CUP8, a mug, rests on the right side of a light wooden table with its handle pointing left. A metal teaspoon lies beside it, and an open notebook occupies the lower left corner. The view looks down at a shallow angle under broad light from the right, casting a soft shadow to the left. The far edge of the table is out of focus.
```

If only shape is the target and glaze should be independently controllable, caption the glaze. Do not apply the same object boundary to every dataset.

## Motion concept

Let `STEP6` learn a particular footwork sequence. Reserve that sequence for the trigger; describe the independently variable performer, outfit and scene:

```text
integrated_multimodal_description: [Shot 1] Live-action, a full-body view frames an adult dancer performing STEP6 on a light wooden floor. The dancer wears a red tracksuit and white shoes, beginning with feet together and arms relaxed at the sides. A plain gray wall fills the background under diffuse overhead light. The camera maintains the same framing as the dancer returns to the starting stance.

overall_soundscape: Soft shoe impacts and fabric movement are audible.

non_diegetic_music: N/A
```

Assume the actual clip supports each statement. Caption speed or direction if they should be separately controllable variants. If the target is the performer instead, use an identity trigger and describe the observed footwork.

## Audit corrections

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
