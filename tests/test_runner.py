from __future__ import annotations

import json
from pathlib import Path

import pytest
from conftest import approving_critique, good_caption_for, h3, primary_responder

from concept_captioner.endpoints import build_endpoint
from concept_captioner.endpoints.fake import FakeEndpoint
from concept_captioner.runner import Runner
from concept_captioner.schemas import CritiqueResult, PrimaryResult
from concept_captioner.sources.local import LocalFolderSource, SidecarSink
from concept_captioner.types import Request


async def _run(job, profile, images: Path, out: Path, captioner, critic=None):
    runner = Runner(job=job, profile=profile, captioner_endpoint=captioner, critic_endpoint=critic)
    return await runner.run(LocalFolderSource(images), SidecarSink(out))


async def test_happy_path_commits_only_mapped_samples(job, profile, images, tmp_path):
    endpoint = FakeEndpoint(primary_responder)
    summary = await _run(job, profile, images, tmp_path / "out", endpoint)
    assert summary.counts() == {"ready": 2, "needs_mapping": 1}
    out = tmp_path / "out"
    assert (out / "solo.txt").exists() and (out / "pair.txt").exists()
    assert not (out / "unmapped.txt").exists()
    receipt = json.loads((out / "_receipts" / "pair.json").read_text())
    assert receipt["status"] == "ready"
    assert receipt["claims"], "approval without a claim ledger must not commit"
    assert receipt["binding"]["image_sha256"]
    assert "NORA7" in (out / "pair.txt").read_text() and "IVAN9" in (out / "pair.txt").read_text()


async def test_resume_skips_bound_captions_and_refuses_changed_jobs(job, profile, images, tmp_path):
    endpoint = FakeEndpoint(primary_responder)
    await _run(job, profile, images, tmp_path / "out", endpoint)
    calls = len(endpoint.requests)
    summary = await _run(job, profile, images, tmp_path / "out", endpoint)
    assert summary.counts() == {"skipped": 2, "needs_mapping": 1}
    assert len(endpoint.requests) == calls, "resume must not call the provider"
    # change the job: a different mapping sentence changes the policy hash
    changed = job.model_copy(update={"samples": {**job.samples, "solo.png": {"NORA7": "The person."}}})
    summary = await _run(changed, profile, images, tmp_path / "out", endpoint)
    solo = next(o for o in summary.outcomes if o.sample_id == "solo.png")
    assert solo.status == "failed" and solo.issues[0].startswith("integrity:")
    assert (tmp_path / "out" / "solo.txt").read_text().startswith("integrated_multimodal_description")


async def test_model_mismatch_fails_the_sample(job, profile, images, tmp_path):
    endpoint = FakeEndpoint(primary_responder, model="good-model", served_model="lite-preview")
    summary = await _run(job, profile, images, tmp_path / "out", endpoint)
    assert summary.counts().get("ready") is None
    solo = next(o for o in summary.outcomes if o.sample_id == "solo.png")
    assert any(issue.startswith("model_mismatch:captioner:lite-preview") for issue in solo.issues)
    assert not (tmp_path / "out" / "solo.txt").exists()


async def test_model_mismatch_can_be_waived(job, profile, images, tmp_path):
    waived = job.model_copy(update={"require_model_match": False})
    endpoint = FakeEndpoint(primary_responder, model="good-model", served_model="lite-preview")
    summary = await _run(waived, profile, images, tmp_path / "out", endpoint)
    assert summary.counts()["ready"] == 2


async def test_unbound_trigger_subject_blocks_commit(job, profile, images, tmp_path):
    def responder(request: Request):
        if request.response_schema is PrimaryResult:
            return primary_responder(request)
        count = 2 if "IVAN9" in request.system else 1
        return approving_critique(count, approved=False, trigger_subject_visible_but_unbound=True,
                                  reasons=["a woman matching NORA7's locator is visible at the left edge but unnamed"])

    summary = await _run(job, profile, images, tmp_path / "out", FakeEndpoint(responder))
    assert summary.counts() == {"needs_review": 2, "needs_mapping": 1}
    solo = next(o for o in summary.outcomes if o.sample_id == "solo.png")
    assert "critique:trigger_subject_visible_but_unbound" in solo.issues
    assert solo.attempts == job.max_caption_attempts


