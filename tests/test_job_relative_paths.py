from pathlib import Path

from conftest import function_model

from concept_captioner.cli import main
from concept_captioner.job import Job
from concept_captioner.runner import Runner


def project(tmp_path: Path):
    root = tmp_path / "project"
    (root / "skill" / "my-skill").mkdir(parents=True)
    (root / "skill" / "my-skill" / "SKILL.md").write_text(
        "---\nname: my-skill\ndescription: Local.\n---\nPROJECT SKILL\n"
    )
    (root / "profile.md").write_text("PROJECT FORMAT")
    path = root / "job.yaml"
    path.write_text(
        "skill: ./skill/my-skill\nprofile: ./profile.md\nconcepts:\n- trigger: NORA7\nsamples:\n  clip.mp4:\n    NORA7: subject\n"
    )
    return path


def test_job_relative_paths_work_outside_project_and_are_not_serialized(
    tmp_path, monkeypatch, capsys
):
    path = project(tmp_path)
    monkeypatch.chdir(tmp_path)
    job = Job.load(path)
    runner = Runner(job=job, captioner=function_model(lambda *_: "unused"))
    assert runner.skill.body.strip() == "PROJECT SKILL"
    assert runner.profile_text == "PROJECT FORMAT"
    assert job.directory == path.parent
    assert "directory" not in job.model_dump()
    assert job == Job.model_validate(job.model_dump())
    assert main(["validate", str(path)]) == 0
    assert main(["show-prompt", str(path), "clip.mp4"]) == 0
    output = capsys.readouterr().out
    assert "PROJECT SKILL" in output and "PROJECT FORMAT" in output
    assert '"evidence": "attached_target_video"' in output


def test_explicit_profile_override_resolves_from_cwd(tmp_path, monkeypatch):
    path = project(tmp_path)
    (tmp_path / "override.md").write_text("CLI OVERRIDE")
    monkeypatch.chdir(tmp_path)
    runner = Runner(
        job=Job.load(path), captioner=function_model(lambda *_: "unused"), profile="./override.md"
    )
    assert runner.profile_text == "CLI OVERRIDE"
