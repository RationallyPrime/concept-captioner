from __future__ import annotations

from pathlib import Path

import pytest
from conftest import approving_critique, h3, synthetic_png

from concept_captioner.endpoints.base import extract_json_object
from concept_captioner.images import provider_image
from concept_captioner.job import Concept, Job
from concept_captioner.policy import build_critique_prompt, build_system_prompt, policy_sha256
from concept_captioner.profiles import load_profile
from concept_captioner.profiles.base import DirectoryProfile
from concept_captioner.schemas import PrimaryResult
from concept_captioner.security import redact_text
from concept_captioner.types import ConfigurationError
from concept_captioner.validation import critique_verdict, exact_trigger_spans, validate_caption


def test_job_rejects_unknown_trigger_in_mapping():
    with pytest.raises(ValueError):
        Job(concepts=[Concept(trigger="A")], samples={"x.png": {"B": "the person"}})


def test_job_rejects_duplicate_triggers_and_blank_locators():
    with pytest.raises(ValueError):
        Job(concepts=[Concept(trigger="A"), Concept(trigger="A")])
    with pytest.raises(ValueError):
        Job(concepts=[Concept(trigger="A")], samples={"x.png": {"A": " "}})


def test_job_roundtrip_yaml(tmp_path: Path):
    example = Path(__file__).parent.parent / "examples" / "job.example.yaml"
    job = Job.load(example)
    assert job.triggers == ["NORA7", "IVAN9"]
    assert job.mapping_for("unmapped.png") is None
    (tmp_path / "job.yaml").write_text(job.dump())
    assert Job.load(tmp_path / "job.yaml") == job


def test_sample_view_only_exposes_mapped_concepts(job):
    view = job.sample_view({"NORA7": "The only person."})
    assert [c["trigger"] for c in view["concepts"]] == ["NORA7"]
    assert view["inputs"]["subject_mapping"] == {"NORA7": "The only person."}


def test_prompt_contains_policy_profile_and_job(job, profile):
    prompt = build_system_prompt(job, profile, {"NORA7": "The only person."})
    assert "# Core Caption Policy" in prompt
    assert "Three fields" in prompt and "[Shot 1]" in prompt
    assert '"subject_mapping": {"NORA7"' in prompt
    assert "API RESPONSE CONTRACT" in prompt
    assert "IVAN9" not in prompt.split("ACTIVE JOB CONFIGURATION")[1].split("API RESPONSE")[0]
    critique = build_critique_prompt(job, profile, {"NORA7": "x"}, "the caption")
    assert "trigger_subject_visible_but_unbound" in critique and '"the caption"' in critique


def test_policy_hash_changes_with_mapping_and_profile(job):
    h3p, plain = load_profile("h3-still"), load_profile("plain")
    a = policy_sha256(job, h3p, {"NORA7": "x"})
    assert a == policy_sha256(job, h3p, {"NORA7": "x"})
    assert a != policy_sha256(job, h3p, {"NORA7": "y"})
    assert a != policy_sha256(job, plain, {"NORA7": "x"})


def test_h3_profile_check_and_wrap():
    profile = load_profile("h3-still")
    body = "A photograph frames NORA7, a woman, by a window."
    wrapped = profile.wrap(body)
    check = profile.check(wrapped)
    assert check.valid and check.body == body and check.word_count > 5
    assert "caption:h3_still_format" in profile.check(body).failures
    assert "caption:still_has_timeline_or_reference" in profile.check(profile.wrap("At 0:12 she turns.")).failures


def test_prose_profiles_reject_h3_fields():
    for name in ("flux-image", "ltx-image", "plain"):
        profile = load_profile(name)
        assert profile.check("NORA7, a woman, sits by a window.").valid
        assert not profile.check(h3("x")).valid
        assert "FLUX" in profile.examples() or "NORA7" in profile.examples()


