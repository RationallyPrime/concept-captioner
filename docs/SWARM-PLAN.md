# ConceptStudio implementation plan

This plan executes `CODEX-HANDOFF.md`, `app/docs/APP-BRIEF.md` and
`pod/docs/POD-VERIFY-BRIEF.md`; those remain the product and delivery requirements.
Prepared 2026-10-10; execution launched on the same day after Hákon enabled ULTRA.

## Target and acceptance

A person with no programming or ML knowledge can go from photos to a trained LoRA through
the nine-screen journey. Hákon can use the same app efficiently enough to prefer it to a
terminal. Apply the audience rules in the app brief to defaults, language, errors and repeat
runs, not merely to onboarding copy. Keep meaningful controls and the shared project formats.

App acceptance: build, tests, lint and bundle green; every screen and required feature works
through the complete offline demo; status distinguishes fake checks from live checks. No
automated GUI launch. Signing and notarization are documented at this boundary.

Pod acceptance: all seven demonstrations in the pod brief, in its order, including both
trainers, real one- and two-GPU behavior, output retrieval/publication and actual spend.
Fake tests do not establish any of those real-hardware claims.

## First: settle the shared foundations

One owner per outcome, including its tests and directly necessary repairs. Work on independent
outcomes in parallel; do not have two authors editing the resolver or another shared file.

| Outcome | Owner at dispatch | Acceptance |
|---|---|---|
| Key routing in Python and Swift | Coordinator; independent reviewer after repair | Fixed provider hosts; vLLM key only to the user-configured host; job authentication headers refused; actual request-header tests and sampled URL adversaries in both languages. |
| All three Swift gateways | Swift core agent | OpenRouter, Vercel AI Gateway and Pydantic AI Gateway use fixed hosts and their own keys; Python-compatible model routing and stubbed wire tests; no job-controlled gateway host. |
| Pod argument and proxy rules | Pod agent | Verify the existing vLLM allowlist, constrain LTX preprocessing flags, and classify Cloudflare 520–526 proxy failures correctly; focused tests reach the real caller. |

Use current source to resolve the handoff's remaining findings: Hub LFS verification and
provider thinking settings on Swift; the current argument paths and proxy client on pod.
The core owner covers the Swift findings alongside gateway work. Confirm or repair the actual
defect; do not reimplement completed work based on stale status counts.

Before app provider integration or any real pod exposure, independently accept the relevant
foundation changes. Key routing and pod argument/proxy repairs have independent acceptance.
Swift gateway/core work and app implementation are active; the pod owner is proceeding to real
builds and verification. Current verification details belong in the respective status documents.

## Then: two delivery streams

**App owner, on the Mac.** Own the complete user journey, using ConceptCore for captioning.
The coordinator agrees the minimal app state and navigation seam with this owner before
additional UI work is split. Reuse job, mapping, final-caption and streaming semantics.
Define no second project contract or captioning pipeline.

Deliver incrementally, keeping the complete demo route navigable:

1. Welcome, project open/create/save, Settings and Keychain, and the nine-screen shell. Establish
   demo mode with the same application actions and visible Demo badge; it must never use the
   network. Keep the library's tests offline too.
2. Images, Concepts and Mapping: folder/Hub/Apple Photos import, the specified image warnings,
   dataset critique, boundary assistance and confirmed mapping. Explain decisions through the
   images and the user's intended result.
3. Captioning, Review and Publish: live outcomes, cancellation, model/skill/profile choices,
   optional critic, edits protected as final, selective re-captioning, model comparison and Hub
   publication. Remember choices for repeat runs.
4. GPU pods, Training and Monitor: RunPod lifecycle and pricing, agent plan/start/status/logs/
   stop/events, trainer defaults, curves and TensorBoard. Implement the required budget cap,
   idle watchdog, quit/close warnings and stop-everything behavior with the lifecycle itself.
5. Complete demo failure/cancellation paths, build the double-clickable `.app`, document first
   run and signing, and write APP-STATUS with exactly what the evidence establishes.

These are delivery slices, not permission stops. If a later slice can proceed while an earlier
one waits on an external dependency, keep moving without duplicating its owner's work.

**Pod owner, on cx53 and real pods.** After foundation acceptance, execute the pod brief's
seven steps in order: Docker builds and registry push with fake compose health; authenticated
agent control on one- and two-GPU pods; real vLLM captioning; Hub data in, both tiny trainer runs,
curves and LoRA out; actual sequential VRAM release and concurrent device isolation; RunPod
template publication; evidence and cost report. Repair code and spec where real behavior differs.
Use placeholder triggers only. Secure outputs and stop paid pods when useful work ends.

The app can progress against its demo backends while the pod owner resolves image builds or
GPU availability. The pod can progress using Python and podctl while the app is unfinished.
Both streams meet at the existing control agent HTTP API and the shared data formats.

## Dispatch and integration

The available team is the coordinator plus three agents. In the first wave, use those slots
for gateway/core work, pod foundation work and independent review of the coordinator's key
repair. In the delivery wave, use them for the app, pod verification and review/core support.
Do not launch more seats than the runtime supports.

During key review, the core owner starts the Hub/thinking findings in separate files; gateway
resolver edits wait until the key repair is accepted. Review a frozen change, then assess any
later resolver delta. Do not let concurrent edits invalidate the review input.

Dispatch only after Hákon's effort-setting change and launch instruction. Use Codex agents
with the model assignment in the handoff's Conventions section. The coordinator handles
integration and product decisions, keeps ownership explicit, and moves a free seat to necessary
adjacent work when an outcome finishes.

Each assignment names the user-visible outcome, owned paths, consumed contracts, focused
checks and terminal artifact. Shared files have one writer. Authors do not accept their own
repairs. An independent reviewer checks changed behavior and reachable failures with
proportionate evidence; review does not create a separate implementation pipeline.

Commit and push ordinary verified progress to main in this lab repository, without force or
rewriting another publisher's work. Keep independent acceptance, local tests, CI and live
verification as separate claims. Update each stream's status at meaningful boundaries and
preserve unresolved findings. Never put keys or private project material in the repository.

## Integration proof and final artifacts

Connect the Mac to the verified agent through the provider proxy. Demonstrate the full shared
data flow, user-configured endpoint/key behavior, observable failures, cancellation, cost
controls, result publication and pod shutdown. Actual hardware behavior and API outcomes are
recorded separately from automated app checks; the automated agent does not launch the GUI.

Once both streams work, run the same-image comparison from the handoff: trigger-only versus
concept-boundary captions, two LoRAs, an inference grid and a written result. Make conclusions
about caption quality from that evidence rather than promising disentanglement in advance.

Then prepare the second repository's proposed narrative commits from v0.1.0, each building and
passing its tests, ending in a tree identical to the verified one, with the required one-page
decision sheet per commit. Walk those sheets with Hákon before publishing that repository.
This repository remains the exploration record.
