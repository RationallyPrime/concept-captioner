# Pod side: verify-and-harden brief

Everything under `pod/` was built without a GPU, Docker or network: the control agent, `podctl`
and the scripts are tested against fakes and mocks, the images were only read. `POD-SPEC.md` is
the design, `POD-STATUS.md` says what exists and where the `# VERIFY` marks are. This brief is
the work that needs real hardware. Where reality disagrees with the spec, change the code and
the spec and say so.

## Requirements to hold the pod to

- The agent only ever runs commands from its fixed catalog with validated parameters. No
  client-supplied value may change where a service reads or writes, or its network or
  authentication surface. (Two known gaps: the vLLM extra-flags list and the LTX preprocess
  arguments are currently free-form. Close them first, with tests.)
- No token, no agent. Everything reachable only over the authenticated API.
- The GPU rule: one GPU means caption then train, sequentially; two or more means captioning on
  GPU 0 and training on the rest, concurrently; double-booking is refused.
- Placeholder triggers only (NORA7 / IVAN9); no real names anywhere.
- Nothing is committed to git; Hákon re-stages the history later.

## What must be shown to work, in order

1. **The images build** (on cx53, which has Docker; the Mac does not) and are pushed to a
   registry. The fake-GPU compose setup comes up on cx53 and answers a health check.
2. **The agent on a real pod**: inventory, plan, start, status, logs, stop, all through the
   provider's proxied URL, on a one-GPU and a two-GPU pod. Services actually stop.
3. **Captioning against the pod**: vLLM on GPU 0 serving a vision model, the Python package
   captioning a small set through it, native structured output or the prompted fallback.
4. **Data in, both trainers, data out**: pull a small dataset from the Hub, run each trainer to
   its first checkpoint on a tiny run, read training curves through the agent, push the LoRA to a
   model repo. This resolves the `# VERIFY` marks.
5. **The GPU rule for real**: sequential on one GPU with VRAM actually freed in between;
   concurrent on two with device isolation holding.
6. **Published**: the base image as a RunPod template.
7. **Reported**: a "verified on a real pod" section in `POD-STATUS.md` with what ran, on what,
   what changed, what is still unverified, and what it cost.
