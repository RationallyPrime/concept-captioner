import hashlib
import json
from pathlib import Path
from typing import get_args

from concept_captioner import skills
from concept_captioner.job import Concept, Job, TargetConcept
from concept_captioner.prompt import (
    USER_TURN,
    captioner_instructions,
    critic_instructions,
    critic_user_turn,
)


def test_all_seven_categories_and_video_use_shared_swift_python_reference():
    reference = json.loads(
        (Path(__file__).parent / "fixtures" / "category-video-parity.json").read_text()
    )
    assert reference["user_turn"] == USER_TURN
    assert reference["critic_user_turn"] == critic_user_turn("sample caption")
    assert {(case["category"], case["video"]) for case in reference["cases"]} == {
        (category, video) for category in get_args(TargetConcept) for video in (False, True)
    }
    skill = skills.load()
    for case in reference["cases"]:
        concept = Concept(trigger="NORA7", target_concept=case["category"])
        assert concept.model_dump() == case["concept"]
        job = Job(profile="plain", concepts=[concept])
        for role, assemble in (
            ("captioner", captioner_instructions),
            ("critic", critic_instructions),
        ):
            text = assemble(
                skill,
                skill.profile("plain"),
                job,
                {"NORA7": "The mapped target."},
                is_video=case["video"],
            )
            assert len(text) == case[role]["scalars"]
            assert hashlib.sha256(text.encode()).hexdigest() == case[role]["sha256"]
