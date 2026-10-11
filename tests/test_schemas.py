from concept_captioner.schemas import Caption


def test_usability_describes_declared_target_without_person_requirement():
    schema = Caption.model_json_schema()
    assert schema["properties"]["usable"]["description"] == (
        "False when the declared training target cannot be found in the sample. "
        "Then leave the caption empty and explain in note."
    )
    assert Caption(caption="STYLE8, a landscape.").usable
