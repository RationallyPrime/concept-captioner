"""Mechanical checks that need no model: triggers, format, counts, and the critic's own consistency."""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass

from .job import Job
from .profiles.base import CaptionProfile, FormatCheck, quoted_text_present
from .schemas import CritiqueResult, PrimaryResult


def _is_word_char(char: str) -> bool:
    return char == "_" or unicodedata.category(char)[0] in {"L", "M", "N"}


def exact_trigger_spans(text: str, trigger: str) -> tuple[tuple[int, int], ...]:
    """Whole-word occurrences of ``trigger`` (NFC-normalized, case-sensitive)."""
    spans: list[tuple[int, int]] = []
    start = 0
    while True:
        index = text.find(trigger, start)
        if index < 0:
            return tuple(spans)
        end = index + len(trigger)
        left = index == 0 or not _is_word_char(text[index - 1])
        right = end == len(text) or not _is_word_char(text[end])
        if left and right:
            spans.append((index, end))
        start = index + 1


@dataclass(frozen=True, slots=True)
class Validation:
    failures: tuple[str, ...]
    format: FormatCheck

    @property
    def valid(self) -> bool:
        return not self.failures


def validate_caption(
    caption: str,
    *,
    job: Job,
    profile: CaptionProfile,
    mapping: dict[str, str],
    payload: PrimaryResult | None = None,
) -> Validation:
    text = unicodedata.normalize("NFC", caption)
    check = profile.check(text)
    failures = list(check.failures)
    for trigger in mapping:
        if not exact_trigger_spans(text, unicodedata.normalize("NFC", trigger)):
            failures.append(f"caption:missing_trigger:{trigger}")
    for trigger in job.triggers:
        if trigger not in mapping and exact_trigger_spans(text, trigger):
            failures.append(f"caption:absent_subject_trigger:{trigger}")
    if check.word_count < job.minimum_caption_words:
        failures.append(f"caption:below_minimum_words:{check.word_count}/{job.minimum_caption_words}")
    if quoted_text_present(check.body):
        failures.append("caption:quoted_text")
    if payload is not None:
        minimum = len(mapping)
        if payload.human_subject_count < minimum or (
            job.single_subject_only and payload.human_subject_count != 1
        ):
            failures.append("subject:count_mismatch")
        if not payload.mapped_subjects_usable:
            failures.append("subject:not_mapped_subjects_usable")
        if payload.ambiguity_reason:
            failures.append("subject:ambiguity_reported")
        if payload.concept_boundary_violation:
            failures.append("subject:self_reported_concept_boundary_violation")
        if payload.subject_binding_violation:
            failures.append("subject:self_reported_binding_violation")
    return Validation(tuple(dict.fromkeys(failures)), check)


CRITIQUE_FLAGS = (
    "concept_boundary_violation",
    "unsupported_inference",
    "subject_ambiguity",
    "image_caption_mismatch",
    "another_person_described_as_trigger",
    "trigger_subject_visible_but_unbound",
    "quoted_text_present",
)


def critique_verdict(critique: CritiqueResult, *, job: Job, mapping: dict[str, str]) -> tuple[bool, tuple[str, ...]]:
    """Turn a critique into (approved, failure codes), checking the critic's own consistency."""
    failures: list[str] = []
    for flag in CRITIQUE_FLAGS:
        if getattr(critique, flag):
            failures.append(f"critique:{flag}")
    if not critique.claims:
        failures.append("critique:empty_claim_ledger")
    unverified = [claim for claim in critique.claims if not claim.verified]
    if unverified and not critique.image_caption_mismatch:
        failures.append("critique:unverified_claims_without_mismatch_flag")
    if unverified:
        failures.extend(f"critique:claim_unverified:{claim.claim[:80]}" for claim in unverified)
    if not critique.reasons:
        failures.append("critique:no_reasons")
    if not critique.approved:
        failures.append("critique:not_approved")
    minimum = len(mapping)
    if critique.human_subject_count < minimum or (
        job.single_subject_only and critique.human_subject_count != 1
    ):
        failures.append("critique:subject_count_mismatch")
    if not critique.mapped_subjects_usable:
        failures.append("critique:not_mapped_subjects_usable")
    if critique.ambiguity_reason:
        failures.append("critique:ambiguity_reported")
    if critique.approved and failures:
        failures.append("critique:approved_despite_flags")
    return (not failures), tuple(dict.fromkeys(failures))
