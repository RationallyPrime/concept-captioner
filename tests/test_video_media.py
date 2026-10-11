from pathlib import Path

import pytest

from concept_captioner import skills
from concept_captioner.job import Concept, Job
from concept_captioner.prompt import captioner_instructions, critic_instructions
from concept_captioner.sources.hf import HFDatasetSink, HFDatasetSource, _encode
from concept_captioner.sources.local import LocalFolderSource
from concept_captioner.stages import image_content
from concept_captioner.types import ConfigurationError, Sample


@pytest.mark.asyncio
async def test_selected_video_bytes_and_sample_ids_are_preserved(tmp_path: Path):
    data = b"exact-selected-segment"
    (tmp_path / "clip.mp4").write_bytes(data)
    (tmp_path / "image.png").write_bytes(b"image")
    source = LocalFolderSource(tmp_path)
    assert source.sample_ids == ["clip.mp4", "image.png"]
    sample = await anext(source.samples())
    content = image_content(sample)
    assert content.is_video
    assert content.data == data
    assert content.media_type == "video/mp4"
    assert content.vendor_metadata == {"fps": 24}
    (tmp_path / "clip.png").write_bytes(b"image")
    with pytest.raises(ConfigurationError, match="stems collide"):
        LocalFolderSource(tmp_path)


def test_quicktime_and_hub_encoded_media_do_not_become_stills(tmp_path: Path):
    data = b"quicktime-segment"
    content = image_content(Sample(sample_id="clip.mov", data=data, suffix=".mov"))
    assert content.data == data
    assert content.media_type == "video/quicktime"
    assert content.vendor_metadata == {"fps": 24}
    assert _encode({"bytes": data, "path": "clip.mov"}) == (data, ".mov")
    path = tmp_path / "clip.mp4"
    path.write_bytes(data)
    assert _encode({"path": str(path)}) == (data, ".mp4")


def test_captioner_and_critic_video_evidence_are_truthful():
    skill = skills.load()
    job = Job(profile="ltx-video", concepts=[Concept(trigger="MOTION7", target_concept="motion")])
    mapping = {"MOTION7": "the observed movement"}
    for assemble in (captioner_instructions, critic_instructions):
        video = assemble(skill, skill.profile("ltx-video"), job, mapping, is_video=True)
        assert '"evidence": "attached_target_video"' in video
        assert '"audio_status": "uninspected"' in video
        assert '"evidence": "attached_target_image"' not in video
        still = assemble(skill, skill.profile("ltx-video"), job, mapping)
        assert '"evidence": "attached_target_image"' in still
        assert '"audio_status": "not_applicable"' in still


@pytest.mark.asyncio
async def test_pure_video_hf_materializes_binary_video_and_reads_without_decoder(
    tmp_path: Path, monkeypatch
):
    datasets = pytest.importorskip("datasets")
    from datasets.table import embed_table_storage

    clip = tmp_path / "selected.mp4"
    content = b"selected-clip-byte-payload"
    clip.write_bytes(content)
    source = LocalFolderSource(tmp_path)
    dataset = HFDatasetSink(
        source, target_repo_id="offline/fixture", token="fixture", push=False
    ).materialize()
    assert isinstance(dataset.features["image"], datasets.Video)
    assert dataset.features["image"].decode is False
    assert _encode(dataset[0]["image"]) == (content, ".mp4")
    # The same storage embedding used by Hub upload embeds exactly these bytes; no upload occurs.
    embedded = datasets.Dataset(embed_table_storage(dataset.data.table, remote_files=False))
    assert embedded[0]["image"] == {"bytes": content, "path": "selected.mp4"}
    default_decoding = embedded.cast_column("image", datasets.Video())
    monkeypatch.setattr(datasets, "load_dataset", lambda *_args, **_kwargs: default_decoding)
    remote = HFDatasetSource("offline/fixture", token="fixture")
    assert remote.dataset.features["image"].decode is False
    sample = await anext(remote.samples())
    assert sample.sample_id == "selected.mp4"
    assert sample.data == content
    assert sample.suffix == ".mp4"


def test_mixed_tabular_hf_output_refuses_before_mislabeling_video_as_image(tmp_path: Path):
    pytest.importorskip("datasets")
    (tmp_path / "selected.mp4").write_bytes(b"clip")
    (tmp_path / "still.png").write_bytes(b"still")
    with pytest.raises(ConfigurationError, match="does not support mixed images and clips"):
        HFDatasetSink(
            LocalFolderSource(tmp_path),
            target_repo_id="offline/fixture",
            token="fixture",
            push=False,
        )


def test_unknown_decoded_hf_media_fails_with_configuration_error():
    with pytest.raises(ConfigurationError, match="unsupported decoded Hugging Face media"):
        _encode(object())
    with pytest.raises(ConfigurationError, match="Video column needs a byte/path descriptor"):
        _encode({"bytes": b"unknown-video-encoding", "path": None}, video=True)
