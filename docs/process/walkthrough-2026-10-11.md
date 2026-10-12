# App walkthrough with the owner, 2026-10-11

Hákon and Claude walk ConceptStudio screen by screen on a build of `main` (1515c50). Decisions
below are the owner's unless marked as observations. Each becomes work for the app seat once the
walkthrough is done.

## Welcome

- **Decided:** remove "How diffusion training works" from Welcome. It stays on the first screen
  of the journey (Images), where the demo starts.
- **Open:** the screen looks austere and empty and needs work. Claude's suggestion, not yet
  decided: show the journey (prepare data, write captions, train) and show recent projects as
  cards with a thumbnail.

## Accounts & settings

1. **Decided: one connection section.** ChatGPT sign-in, OpenRouter browser authorization and
   manually pasted keys become a single "connect a captioning account" section with a selector
   that switches between the three.
2. **Decided: stop over-explaining.** Each section gets one sentence saying what it is for.
   Sentences about where secrets are stored, how authorization works or billing mechanics are
   cut; anything genuinely useful moves to a tooltip. Examples: "No API key is needed. Requests
   count toward your plan or credits balance"; "Your browser handles sign-in. Saved sessions stay
   in your Mac's Keychain, outside projects"; the "How browser authorization works" disclosure;
   the OpenRouter usage caveats; "Keys are saved in your Mac's Keychain and never included in a
   project upload"; the vLLM host sentence; the repeated "Open or create a real project to leave
   demo mode".
3. **Bug: the training image field cannot show "automatic".** Clearing it and saving writes the
   full default name back into the field, which is indistinguishable from an override (the owner
   read it as the old override returning). An empty field means automatic, with the current
   default shown as placeholder text.
4. **Observation: Settings stays in demo mode after the demo is closed.** Demo mode ends only
   when a real project is opened or created, so ChatGPT sign-in and key status are unavailable
   from Welcome right after trying the demo. Closing the demo should leave demo mode.
5. **Decided: Hugging Face and RunPod get their own section.** They serve publishing and
   training, not captioning, and are important; they no longer hide in the captioning key picker.
6. **Decided: split the connection test.** Each key is checked when it is saved, in Settings,
   with a free request that generates nothing (list models, key info, whoami, account), and the
   status line says whether it works. The "does captioning work with my chosen model" test moves
   to the Captioning screen, next to the provider and model pickers. Reason: a freshly saved key
   (e.g. Anthropic) could not be tested from Settings at all.

Verified working live: ChatGPT plan connection test, OpenRouter key usage refresh, Manage usage.