async def test_empty_claim_ledger_is_not_an_approval(job, profile, images, tmp_path):
    def responder(request: Request):
        if request.response_schema is PrimaryResult:
            return primary_responder(request)
        return approving_critique(2 if "IVAN9" in request.system else 1, claims=[])

    summary = await _run(job, profile, images, tmp_path / "out", FakeEndpoint(responder))
    solo = next(o for o in summary.outcomes if o.sample_id == "solo.png")
    assert solo.status == "needs_review" and "critique:empty_claim_ledger" in solo.issues


async def test_quoted_text_is_rejected_mechanically(job, profile, images, tmp_path):
    def responder(request: Request):
        if request.response_schema is PrimaryResult:
            return PrimaryResult(
                caption=h3('A photograph frames NORA7, a woman, holding a bottle labelled "MALTEXTRAKT".'),
                human_subject_count=1, mapped_subjects_usable=True)
        return approving_critique(1)

    summary = await _run(job, profile, images, tmp_path / "out", FakeEndpoint(responder))
    solo = next(o for o in summary.outcomes if o.sample_id == "solo.png")
    assert "caption:quoted_text" in solo.issues


async def test_feedback_is_sent_on_retry(job, profile, images, tmp_path):
    seen: list[str] = []

    def responder(request: Request):
        if request.response_schema is PrimaryResult:
            seen.append(request.system)
            if "caption:missing_trigger" in request.system:
                return primary_responder(request)
            return PrimaryResult(caption=h3("A woman sits by a window."), human_subject_count=1, mapped_subjects_usable=True)
        return approving_critique(2 if "IVAN9" in request.system else 1)

    summary = await _run(job, profile, images, tmp_path / "out", FakeEndpoint(responder))
    solo = next(o for o in summary.outcomes if o.sample_id == "solo.png")
    assert solo.status == "ready" and solo.attempts == 2
    assert any("caption:missing_trigger:NORA7" in s for s in seen)


async def test_critic_can_be_a_different_endpoint(job, profile, images, tmp_path):
    captioner = FakeEndpoint(primary_responder, model="captioner-model")
    critic_calls = []

    def critic_responder(request: Request):
        critic_calls.append(request)
        return approving_critique(2 if "IVAN9" in request.system else 1)

    critic = FakeEndpoint(critic_responder, model="critic-model")
    summary = await _run(job, profile, images, tmp_path / "out", captioner, critic)
    assert summary.counts()["ready"] == 2
    assert all(r.response_schema is CritiqueResult for r in critic_calls)
    assert all(r.response_schema is PrimaryResult for r in captioner.requests)
    receipt = json.loads((tmp_path / "out" / "_receipts" / "solo.json").read_text())
    assert receipt["binding"]["critic_model"] == "critic-model"


async def test_schema_enforcer_handles_unstructured_backends(job, profile, images, tmp_path):
    def responder(request: Request):
        # an unstructured backend sees the schema in the prompt and returns prose + fenced JSON
        assert request.response_schema is None and '"title": "' in request.system
        if '"title": "CritiqueResult"' in request.system:
            return "Here you go:\n```json\n" + approving_critique(2 if "IVAN9" in request.system else 1).model_dump_json() + "\n```"
        caption = good_caption_for(request)
        primary = PrimaryResult(caption=caption, human_subject_count=2 if "IVAN9" in caption else 1, mapped_subjects_usable=True)
        return "```json\n" + primary.model_dump_json() + "\n```"

    raw = FakeEndpoint(responder, structured_output=False)
    endpoint = build_endpoint({"kind": "fake", "model": "x", "responder": responder, "structured_output": False}, retries=1)
    assert endpoint.capabilities.structured_output
    summary = await _run(job, profile, images, tmp_path / "out", endpoint)
    assert summary.counts()["ready"] == 2
    assert not raw.requests  # the registry built its own instance


@pytest.mark.parametrize("spec,kind,model", [
    ("gemini:gemini-3.8-flash", "gemini", "gemini-3.8-flash"),
    ("openai:http://localhost:8000/v1#Qwen/Qwen3-VL-32B-Instruct", "openai", "Qwen/Qwen3-VL-32B-Instruct"),
    ("transformers:Qwen/Qwen3-VL-8B-Instruct", "transformers", "Qwen/Qwen3-VL-8B-Instruct"),
])
def test_parse_spec(spec, kind, model):
    from concept_captioner.endpoints import parse_spec

    parsed = parse_spec(spec)
    assert parsed["kind"] == kind and parsed["model"] == model
    if kind == "openai":
        assert parsed["base_url"] == "http://localhost:8000/v1"
