# Profile: MiniMax H3 training-caption format (video)

## Scope

Caption the exact attached training segment in H3's base three-field syntax. This is observation of supplied media, not a request to invent a generated scene. The Core Caption Policy and the active concept boundary govern every field. These are proposed training captions, not a claim about a private pretraining corpus or measured adapter quality.

The three fields are serialized text inside `caption`, not extra JSON keys, model arguments or conditioning tensors. Do not invent a keyframe or reference prefix: use one only if the active job actually declares that trainer conditioning.

## Three fields

Keep these names and order, with blank lines between fields:

```text
integrated_multimodal_description: [Shot 1] ...

overall_soundscape: ...

non_diegetic_music: ...
```

Introduce each mapped trigger and its class noun in the opening description of the correct subject. Describe observed composition, independently controllable details, setting and light. Leave the learned concept's defining appearance, style, movement or voice to its trigger. Do not label a motion concept with the defining action in ordinary prose; describe the performer, scene and independently variable details instead.

## Exact segment and chronology

- The approved segment starts at zero. Describe its actual beginning, observable development and ending; do not borrow events from the original longer clip.
- Start with `[Shot 1]` without a timestamp. Add `[Shot 2]`, `[Shot 3]` and cut times only for cuts observed in this segment. Cut times must increase and lie inside the supplied segment; do not add cuts or camera moves to improve a story.
- Describe changes over time, subject actions and camera movement only when the supplied video supports them. Do not infer motion, speech or sound from thumbnails or a still frame.
- Describe visible image treatment only when it is outside the learned concept. Do not impose the generation guide's default cinematic style or invent age, identity, scenery, props, dialogue or sound.
- Keep readable scene text generic under the Core Caption Policy; never copy signs, labels or subtitles verbatim into the caption.

## Audio evidence

Inspect the audio in the actual transmitted segment. A visible action does not prove its sound, and `audio_status: uninspected` is a request to inspect the supplied evidence, not a declaration of silence.

- In the first field, place clear observed speech, singing and scene-originating music where they occur. Give actually vocalizing speakers stable `(S1)`, `(S2)` IDs. Preserve clearly audible words and their language inside `<d>[Language] ...</d>`; never supply missing words, translate uncertain speech, or invent a voice. Describe vocal characteristics only when audible and outside the concept boundary.
- `overall_soundscape` summarizes inspected ambient sound, physical effects and nonverbal vocal sounds. Do not repeat dialogue or lyrics here. Use `N/A` only when the supplied evidence establishes no applicable sound, such as a confirmed absent audio track; never claim silence because audio was unavailable or uninspected.
- `non_diegetic_music` describes an inspected audience-only score in concrete musical terms. Music from visible instruments, radios or other scene sources belongs in the first field. Use `N/A` when inspection establishes there is no audience-only score.
- If the route cannot inspect the required audio, or essential action, identity or speech is ambiguous, return `usable: false`, an empty `caption` and a short reason in `note`. Uncertainty belongs outside training text.

## Still images in a mixed project

If the actual attached target is one photograph or frame, use the unchanged `h3-still` convention: one `[Shot 1]`, no timestamp, cuts, duration, reference prefix or temporal claims; describe only visible composition and pose, and set both audio fields to `N/A`. Do not turn a still into an invented video. A three-field caption does not establish whether the selected trainer supports that target.
