"""The two model-facing stages: Captioner and Critic. Each is an endpoint plus a profile."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .endpoints.base import ModelEndpoint
from .images import provider_image
from .job import Job
from .policy import build_critique_prompt, build_system_prompt
from .profiles.base import CaptionProfile
from .schemas import CritiqueResult, PrimaryResult
from .types import Request, Response, Sample

USER_TURN = (
    "Inspect this exact target image. Return only the configured JSON object; "
    "JSON-escape caption line breaks."
)


@dataclass(slots=True)
class StageResult:
    response: Response
    parsed: Any | None
    model_mismatch: bool
    issues: list[str] = field(default_factory=list)


class Captioner:
    def __init__(self, endpoint: ModelEndpoint, profile: CaptionProfile) -> None:
        self.endpoint = endpoint
        self.profile = profile

    async def caption(
        self,
        sample: Sample,
        job: Job,
        mapping: dict[str, str],
        *,
        feedback: tuple[str, ...] = (),
    ) -> StageResult:
        system = build_system_prompt(job, self.profile, mapping)
        if feedback:
            system += (
                "\n\nThe prior attempt failed validation. Correct every code below without "
                "weakening the canonical rules:\n- " + "\n- ".join(feedback) + "\n"
            )
        request = Request(
            system=system,
            user=USER_TURN,
            images=(provider_image(sample.data, suffix=sample.suffix),),
            response_schema=PrimaryResult,
            thinking=job.captioner_thinking,
        )
        response = await self.endpoint.describe(request)
        parsed = response.parsed if isinstance(response.parsed, PrimaryResult) else None
        issues = [] if parsed is not None else ["captioner:invalid_payload"]
        return StageResult(response, parsed, not response.model_matches, issues)


class Critic:
    def __init__(self, endpoint: ModelEndpoint, profile: CaptionProfile) -> None:
        self.endpoint = endpoint
        self.profile = profile

    async def critique(
        self, sample: Sample, job: Job, mapping: dict[str, str], caption: str
    ) -> StageResult:
        request = Request(
            system=build_critique_prompt(job, self.profile, mapping, caption),
            user=(
                "Audit the proposed caption against this exact target image. Build the claim "
                "ledger, then set every flag. Return only the critique JSON object."
            ),
            images=(provider_image(sample.data, suffix=sample.suffix),),
            response_schema=CritiqueResult,
            thinking=job.critic_thinking,
        )
        response = await self.endpoint.describe(request)
        parsed = response.parsed if isinstance(response.parsed, CritiqueResult) else None
        issues = [] if parsed is not None else ["critic:invalid_payload"]
        return StageResult(response, parsed, not response.model_matches, issues)
