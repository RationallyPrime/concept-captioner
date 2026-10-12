from pathlib import Path

import pytest
from conftest import function_model

from concept_captioner.cli import main
from concept_captioner.job import Job
from concept_captioner.runner import Runner
from concept_captioner.types import ConfigurationError


def test_empty_concepts_are_a_valid_project_draft_but_not_a_caption_run(tmp_path: Path, capsys):
    path = tmp_path / "job.yaml"
    Job(concepts=[]).save(path)

    loaded = Job.load(path)
    assert loaded.concepts == []
    assert "concepts: []" in path.read_text(encoding="utf-8")
    assert main(["validate", str(path)]) == 0
    assert '"triggers": []' in capsys.readouterr().out

    with pytest.raises(ConfigurationError, match=r"Add a concept before captioning or training\."):
        Runner(job=loaded, captioner=function_model(lambda *_: "unused"))