def test_directory_profile(tmp_path: Path):
    root = tmp_path / "my-trainer"
    root.mkdir()
    (root / "profile.yaml").write_text(
        'name: my-trainer\nwrapper: "CAPTION: {body}"\npattern: "^CAPTION: (?P<body>.+)$"\nforbid: ["\\\\[Shot "]\n'
    )
    (root / "format.md").write_text("# My format\nOne line, prefixed with CAPTION:.")
    profile = load_profile(str(root))
    assert isinstance(profile, DirectoryProfile) and profile.name == "my-trainer"
    wrapped = profile.wrap("NORA7, a woman, smiles.")
    assert wrapped == "CAPTION: NORA7, a woman, smiles."
    assert profile.check(wrapped).valid and profile.check(wrapped).body == "NORA7, a woman, smiles."
    assert not profile.check("NORA7 smiles.").valid
    assert "my-trainer_forbidden_token" in profile.check("CAPTION: [Shot 1] x").failures[0]


def test_unknown_profile():
    with pytest.raises(ConfigurationError):
        load_profile("nope")


def test_trigger_spans_are_whole_word():
    assert exact_trigger_spans("NORA7 and NORA7x and xNORA7", "NORA7") == ((0, 5),)
    assert exact_trigger_spans("Erla, a woman", "Erla") == ((0, 4),)


def test_validate_caption_codes(job, profile):
    mapping = {"NORA7": "x"}
    ok = validate_caption(h3("A photo of NORA7, a woman, by a window."), job=job, profile=profile, mapping=mapping)
    assert ok.valid
    missing = validate_caption(h3("A photo of a woman."), job=job, profile=profile, mapping=mapping)
    assert "caption:missing_trigger:NORA7" in missing.failures
    leaked = validate_caption(h3("NORA7 and IVAN9 together."), job=job, profile=profile, mapping=mapping)
    assert "caption:absent_subject_trigger:IVAN9" in leaked.failures
    payload = PrimaryResult(caption="", human_subject_count=0, mapped_subjects_usable=False, ambiguity_reason="too small")
    bad = validate_caption(h3("NORA7, a woman."), job=job, profile=profile, mapping=mapping, payload=payload)
    assert {"subject:count_mismatch", "subject:not_mapped_subjects_usable", "subject:ambiguity_reported"} <= set(bad.failures)


def test_critique_verdict_consistency(job):
    mapping = {"NORA7": "x"}
    ok, failures = critique_verdict(approving_critique(1), job=job, mapping=mapping)
    assert ok and not failures
    # a critic that approves while flagging is itself inconsistent
    inconsistent = approving_critique(1, quoted_text_present=True)
    ok, failures = critique_verdict(inconsistent, job=job, mapping=mapping)
    assert not ok and "critique:quoted_text_present" in failures and "critique:approved_despite_flags" in failures
    # an unverified claim without the mismatch flag is also inconsistent
    from concept_captioner.schemas import Claim

    sloppy = approving_critique(1, claims=[Claim(claim="red hat", verified=False, note="no hat")])
    ok, failures = critique_verdict(sloppy, job=job, mapping=mapping)
    assert not ok and any(f.startswith("critique:claim_unverified:") for f in failures)


def test_extract_json_object_variants():
    assert extract_json_object('{"a": 1}') == {"a": 1}
    assert extract_json_object('```json\n{"a": 1}\n```') == {"a": 1}
    assert extract_json_object('Sure! {"a": {"b": 2}} done') == {"a": {"b": 2}}
    with pytest.raises(ValueError):
        extract_json_object("no json here")


def test_provider_image_strips_and_caps():
    ref = provider_image(synthetic_png(1), suffix=".png", max_bytes=20_000, max_side=128)
    assert ref.mime == "image/png" and len(ref.data) <= 20_000
    import io

    from PIL import Image

    with Image.open(io.BytesIO(ref.data)) as image:
        assert max(image.size) <= 128
        assert "exif" not in image.info


def test_redaction_covers_common_key_shapes():
    text = "key=AIzaSyA1234567890abcdefghijklmnop and hf_abcdefghijklmnopqrstuvwxyz1234 Bearer abc.def"
    out = redact_text(text, "sekrit")
    assert "AIza" not in out and "hf_abc" not in out and "Bearer [REDACTED]" in out
    assert redact_text("token: sekrit", "sekrit") == "token: [REDACTED]"
