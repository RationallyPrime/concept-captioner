# Pod side: verify-and-harden brief

The control agent, command-line client and trainer wrappers have offline tests. The original
images also completed small real-GPU checks on 2026-10-10. New code is not covered by that
historical evidence: each deployed image must be tied to the source and operations actually
checked. POD-SPEC.md states the contract; POD-STATUS.md records current proof and gaps. When
runtime behavior disagrees with the contract, repair the implementation and record the finding.

## Requirements to hold the pod to

- Run only fixed catalog commands with validated parameters. Client input cannot redirect
  service paths, credentials or network exposure. vLLM flags and LTX preprocessing options
  use explicit allowlists.
- No token, no agent. Files, logs, controls and TensorBoard require authenticated access.
- One GPU means caption, release its memory, then train or generate. With several GPUs,
  captioning uses GPU 0 and training uses the remaining devices. Refuse double-booking.
- Train only the published, included media. Preserve its recorded dataset revision. Approved
  clips must reach preprocessing with the selected frames, timing and visible scene intact.
- Preserve checkpoints and outputs on saved storage. Generation compares the same prompt,
  seed and settings with and without the chosen LoRA. Resume uses the trainer's actual
  checkpoint support; no successful placeholder output counts as proof.
- Use synthetic or explicitly authorized test data. Bound operational checks; do not turn them
  into a quality-training campaign. Secure outputs and stop paid compute when useful work ends.
- Ordinary commits and pushes to the lab repository are authorized. Re-staging remains deferred
  until Hákon requests it.

## What must be shown to work, in order

1. **Build and publish:** build current images on the Docker host, push dated tags, verify
   anonymous retrieval by digest, and check the fake-GPU compose health/auth path.
2. **Control a real pod:** inventory, plan, start, status, logs and stop through the provider
   proxy. Check new file-download and TensorBoard-session endpoints on the current image.
3. **Caption actual inputs:** verify structured image captions through vLLM; verify supported
   video captioning receives the exact selected clip, with unsupported routes explained.
4. **Train and retrieve:** pull the recorded dataset; make bounded image/video trainer runs;
   read curves, resume a supported checkpoint, publish and download real model bytes.
5. **Generate and allocate:** produce matched base/LoRA outputs and retrieve their manifest and
   media; prove sequential memory release and multi-GPU isolation on the supported routes.
6. **Expose the verified images:** use the published trainer images in the app and keep the
   reusable RunPod template's documented image consistent with its verified version.
7. **Report:** distinguish source tests, current-image live checks and pending human acceptance
   in POD-STATUS.md. Record image digests, inputs, hardware, outputs, cost and stopped resources.
