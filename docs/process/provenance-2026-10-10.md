# Provenance of the lab commits, 2026-10-10

Who produced each commit in this repository up to `e620882`. The Codex commits carry no
`Co-Authored-By` trailer and are authored under Hákon's identity, so this file is the record.

## Claude workflows

Author `gnomon <gnomon@sokrates.is>` unless noted; every one carries a
`Co-Authored-By: Claude Fable 5.1` trailer.

| commit | subject |
|---|---|
| `d80681f` (tag `v0.1.0`) | concept-captioner 0.1.0 (authored as Hákon Freyr Gunnarsson) |
| `98e32aa` | Exploration snapshot: v0.2 Python rewrite, Swift core, pod side, app and pod briefs |
| `0c8f3c0` | Briefs: this repo is the lab notebook, commit freely; re-stage happens in a second repo |
| `b0c139a` | CORE-STATUS: record the unverified Resolve.swift parser-differential finding |
| `26f73fe` | Record the vLLM key-binding tightening for both resolvers as a do-first item |

## Codex seats

`git log 26f73fe..e620882`: 24 commits, all authored as `Hákon Freyr Gunnarsson
<rationallyprime@gmail.com>`, none with a trailer. They were made by the Codex coordinator and
its seats working from `docs/CODEX-HANDOFF.md` and `docs/SWARM-PLAN.md` (Sol for substantive
work and review, Luna for mechanical work, per the handoff's Conventions). The record does not
say which seat made each commit; the status history names seats where it mattered
("Sol core agent", "Sol key-review agent").

| commit | time (UTC) | subject |
|---|---|---|
| `d671f6e` | 17:47 | Define the app audience and plan the two implementation streams |
| `74d80e4` | 17:49 | Use Codex agents with Sol for substantive work and Luna for mechanical tasks |
| `c09455f` | 17:58 | Bind model credentials to configured hosts and validate the actual HTTP destination |
| `52bedee` | 17:58 | Constrain LTX preprocessing options and recognize pod proxy failures |
| `c325cb4` | 18:08 | Serve TensorBoard through the authenticated agent and prepare LTX models automatically |
| `602c60c` | 18:16 | Complete Swift gateway routes and provider thinking support |
| `d0b845b` | 18:25 | Record real Swift Hub upload, LFS verification and download proof |
| `ad5c94c` | 18:41 | Build the native nine-screen app with offline demo and GPU controls |
| `11e1999` | 18:45 | Record app acceptance and ongoing hardware integration boundary |
| `3fb3bfb` | 18:46 | Record real Swift image captioning through the authenticated pod |
| `92136b1` | 18:48 | Reject flags removed from the pinned vLLM runtime |
| `f7277a4` | 19:06 | Record live FLUX proof and prepared comparison boundary |
| `d5acfc8` | 19:19 | Use proven caption-server settings and preserve concurrent service |
| `158b092` | 19:22 | Record real image, caption and FLUX verification evidence |
| `d355674` | 19:22 | Correct documented AI Toolkit training seed path |
| `6560eef` | 19:26 | Record native reads of real pod state and training curves |
| `de6f152` | 19:30 | Install TensorBoard in the LTX trainer environment |
| `05d35d9` | 19:31 | Defer the comparison and retire the five-image proposal |
| `ef7989b` | 19:37 | Enable GUI walkthroughs and record native Gemini verification |
| `f7534e8` | 19:54 | Use measured GPU memory and LTX training defaults |
| `7910ffb` | 20:08 | Record live pod proofs and correct storage guidance |
| `a21a278` | 21:31 | Select public trainer images automatically for new projects |
| `e038c91` | 22:26 | Refine the native photo workspace and preserve caption drafts |
| `e620882` | 23:04 | Add native ChatGPT sign-in and plan-backed captioning |

Four of these edited `app/docs/APP-BRIEF.md` in place (`d671f6e` audience, `ef7989b` GUI
walkthroughs, `e038c91` DESIGN.md reference, `e620882` ChatGPT sign-in and its loopback
callback). On 2026-10-11 the owner confirmed that he asked for ChatGPT sign-in and OpenAI
captioning; APP-BRIEF marks the lines that carry that and the other owner decisions of that
day. The audience, GUI-walkthrough and DESIGN.md edits have no owner confirmation on record.

## After 2026-10-10

Commits on `main` after `e620882`, 2026-10-11, as each commit records itself:

| commit | time | author | trailer | subject |
|---|---|---|---|---|
| `1c622e3` | 00:28 | `gnomon <gnomon@sokrates.is>` | `Co-Authored-By: Claude Fable 5.1` | Refuse retention-controlling keys in a job's extra_body, in both languages |
| `fc89ccb` | 00:33 | `gnomon <gnomon@sokrates.is>` | `Co-Authored-By: Claude Fable 5.1` | Python accepts only the unified job settings keys and forces OpenAI storage off |
| `371c9ad` | 00:36 | Hákon Freyr Gunnarsson | none | Defer re-staging until the owner requests it |
| `8cda07c` | 00:40 | Hákon Freyr Gunnarsson | none | Add video training data to the later roadmap |

`371c9ad` and `8cda07c` carry Hákon's identity and no trailer, so the commits do not show who
produced them; their producer is unrecorded unless the owner or the integrator states it. Later
commits are added here by hash in the same form when they reach `main`.

The local narrative candidate in the private notes (`restage/candidate`) uses the placeholder
identity `Codex narrative candidate <codex@local.invalid>`. It is a historical draft, deferred
under the re-stage rule in `docs/CODEX-HANDOFF.md`.
