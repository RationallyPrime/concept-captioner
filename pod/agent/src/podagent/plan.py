"""The GPU topology rule (POD-SPEC §2.5), computed here and nowhere else.

The owner's rule:

| GPUs   | caption only | train only            | both                                          |
| ------ | ------------ | --------------------- | --------------------------------------------- |
| 0      | 400 no GPUs  | same                  | same                                          |
| 1      | vLLM on [0]  | trainer on [0]        | sequential: vLLM on [0], stop it, trainer [0] |
| N >= 2 | vLLM on [0]  | trainer on [1..N-1]   | concurrent: vLLM on [0], trainer on [1..N-1]  |

GPU 0 stays reserved for captioning whenever there is more than one GPU, even for a
train-only plan, so a re-caption can run during training. The plan is advisory: the supervisor
enforces only no-double-booking, so a caller who wants all N GPUs for a train-only run passes
``gpus: [0..N-1]`` to the start call explicitly.

``train.service`` is the generic ``trainer``; the app substitutes ``trainer-aitoolkit`` or
``trainer-ltx`` from the service catalog.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from .errors import BadRequest

__all__ = [
    "CAPTION_SERVICE",
    "MAX_GPUS",
    "TRAIN_SERVICE",
    "Assignment",
    "PlanRequest",
    "PlanResponse",
    "Step",
    "plan",
]

CAPTION_SERVICE = "vllm"
TRAIN_SERVICE = "trainer"

# Ceiling on the GPU count a plan is computed for. The trainer assignment materialises
# ``range(1, count)``, and the agent is PID 1 in the container: an unbounded count from a
# client body (or a corrupt inventory) would let one request allocate gigabytes and get the
# agent OOM-killed, taking every running service with it. No single pod has anywhere near
# this many GPUs (RunPod tops out at 8).
MAX_GPUS = 64

Mode = Literal["sequential", "concurrent", "single"]
Action = Literal["start", "stop"]


class PlanRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    caption: bool = False
    train: bool = False
    # Optional override of the inventory size: the app plans before the pod exists.
    gpu_count: int | None = Field(default=None, ge=0, le=MAX_GPUS)


class Assignment(BaseModel):
    service: str  # CAPTION_SERVICE | TRAIN_SERVICE
    gpus: list[int]


class Step(BaseModel):
    action: Action
    service: str


class PlanResponse(BaseModel):
    gpu_count: int
    mode: Mode
    caption: Assignment | None
    train: Assignment | None
    order: list[Step]


def plan(request: PlanRequest, gpu_count: int) -> PlanResponse:
    """Apply the rule for ``gpu_count`` GPUs (``request.gpu_count`` overrides when given).

    Raises ``BadRequest`` when neither caption nor train is requested, or when the effective
    GPU count is zero. The effective count is clamped to ``MAX_GPUS`` so the assignment lists
    stay bounded whatever the inventory backend reports.
    """
    if not (request.caption or request.train):
        raise BadRequest(
            "plan requires caption and/or train",
            detail={"caption": request.caption, "train": request.train},
        )

    count = gpu_count if request.gpu_count is None else request.gpu_count
    if count <= 0:
        raise BadRequest("no GPUs", detail={"gpu_count": count})
    count = min(count, MAX_GPUS)

    caption = Assignment(service=CAPTION_SERVICE, gpus=[0]) if request.caption else None
    train: Assignment | None = None
    if request.train:
        # One GPU: the trainer takes it after vLLM is stopped. Two or more: GPU 0 is vLLM's.
        train_gpus = [0] if count == 1 else list(range(1, count))
        train = Assignment(service=TRAIN_SERVICE, gpus=train_gpus)

    mode: Mode
    if caption is not None and train is not None:
        if count == 1:
            mode = "sequential"
            order = [
                Step(action="start", service=caption.service),
                Step(action="stop", service=caption.service),
                Step(action="start", service=train.service),
            ]
        else:
            mode = "concurrent"
            order = [
                Step(action="start", service=caption.service),
                Step(action="start", service=train.service),
            ]
    else:
        mode = "single"
        only = caption if caption is not None else train
        assert only is not None  # one of the two was requested (checked above)
        order = [Step(action="start", service=only.service)]

    return PlanResponse(gpu_count=count, mode=mode, caption=caption, train=train, order=order)
