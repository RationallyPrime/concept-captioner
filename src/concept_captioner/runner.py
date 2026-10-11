"""Orchestration: for each sample, caption -> (optional critique, one feedback round) -> write.

Statuses: ``written``, ``skipped`` (already captioned, or human-final), ``needs_mapping``
(no subject mapping in the job; no model call), ``unusable`` (the captioner says the mapped
subject cannot be captioned from this image), ``rejected`` (trigger check or critic failed
after the retry), ``failed`` (a provider error).
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import AsyncIterator, Collection
from dataclasses import dataclass, field
from typing import Any

from pydantic_ai import UnexpectedModelBehavior

from . import skills
from .job import Job
from .models import Resolved
from .prompt import USER_TURN, captioner_instructions, critic_instructions, critic_user_turn
from .skills import Skill
from .sources.base import CaptionSink, ImageSource
from .sources.local import VIDEO_SUFFIXES
from .stages import CaptionDeps, build_captioner, build_critic, image_content, served_model
from .types import Sample


@dataclass(slots=True)
class Outcome:
    sample_id: str
    status: str
    caption: str | None = None
    notes: list[str] = field(default_factory=list)
    record: dict[str, Any] = field(default_factory=dict)


@dataclass(slots=True)
class RunSummary:
    outcomes: list[Outcome]
    elapsed_s: float
    sink: dict[str, Any] = field(default_factory=dict)

    def counts(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for outcome in self.outcomes:
            counts[outcome.status] = counts.get(outcome.status, 0) + 1
        return counts


class Runner:
    def __init__(
        self,
        *,
        job: Job,
        captioner: Resolved,
        critic: Resolved | None = None,
        skill: Skill | None = None,
        profile: str | None = None,
        concurrency: int | None = None,
        overwrite: bool = False,
    ) -> None:
        self.job = job
        self.skill = skill or skills.load(job.skill)
        self.profile_name = profile or job.profile
        self.profile_text = self.skill.profile(self.profile_name)
        self.captioner_spec = captioner
        self.critic_spec = critic
        self.captioner = build_captioner(captioner)
        self.critic = build_critic(critic) if critic else None
        self.overwrite = overwrite
        self._semaphore = asyncio.Semaphore(concurrency or captioner.concurrency)

    async def run(
        self, source: ImageSource, sink: CaptionSink, *, only: Collection[str] | None = None
    ) -> RunSummary:
        started = time.monotonic()
        outcomes = [outcome async for outcome in self.stream(source, sink, only=only)]
        summary = await sink.finalize()
        return RunSummary(outcomes, time.monotonic() - started, summary)

    async def stream(
        self, source: ImageSource, sink: CaptionSink, *, only: Collection[str] | None = None
    ) -> AsyncIterator[Outcome]:
        """Yield each sample's outcome as it completes."""
        wanted = set(only) if only is not None else None
        tasks = []
        async for sample in source.samples():
            if wanted is not None and sample.sample_id not in wanted:
                continue
            tasks.append(asyncio.create_task(self._guarded(sample, sink)))
        for task in asyncio.as_completed(tasks):
            yield await task

    async def _guarded(self, sample: Sample, sink: CaptionSink) -> Outcome:
        async with self._semaphore:
            try:
                return await self._process(sample, sink)
            except (UnexpectedModelBehavior, Exception) as error:  # provider/transport failures
                note = f"{type(error).__name__}: {error}"
                return Outcome(sample.sample_id, "failed", notes=[note])

    def _base_record(self, sample: Sample, status: str) -> dict[str, Any]:
        return {
            "sample_id": sample.sample_id,
            "status": status,
            "source": "model",
            "skill": self.skill.name,
            "profile": self.profile_name,
            "captioner": {"requested": self.captioner_spec.requested, "served": None},
            "critic": {"requested": self.critic_spec.requested, "served": None}
            if self.critic_spec
            else None,
            "attempts": 0,
            "requests": 0,
            "caption": None,
            "critique": None,
        }

    async def _process(self, sample: Sample, sink: CaptionSink) -> Outcome:
        mapping = self.job.mapping_for(sample.sample_id)
        if mapping is None:
            return Outcome(sample.sample_id, "needs_mapping", notes=["no subject mapping"])
        existing = await sink.record(sample.sample_id)
        if existing is not None and existing.get("source") == "human":
            return Outcome(sample.sample_id, "skipped", notes=["human-final"], record=existing)
        if not self.overwrite and await sink.exists(sample.sample_id):
            return Outcome(sample.sample_id, "skipped", record=existing or {})

        record = self._base_record(sample, "rejected")
        image = image_content(sample)
        deps = CaptionDeps(mapping=mapping, triggers=tuple(self.job.triggers))
        instructions = captioner_instructions(
            self.skill,
            self.profile_text,
            self.job,
            mapping,
            is_video=sample.suffix.lower() in VIDEO_SUFFIXES,
        )

        run = await self.captioner.run([USER_TURN, image], instructions=instructions, deps=deps)
        record["attempts"] = 1
        record["requests"] += run.usage.requests
        record["captioner"]["served"] = served_model(run.all_messages())
        record["caption"] = run.output.model_dump()
        if not run.output.usable:
            record["status"] = "unusable"
            notes = [run.output.note] if run.output.note else []
            await sink.write(sample.sample_id, None, record)
            return Outcome(sample.sample_id, "unusable", notes=notes, record=record)

        notes: list[str] = []
        if self.critic is not None:
            review_instructions = critic_instructions(
                self.skill,
                self.profile_text,
                self.job,
                mapping,
                is_video=sample.suffix.lower() in VIDEO_SUFFIXES,
            )
            verdict = await self._review(run.output.caption, image, review_instructions, record)
            if not verdict.approved:
                feedback = "Reviewer notes:\n- " + "\n- ".join(verdict.notes or ["not approved"])
                run = await self.captioner.run(
                    feedback,
                    instructions=instructions,
                    deps=deps,
                    message_history=run.all_messages(),
                )
                record["attempts"] = 2
                record["requests"] += run.usage.requests
                record["captioner"]["served"] = served_model(run.all_messages())
                record["caption"] = run.output.model_dump()
                verdict = await self._review(run.output.caption, image, review_instructions, record)
                if not verdict.approved:
                    notes = list(verdict.notes)
                    await sink.write(sample.sample_id, None, record)
                    return Outcome(sample.sample_id, "rejected", notes=notes, record=record)
            notes = list(verdict.notes)

        record["status"] = "written"
        await sink.write(sample.sample_id, run.output.caption, record)
        return Outcome(sample.sample_id, "written", run.output.caption, notes, record)

    async def _review(self, caption: str, image: Any, instructions: str, record: dict[str, Any]):
        assert self.critic is not None
        result = await self.critic.run(
            [critic_user_turn(caption), image], instructions=instructions
        )
        record["requests"] += result.usage.requests
        record["critic"]["served"] = served_model(result.all_messages())
        record["critique"] = result.output.model_dump()
        return result.output