Side note: two copies of the app (main and the app seat's working copy) share one set of
preferences; the stale copy can write an old training image override back.

## Real project (Diffusion-Fun: 22 new video stills joining a captioned 47-photo set)

7. **Observation: a new project starts with the demo's concept.** Its job.yaml held the demo's
   fictional `NORA7` person and the FLUX caption format. A real project should start without a
   concept, or with an empty one to fill in.
8. **Observation: folder import ignores caption sidecars.** Importing a folder brings images but
   drops the `.txt` captions next to them, although sidecars are the shared format the CLI
   writes. Folder import should read them (as Hub import already does, marking them imported).
   Today's workaround: the old set's images and captions were copied straight into the project's
   `images/` folder, and the project reopened.
9. **Observation: dataset advice looks like it drops samples.** Advice deliberately reviews at most
   48 photos, chosen evenly across the set; the progress line ("… of 48 samples") reads as if the
   rest were excluded. Say it is a sample, e.g. "reviewing 48 of 69, chosen evenly".
10. **Decided: expandable sections open from the whole row.** Today a disclosure ("Advanced
    settings", "Definitions" and the rest) opens only when the chevron itself is clicked; a click
    on its label does nothing (reproduced in the concept editor). Clicking anywhere on the row
    should toggle it, or at least the label as well as the chevron.
11. **Decided: no location text needed when the answer is obvious.** Mapping requires a location
    phrase in addition to ticking the concept, even when the frame shows a single face. When only
    one person (or one face) is present, ticking the concept is enough; the location defaults to
    the plain class noun ("the woman").
12. **Decided: model suggestions can be accepted.** "Request assignments from model" produces
    suggestions per sample, but there is no way to accept them except confirming each sample by
    hand. Add a way to accept suggestions, at least all of them at once, with per-sample review
    still possible.
   For this project, all 69 mappings were written directly into job.yaml with the project closed
   (30 Erla, 30 Gunnar, 9 pairs; the old set's from its reviewed captions, the new frames by eye),
   then validated with the CLI and confirmed by the app on reopening.
13. **Decided: model lists come from the provider.** Captioning shows a model dropdown for ChatGPT
    but only a free-text field for other providers, and switching provider (to Google Gemini)
    kept the previous provider's model name, `gpt-6.1-sol`. Fetch each provider's model list with
    the saved key (the same free request that item 6's key check makes), filter it to models that
    accept images (and video for clips) where the provider reports input types, and show it as a
    dropdown with an "Other model…" free-text escape for vLLM, gateways and new names. Switching
    provider resets the model to that provider's default. A Gemini model typed as
    `models/gemini-…` (the form Google lists) must work: strip the `models/` prefix, which the
    client already adds to the request URL.
14. **Observation: captioned samples read "Ready".** On Captioning, the 47 imported photos that
    already have captions show "Ready", the same as uncaptioned ones, though a normal run skips
    them. Show that they already have a caption (and whether it is final or imported).
15. **Bug (fixed in PR #3): publishing failed on an ordinary 16 MB photo** with "multipart LFS upload
    (> 5 GB) is not supported". The upload request offered multipart transfers, which the app does
    not implement, so the Hub chose them. Now only single-request uploads are offered.
16. **Observation: upload progress overwrites the final message.** Progress lines are posted late
    and replace the outcome; the footer froze on "hashing: 9.png" while the real error showed
    only in an alert. The final message must win.
17. **Observation: a rebuilt app loses its folder and Keychain access.** A build signed differently
    (every local rebuild, and any change of signing identity in a release) cannot restore recent
    project folders ("could not be restored … isn't in the correct format") and macOS asks again
    for each saved key. Expected for unsigned development builds; worth a clear message, and a
    stable Developer ID for releases.
18. **Observation: Publish did not notice a newly saved Hugging Face token** until the step was
    left and reopened; it kept offering the no-account route.
19. **Bug: the computer list ignores the saved storage's data center.** GPU pods offered an RTX PRO
    6000 while the selected network volume lives in EU-RO-1, which had none (its largest GPU was a
    32 GB RTX PRO 4500). Renting then failed. Offers must come from the volume's data center (the
    catalog can be queried per data center), or the screen must say which data centers have the
    chosen GPU and which storage can follow it.
20. **Bug: RunPod's error text is thrown away.** The failure read only "RunPod could not complete
    this action (400). Check your account and try again." RunPod's response body explains the
    refusal; show it (or a plain translation of it).
21. **Observation: a network volume is mandatory.** The app cannot rent without saved storage, so
    data centers with stock but no network volumes (both Icelandic ones, EU-NL-1, EU-CZ-1 on
    2026-10-12) are unreachable. Offer "no saved storage" with a plain warning that checkpoints
    live only on the rented computer and the result is pushed when training finishes. Creating a
    volume from the app, in a data center that has the chosen GPU, would also help.

## First real training run (2026-10-12)

Diffusion-Fun / Grease: 69 samples (47 earlier captioned photos + 22 new video stills captioned with
`gemini-flash-latest`, H3 still format), published privately as `RationallyPrime/Grease` at
`6102d707`. MiniMax-H3 (`Comfy-Org/MiniMax-H3` + pinned training adapter), AI Toolkit image
`v0.2.3-clean-20261011`, one RTX PRO 6000 in CA-MTL-3 with a new 300 GB network volume. 3,000 steps,
1,024 px, rank/alpha 32 on blocks 20–49, accumulation 2, lr 1e-4, about 1.1 steps/s. The LoRA
(179 MB) was pushed to private `RationallyPrime/grease-erla-gunnar-h3-v3`; the pod was stopped after
72 minutes (about $3 GPU). Pod env held only RunPod secret placeholders (ticket 3 confirmed live).

Recipe questions for the app seat. Corrected 2026-10-12: the owner's two earlier runs used different
training adapters, and the app recipe follows v2, not v1.

| Run | Training adapter | Guidance loss | Data | Resolution |
|---|---|---|---|---|
| v1 | Ostris v1 | on, target 3.5 | 47 photos | 768 + 1,024 |
| v2 | Circlestone | off | the same 47 | 768 + 1,024 |
| v3 (app) | Circlestone | off | 47 + 22 video stills | 1,024 |

22. **Checkpoints:** saved every 250 steps keeping only the last 4; v1 and v2 saved every 300 and kept
    40, so earlier checkpoints were available for comparison.
23. **Saved precision:** float16; v1 and v2 saved float32.
24. **Guidance loss:** off, which matches v2 and is correct with Circlestone (its author says not to
    combine the adapter with the guidance loss). Not a defect. If the app ever offers the Ostris
    adapter, the guidance loss belongs with that choice.
25. **Resolution:** one value only (512, 768 or 1,024); v1 and v2 used buckets 768 and 1,024.

Owner's verdict on the comparison renders (same seed and graphs, 2026-10-12): v3 gives the best Gunnar
but loses Erla's likeness. Next experiment: an Erla-only adapter on v1's recipe.
26. **Observation: steppers for large values.** Training steps moves in 25s with no text entry;
    reaching 3,000 took a long hold. A number field would serve better.
