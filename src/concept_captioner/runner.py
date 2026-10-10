"""Orchestration: for each sample, caption -> mechanical validation -> critique -> commit.

Guarantees:
- A caption is committed only after the critic approves it with a non-empty claim ledger.
- A served model that differs from the requested one fails the attempt (``model_mismatch``),
  unless the job sets ``require_model_match: false``.
- Every attempt's receipt is written before the next provider call, so an interrupted run
  leaves the caption response on disk even if the critique never happened.
- Resume: an existing committed caption is kept only if its receipt binds to the same image
  bytes and the same policy hash; otherwise the sample fails with ``integrity`` and nothing is
  overwritten.
"""

from __future__ import annotations

import asyncio
import hashlib
import time
from dataclasses import dataclass, field
from typing import Any

from .endpoints.base import ModelEndpoint
from .job import Job
from .policy import POLICY_VERSION, policy_sha256
from .profiles.base import CaptionProfile
from .sources.base import CaptionSink, ImageSource
from .stages import Captioner, Critic
from .types import EndpointError, IntegrityError, Sample
from .validation import critique_verdict, validate_caption


@dataclass(slots=True)
class Outcome:
    sample_id: str
    status: str  # ready | skipped | needs_review | needs_mapping | failed
    issues: list[str] = field(default_factory=list)
    attempts: int = 0
    caption: str | None = None


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


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Runner:
    def __init__(
        self,
        *,
        job: Job,
        profile: CaptionProfile,
        captioner_endpoint: ModelEndpoint,
        critic_endpoint: ModelEndpoint | None = None,
        concurrency: int = 4,
    ) -> None:
        self.job = job
        self.profile = profile
        self.captioner = Captioner(captioner_endpoint, profile)
        self.critic = Critic(critic_endpoint or captioner_endpoint, profile)
        self._semaphore = asyncio.Semaphore(concurrency)

    async def run(self, source: ImageSource, sink: CaptionSink, *, dry_run: bool = False) -> RunSummary:
        started = time.monotonic()
        tasks = []
        async for sample in source.samples():
            tasks.append(asyncio.create_task(self._guarded(sample, sink, dry_run)))
        outcomes = await asyncio.gather(*tasks)
        summary = {} if dry_run else await sink.finalize()
        return RunSummary(list(outcomes), time.monotonic() - started, summary)

    async def _guarded(self, sample: Sample, sink: CaptionSink, dry_run: bool) -> Outcome:
        async with self._semaphore:
            try:
                return await self._process(sample, sink, dry_run)
            except IntegrityError as error:
                return Outcome(sample.sample_id, "failed", [f"integrity:{error}"])

    def _binding(self, sample: Sample, mapping: dict[str, str] | None) -> dict[str, Any]:
        return {
            "sample_id": sample.sample_id,
            "image_sha256": sample.sha256,
            "policy_version": POLICY_VERSION,
            "profile": self.profile.name,
            "captioner_model": self.captioner.endpoint.model,
            "critic_model": self.critic.endpoint.model,
            "policy_sha256": policy_sha256(self.job, self.profile, mapping) if mapping else None,
        }

    async def _process(self, sample: Sample, sink: CaptionSink, dry_run: bool) -> Outcome:
        mapping = self.job.mapping_for(sample.sample_id)
        binding = self._binding(sample, mapping)
        existing = await sink.existing(sample.sample_id)
        if existing is not None:
            caption, receipt = existing
            if mapping is None or receipt.get("binding") != binding or receipt.get("status") != "ready":
                raise IntegrityError(
                    f"{sample.sample_id}: existing caption was produced under a different job; use a new output"
                )
            if receipt.get("caption_sha256") != _sha(caption.encode("utf-8")):
                raise IntegrityError(f"{sample.sample_id}: existing caption does not match its receipt")
            return Outcome(sample.sample_id, "skipped", caption=caption)
        if mapping is None:
            if not dry_run:
                await sink.write_receipt(
                    sample.sample_id,
                    {"binding": binding, "status": "needs_mapping", "attempts": [], "issues": ["missing_subject_mapping"]},
                )
            return Outcome(sample.sample_id, "needs_mapping", ["missing_subject_mapping"])
        if dry_run:
            return Outcome(sample.sample_id, "needs_review", ["dry_run"])

        receipt: dict[str, Any] = {"binding": binding, "status": "needs_review", "attempts": [], "issues": []}
        feedback: tuple[str, ...] = ()
        final_issues: list[str] = []
        for attempt_number in range(1, self.job.max_caption_attempts + 1):
            attempt: dict[str, Any] = {"n": attempt_number}
            receipt["attempts"].append(attempt)
            try:
                primary = await self.captioner.caption(sample, self.job, mapping, feedback=feedback)
            except EndpointError as error:
                attempt["captioner_error"] = str(error)
                receipt["issues"] = [str(error)]
                await sink.write_receipt(sample.sample_id, receipt)
                return Outcome(sample.sample_id, "failed", [str(error)], attempt_number)
            attempt["captioner"] = {
                "served_model": primary.response.served_model,
                "latency_ms": primary.response.latency_ms,
                "request_sha256": primary.response.request_sha256,
                "model_mismatch": primary.model_mismatch,
                "parsed": primary.parsed.model_dump() if primary.parsed else None,
                "text": primary.response.text,
            }
            await sink.write_receipt(sample.sample_id, receipt)  # caption saved before critique
            issues = list(primary.issues)
            if primary.model_mismatch and self.job.require_model_match:
                issues.append(f"model_mismatch:captioner:{primary.response.served_model}")
            if primary.parsed is None or issues:
                feedback = tuple(issues) or ("captioner:invalid_payload",)
                attempt["issues"] = list(feedback)
                final_issues = list(feedback)
                continue
            check = validate_caption(
                primary.parsed.caption, job=self.job, profile=self.profile, mapping=mapping, payload=primary.parsed
            )
            attempt["validation"] = list(check.failures)
            if not check.valid:
                feedback = check.failures
                final_issues = list(check.failures)
                if not primary.parsed.mapped_subjects_usable or primary.parsed.ambiguity_reason:
                    break  # the captioner says the sample is unusable from this mapping; stop
                continue
            try:
                critique = await self.critic.critique(sample, self.job, mapping, primary.parsed.caption)
            except EndpointError as error:
                attempt["critic_error"] = str(error)
                receipt["issues"] = [str(error)]
                await sink.write_receipt(sample.sample_id, receipt)
                return Outcome(sample.sample_id, "failed", [str(error)], attempt_number)
            attempt["critic"] = {
                "served_model": critique.response.served_model,
                "latency_ms": critique.response.latency_ms,
                "request_sha256": critique.response.request_sha256,
                "model_mismatch": critique.model_mismatch,
                "parsed": critique.parsed.model_dump() if critique.parsed else None,
                "text": critique.response.text,
            }
            issues = list(critique.issues)
            if critique.model_mismatch and self.job.require_model_match:
                issues.append(f"model_mismatch:critic:{critique.response.served_model}")
            if critique.parsed is not None:
                approved, failures = critique_verdict(critique.parsed, job=self.job, mapping=mapping)
                issues.extend(failures)
            else:
                approved = False
            attempt["issues"] = issues
            if approved and not issues:
                caption = primary.parsed.caption
                receipt.update(
                    status="ready",
                    caption_sha256=_sha(caption.encode("utf-8")),
                    issues=[],
                    claims=[claim.model_dump() for claim in critique.parsed.claims],
                )
                await sink.commit(sample.sample_id, caption, receipt)
                return Outcome(sample.sample_id, "ready", [], attempt_number, caption)
            feedback = tuple(issues)
            final_issues = issues
        receipt["issues"] = final_issues
        await sink.write_receipt(sample.sample_id, receipt)
        return Outcome(sample.sample_id, "needs_review", final_issues, len(receipt["attempts"]))
