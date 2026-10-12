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
