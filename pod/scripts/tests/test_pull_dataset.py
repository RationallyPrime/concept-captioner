"""pull_dataset.py: imagefolder normalisation, the datasets path, manifest counts, the Hub seam.

The script is loaded by path (``scripts/`` is not a package). Hub calls go through a fake; the
in-memory ``datasets.Dataset`` cases are skipped when ``datasets`` is not installed.
"""

from __future__ import annotations

import importlib.util
import json
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "pull_dataset.py"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses need it there to resolve string annotations
    spec.loader.exec_module(module)
    return module


pull = _load("pull_dataset_under_test", SCRIPT)

NORA7_CAPTION = "NORA7 woman in a grey coat, studio portrait, soft key light"
IVAN9_CAPTION = "IVAN9 man at a window, overcast daylight, three-quarter view"


def png_bytes(width: int = 2, height: int = 2) -> bytes:
    """A valid RGB PNG without Pillow."""

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return (
            struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + b"\x80\x40\x20" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


JPEG_HEAD = b"\xff\xd8\xff\xe0" + b"\x00" * 16
WEBP_HEAD = b"RIFF" + b"\x10\x00\x00\x00" + b"WEBP" + b"VP8 " + b"\x00" * 8


class FakeHub:
    """Stands in for pull_dataset.Hub: a file list, a snapshot folder, a job file, a dataset."""

    def __init__(
        self,
        *,
        files: list[str],
        snapshot: Path | None = None,
        sha: str | None = "abc123def456",
        job_text: str | None = None,
        dataset=None,
        tmp: Path | None = None,
    ) -> None:
        self.files = files
        self.snapshot_dir = snapshot
        self.sha = sha
        self.job_text = job_text
        self.dataset = dataset
        self.tmp = tmp
        self.calls: list[tuple] = []

    def list_files(self, repo_id, revision):
        self.calls.append(("list_files", repo_id, revision))
        return list(self.files)

    def resolve_sha(self, repo_id, revision):
        self.calls.append(("resolve_sha", repo_id, revision))
        return self.sha

    def snapshot(self, repo_id, revision, allow_patterns):
        self.calls.append(("snapshot", repo_id, revision, tuple(allow_patterns)))
        assert self.snapshot_dir is not None
        return self.snapshot_dir

    def download_file(self, repo_id, path_in_repo, revision):
        self.calls.append(("download_file", repo_id, path_in_repo, revision))
        assert self.job_text is not None and self.tmp is not None
        target = self.tmp / "downloaded-job.yaml"
        target.write_text(self.job_text, encoding="utf-8")
        return target

    def load_dataset(self, repo_id, *, split, revision, image_column):
        self.calls.append(("load_dataset", repo_id, split, revision, image_column))
        assert self.dataset is not None
        if hasattr(self.dataset, "column_names"):
            return pull.prepare_dataset(self.dataset, image_column)
        return self.dataset  # plain rows for the dependency-free tests


def make_imagefolder(root: Path) -> Path:
    """train/metadata.jsonl listing a.png (caption) and sub/b.jpg (text); c.webp with a sidecar; d.png bare."""
    train = root / "train"
    (train / "sub").mkdir(parents=True)
    (train / "a.png").write_bytes(png_bytes())
    (train / "sub" / "b.jpg").write_bytes(JPEG_HEAD)
    (train / "c.webp").write_bytes(WEBP_HEAD)
    (train / "c.txt").write_text("  IVAN9 man, seated, lamp light  \n", encoding="utf-8")
    (train / "d.png").write_bytes(png_bytes(3, 1))
    (train / "metadata.jsonl").write_text(
        json.dumps({"file_name": "a.png", "caption": NORA7_CAPTION})
        + "\n"
        + json.dumps({"file_name": "sub/b.jpg", "text": IVAN9_CAPTION})
        + "\n\n",
        encoding="utf-8",
    )
    (root / "README.md").write_text("# fixture\n", encoding="utf-8")
    return root


def read_manifest(out: Path) -> dict:
    return json.loads((out / "manifest.json").read_text(encoding="utf-8"))


def read_metadata(out: Path) -> list[dict]:
    return [
        json.loads(line)
        for line in (out / "metadata.jsonl").read_text(encoding="utf-8").splitlines()
        if line
    ]


# --- pure helpers --------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("files", "expected"),
    [
        (["train/a.png", "train/metadata.jsonl", "README.md"], "imagefolder"),
        (["a.png", "b.jpg"], "imagefolder"),  # raw folder: no metadata, no tabular files
        (["data/train-00000-of-00001.parquet", "README.md"], "datasets"),
        (
            ["images/a.png", "data/train.parquet"],
            "datasets",
        ),  # tabular wins unless metadata says otherwise
        (["images/a.png", "images/metadata.csv", "data/train.parquet"], "imagefolder"),
        (["README.md"], "datasets"),
    ],
)
def test_detect_convention(files, expected):
    assert pull.detect_convention(files) == expected


def test_sample_id_rules_match_the_package():
    assert pull._sample_id({"file_name": "x.png", "id": 7}, 3, None) == "x.png"
    assert pull._sample_id({"filename": "y.jpg"}, 3, None) == "y.jpg"
    assert pull._sample_id({"image_id": 12}, 3, None) == "12"
    assert pull._sample_id({"id": 0}, 3, None) == "0"  # 0 is a value, not "missing"
    assert pull._sample_id({"name": "z"}, 3, None) == "z"
    assert pull._sample_id({"file_name": "x.png", "key": "k1"}, 3, "key") == "k1"
    assert pull._sample_id({"file_name": "x.png", "key": None}, 3, "key") == "x.png"
    assert pull._sample_id({"caption": "..."}, 3, None) == "3"


def test_flatten_and_file_name_for():
    assert pull.flatten("sub/dir/a.png") == "sub__dir__a.png"
    assert pull.flatten("./a.png") == "a.png"
    assert pull.flatten("sub\\b.jpg") == "sub__b.jpg"
    with pytest.raises(pull.PullError):
        pull.flatten("../a.png")
    with pytest.raises(pull.PullError):
        pull.flatten("")
    assert pull.file_name_for("solo.png", ".jpg") == "solo.png"  # an image suffix in the id wins
    assert pull.file_name_for("img.001", ".png") == "img.001.png"  # no stem truncation
    assert pull.file_name_for("12", ".webp") == "12.webp"
    assert pull.file_name_for("a/b", ".png") == "a__b.png"
    assert pull.file_name_for(".hidden", ".png") == "hidden.png"
    assert pull.file_name_for("", ".png") == "sample.png"


def test_sniff_suffix():
    assert pull.sniff_suffix(png_bytes()) == ".png"
    assert pull.sniff_suffix(JPEG_HEAD) == ".jpg"
    assert pull.sniff_suffix(WEBP_HEAD) == ".webp"
    assert pull.sniff_suffix(b"GIF89a....") is None


def test_name_set_rejects_name_and_stem_collisions():
    names = pull.NameSet()
    names.add("a.png")
    names.add("b.png")
    with pytest.raises(pull.PullError, match="would land as"):
        names.add("a.png")
    with pytest.raises(pull.PullError, match="share a stem"):
        names.add("a.jpg")


# --- imagefolder ---------------------------------------------------------------------------------


def test_collect_imagefolder_normalises_a_fixture_tree(tmp_path: Path):
    snapshot = make_imagefolder(tmp_path / "snap")
    entries = pull.collect_imagefolder(snapshot, split="train", caption_column="caption")
    by_name = {entry.file_name: entry for entry in entries}
    assert list(by_name) == [
        "a.png",
        "sub__b.jpg",
        "c.webp",
        "d.png",
    ]  # metadata rows first, then the rest
    assert by_name["a.png"].caption == NORA7_CAPTION
    assert by_name["sub__b.jpg"].caption == IVAN9_CAPTION  # "text" is accepted
    assert by_name["c.webp"].caption == "IVAN9 man, seated, lamp light"  # sidecar, stripped
    assert by_name["d.png"].caption is None
    assert by_name["sub__b.jpg"].source == snapshot / "train" / "sub" / "b.jpg"


def test_write_entries_lands_files_sidecars_and_metadata(tmp_path: Path):
    snapshot = make_imagefolder(tmp_path / "snap")
    out = tmp_path / "out"
    written = pull.write_entries(
        pull.collect_imagefolder(snapshot, split="train", caption_column="caption"), out
    )
    assert sorted(p.name for p in out.iterdir()) == [
        "a.png",
        "a.txt",
        "c.txt",
        "c.webp",
        "d.png",
        "metadata.jsonl",
        "sub__b.jpg",
        "sub__b.txt",
    ]
    assert (out / "a.txt").read_text(encoding="utf-8") == NORA7_CAPTION  # raw caption, no newline
    assert (out / "sub__b.jpg").read_bytes() == JPEG_HEAD
    assert read_metadata(out) == [
        {"file_name": "a.png", "caption": NORA7_CAPTION},
        {"file_name": "sub__b.jpg", "caption": IVAN9_CAPTION},
        {"file_name": "c.webp", "caption": "IVAN9 man, seated, lamp light"},
        {"file_name": "d.png", "caption": None},
    ]
    assert all(entry.data is None and entry.source is None for entry in written)


def test_caption_column_is_honoured_before_caption_and_text(tmp_path: Path):
    snapshot = tmp_path / "snap"
    snapshot.mkdir()
    (snapshot / "a.png").write_bytes(png_bytes())
    (snapshot / "metadata.jsonl").write_text(
        json.dumps({"file_name": "a.png", "caption": "wrong", "final": NORA7_CAPTION}) + "\n"
    )
    entries = pull.collect_imagefolder(snapshot, split="train", caption_column="final")
    assert entries[0].caption == NORA7_CAPTION


def test_metadata_csv_is_accepted(tmp_path: Path):
    snapshot = tmp_path / "snap"
    snapshot.mkdir()
    (snapshot / "a.png").write_bytes(png_bytes())
    (snapshot / "metadata.csv").write_text(
        f'file_name,text\na.png,"{IVAN9_CAPTION}"\n', encoding="utf-8"
    )
    entries = pull.collect_imagefolder(snapshot, split="train", caption_column="caption")
    assert [(e.file_name, e.caption) for e in entries] == [("a.png", IVAN9_CAPTION)]


def test_split_selects_among_several_metadata_folders(tmp_path: Path):
    snapshot = tmp_path / "snap"
    for split in ("train", "test"):
        folder = snapshot / "data" / split
        folder.mkdir(parents=True)
        (folder / "a.png").write_bytes(png_bytes())
        (folder / "metadata.jsonl").write_text(
            json.dumps({"file_name": "a.png", "caption": split}) + "\n"
        )
    entries = pull.collect_imagefolder(snapshot, split="train", caption_column="caption")
    assert [(e.file_name, e.caption) for e in entries] == [("a.png", "train")]
    # Without a matching split both folders are used and the flattened names collide on write.
    with pytest.raises(pull.PullError, match="would land as"):
        pull.write_entries(
            pull.collect_imagefolder(snapshot, split="validation", caption_column="caption"),
            tmp_path / "out",
        )


def test_missing_listed_file_and_non_image_rows_are_errors(tmp_path: Path):
    snapshot = tmp_path / "snap"
    snapshot.mkdir()
    (snapshot / "metadata.jsonl").write_text(
        json.dumps({"file_name": "gone.png", "caption": "x"}) + "\n"
    )
    with pytest.raises(pull.PullError, match="not in the repo"):
        pull.collect_imagefolder(snapshot, split="train", caption_column="caption")
    (snapshot / "notes.txt").write_text("x")
    (snapshot / "metadata.jsonl").write_text(
        json.dumps({"file_name": "notes.txt", "caption": "x"}) + "\n"
    )
    with pytest.raises(pull.PullError, match="not an image"):
        pull.collect_imagefolder(snapshot, split="train", caption_column="caption")
    (snapshot / "metadata.jsonl").write_text("{not json\n")
    with pytest.raises(pull.PullError, match=r"metadata\.jsonl:1"):
        pull.collect_imagefolder(snapshot, split="train", caption_column="caption")


def test_metadata_file_name_cannot_escape_the_snapshot(tmp_path: Path):
    secret = tmp_path / "secret.png"
    secret.write_bytes(png_bytes())
    snapshot = tmp_path / "snap"
    (snapshot / "train").mkdir(parents=True)
    (snapshot / "train" / "metadata.jsonl").write_text(
        json.dumps({"file_name": "../../secret.png", "caption": "x"}) + "\n", encoding="utf-8"
    )
    with pytest.raises(pull.PullError, match="outside the repo snapshot"):
        pull.collect_imagefolder(snapshot, split="train", caption_column="caption")
    (snapshot / "train" / "metadata.jsonl").write_text(
        json.dumps({"file_name": str(secret), "caption": "x"}) + "\n", encoding="utf-8"
    )
    with pytest.raises(pull.PullError, match="must be a relative path"):
        pull.collect_imagefolder(snapshot, split="train", caption_column="caption")


def test_hidden_folders_are_ignored(tmp_path: Path):
    snapshot = tmp_path / "snap"
    (snapshot / ".cache" / "huggingface").mkdir(parents=True)
    (snapshot / ".cache" / "huggingface" / "stale.png").write_bytes(png_bytes())
    (snapshot / "a.png").write_bytes(png_bytes())
    entries = pull.collect_imagefolder(snapshot, split="train", caption_column="caption")
    assert [e.file_name for e in entries] == ["a.png"]


# --- main() over the fake Hub: imagefolder -----------------------------------------------------


def test_main_imagefolder_end_to_end(tmp_path: Path, capsys):
    snapshot = make_imagefolder(tmp_path / "snap")
    files = [
        "README.md",
        "train/metadata.jsonl",
        "train/a.png",
        "train/sub/b.jpg",
        "train/c.webp",
        "train/c.txt",
        "train/d.png",
        "concept-captioner/job.yaml",
    ]
    hub = FakeHub(
        files=files, snapshot=snapshot, job_text="profile: h3-still\nconcepts: []\n", tmp=tmp_path
    )
    out = tmp_path / "datasets" / "faces"
    assert pull.main(["--repo", "someone/faces", "--to", str(out)], hub=hub) == 0

    manifest = read_manifest(out)
    assert manifest["repo_id"] == "someone/faces"
    assert manifest["revision"] == "abc123def456"  # resolved sha, not the requested (None)
    assert manifest["requested_revision"] is None
    assert manifest["convention"] == "imagefolder"
    assert (manifest["count"], manifest["with_caption"], manifest["without_caption"]) == (4, 3, 1)
    assert manifest["job_yaml"] == "job.yaml"
    assert manifest["split"] == "train"
    assert manifest["pulled_at"].endswith("Z")
    assert (out / "job.yaml").read_text(encoding="utf-8").startswith("profile: h3-still")
    assert (out / "a.txt").read_text(encoding="utf-8") == NORA7_CAPTION
    assert not (out.parent / "faces.partial").exists()
    assert not (out.parent / "faces.old").exists()

    # the snapshot was pinned to the resolved sha and asked only for what an imagefolder needs
    snapshot_call = next(c for c in hub.calls if c[0] == "snapshot")
    assert snapshot_call[2] == "abc123def456"
    assert {"*.png", "*.PNG", "*.txt", "*metadata.jsonl", "*metadata.csv"} <= set(snapshot_call[3])
    job_call = next(c for c in hub.calls if c[0] == "download_file")
    assert job_call[2:] == ("concept-captioner/job.yaml", "abc123def456")
    assert "4 images, 3 with captions, 1 without; job.yaml: yes" in capsys.readouterr().out


def test_main_without_job_file_and_with_explicit_revision(tmp_path: Path):
    snapshot = make_imagefolder(tmp_path / "snap")
    hub = FakeHub(files=["train/metadata.jsonl", "train/a.png"], snapshot=snapshot, sha=None)
    out = tmp_path / "faces"
    assert (
        pull.main(["--repo", "someone/faces", "--to", str(out), "--revision", "v1"], hub=hub) == 0
    )
    manifest = read_manifest(out)
    assert manifest["job_yaml"] is None
    assert manifest["revision"] == "v1"
    assert not (out / "job.yaml").exists()
    assert all(c[0] != "download_file" for c in hub.calls)


def test_require_captions_exits_1_but_keeps_the_folder(tmp_path: Path, capsys):
    snapshot = make_imagefolder(tmp_path / "snap")
    hub = FakeHub(files=["train/metadata.jsonl", "train/a.png"], snapshot=snapshot)
    out = tmp_path / "faces"
    code = pull.main(["--repo", "someone/faces", "--to", str(out), "--require-captions"], hub=hub)
    assert code == 1
    assert "1 of 4 images have no caption: d.png" in capsys.readouterr().err
    assert read_manifest(out)["without_caption"] == 1  # swapped in anyway, for inspection


def test_require_captions_passes_when_every_image_has_one(tmp_path: Path):
    snapshot = make_imagefolder(tmp_path / "snap")
    (snapshot / "train" / "d.txt").write_text("NORA7 woman, profile", encoding="utf-8")
    hub = FakeHub(files=["train/metadata.jsonl", "train/a.png"], snapshot=snapshot)
    out = tmp_path / "faces"
    assert (
        pull.main(["--repo", "someone/faces", "--to", str(out), "--require-captions"], hub=hub) == 0
    )
    assert read_manifest(out)["without_caption"] == 0


def test_re_pull_replaces_stale_files_atomically(tmp_path: Path):
    snapshot = make_imagefolder(tmp_path / "snap")
    out = tmp_path / "faces"
    out.mkdir()
    (out / "stale.png").write_bytes(png_bytes())
    (out / "stale.txt").write_text("old caption")
    hub = FakeHub(files=["train/metadata.jsonl", "train/a.png"], snapshot=snapshot)
    assert pull.main(["--repo", "someone/faces", "--to", str(out)], hub=hub) == 0
    assert not (out / "stale.png").exists()
    assert (out / "a.png").exists()
    assert not (tmp_path / "faces.old").exists()


def test_failed_pull_leaves_the_previous_folder_untouched(tmp_path: Path, capsys):
    snapshot = tmp_path / "snap"
    snapshot.mkdir()
    (snapshot / "metadata.jsonl").write_text(json.dumps({"file_name": "gone.png"}) + "\n")
    out = tmp_path / "faces"
    out.mkdir()
    (out / "keep.png").write_bytes(png_bytes())
    hub = FakeHub(files=["metadata.jsonl", "a.png"], snapshot=snapshot)
    assert pull.main(["--repo", "someone/faces", "--to", str(out)], hub=hub) == 1
    assert "not in the repo" in capsys.readouterr().err
    assert (out / "keep.png").exists()
    assert not (tmp_path / "faces.partial").exists()


def test_hub_errors_become_one_line(tmp_path: Path, capsys):
    class Broken(FakeHub):
        def list_files(self, repo_id, revision):
            raise RuntimeError("401 Client Error")

    hub = Broken(files=[])
    assert pull.main(["--repo", "nobody/nothing", "--to", str(tmp_path / "x")], hub=hub) == 1
    assert "cannot read nobody/nothing: 401 Client Error" in capsys.readouterr().err


# --- the datasets path ---------------------------------------------------------------------------


def test_iter_dataset_entries_over_plain_rows():
    rows = [
        {
            "image": {"bytes": png_bytes(), "path": "solo.png"},
            "file_name": "solo.png",
            "caption": NORA7_CAPTION,
            "caption_response": json.dumps({"status": "ok"}),
        },
        {
            "image": {"bytes": JPEG_HEAD, "path": None},
            "file_name": "pair",
            "caption": "",
            "caption_response": "{}",
        },
        {"image": {"bytes": WEBP_HEAD, "path": "weird.bin"}, "caption": None},
        {"image": {"bytes": b"\x00\x01\x02", "path": None}, "id": 9, "caption": IVAN9_CAPTION},
    ]
    entries = list(
        pull.iter_dataset_entries(
            rows, image_column="image", caption_column="caption", id_column=None
        )
    )
    assert [e.file_name for e in entries] == ["solo.png", "pair.jpg", "2.webp", "9.png"]
    assert [e.caption for e in entries] == [NORA7_CAPTION, None, None, IVAN9_CAPTION]
    assert entries[0].record == json.dumps({"status": "ok"})
    assert entries[1].record is None  # "{}" is not a record
    assert entries[0].data == png_bytes()


def test_iter_dataset_entries_id_column_and_missing_image_column():
    rows = [{"image": {"bytes": png_bytes()}, "file_name": "a.png", "uid": "k-1"}]
    (entry,) = pull.iter_dataset_entries(
        rows, image_column="image", caption_column="caption", id_column="uid"
    )
    assert entry.file_name == "k-1.png"
    with pytest.raises(pull.PullError, match="no 'img' column"):
        list(
            pull.iter_dataset_entries(
                rows, image_column="img", caption_column="caption", id_column=None
            )
        )
    with pytest.raises(pull.PullError, match="neither bytes nor a path"):
        list(
            pull.iter_dataset_entries(
                [{"image": {"bytes": None, "path": None}}],
                image_column="image",
                caption_column="caption",
                id_column=None,
            )
        )


def test_image_payload_reads_a_path_when_bytes_are_absent(tmp_path: Path):
    path = tmp_path / "on-disk.jpeg"
    path.write_bytes(JPEG_HEAD)
    assert pull.image_payload({"bytes": None, "path": str(path)}, allowed_roots=[tmp_path]) == (
        JPEG_HEAD,
        ".jpeg",
    )
    assert pull.image_payload(b"raw") == (b"raw", None)
    # a path cell is untrusted: outside the allowed roots, or not an image, it is refused
    outside = tmp_path / "elsewhere" / "secret.jpeg"
    outside.parent.mkdir()
    outside.write_bytes(JPEG_HEAD)
    with pytest.raises(pull.PullError, match="outside the dataset cache"):
        pull.image_payload({"bytes": None, "path": str(outside)}, allowed_roots=[tmp_path / "x"])
    with pytest.raises(pull.PullError, match="not an image file"):
        pull.image_payload({"bytes": None, "path": "/etc/passwd"}, allowed_roots=[Path("/")])
    with pytest.raises(pull.PullError, match="unsupported image cell"):
        pull.image_payload(42)


def test_image_payload_encodes_a_pil_image():
    Image = pytest.importorskip("PIL.Image")
    data, suffix = pull.image_payload(Image.new("RGB", (2, 2), (10, 20, 30)))
    assert suffix == ".png" and data.startswith(b"\x89PNG")


def test_main_datasets_path_over_plain_rows(tmp_path: Path):
    rows = [
        {
            "image": {"bytes": png_bytes(), "path": "solo.png"},
            "file_name": "solo.png",
            "caption": NORA7_CAPTION,
        },
        {"image": {"bytes": JPEG_HEAD, "path": None}, "file_name": "pair.jpg", "caption": None},
    ]
    hub = FakeHub(files=["data/train-00000-of-00001.parquet"], dataset=rows)
    out = tmp_path / "faces"
    assert (
        pull.main(["--repo", "someone/faces", "--to", str(out), "--split", "validation"], hub=hub)
        == 0
    )
    manifest = read_manifest(out)
    assert manifest["convention"] == "datasets"
    assert (manifest["count"], manifest["with_caption"], manifest["without_caption"]) == (
        2,
        1,
        0 + 1,
    )
    assert manifest["split"] == "validation"
    assert (out / "solo.txt").read_text(encoding="utf-8") == NORA7_CAPTION
    assert (out / "pair.jpg").read_bytes() == JPEG_HEAD
    assert not (out / "pair.txt").exists()
    assert ("load_dataset", "someone/faces", "validation", "abc123def456", "image") in hub.calls


def test_main_datasets_path_with_an_in_memory_dataset(tmp_path: Path):
    datasets = pytest.importorskip("datasets")
    dataset = datasets.Dataset.from_dict(
        {
            "image": [
                {"bytes": png_bytes(), "path": "nora7-01.png"},
                {"bytes": JPEG_HEAD, "path": None},
                {"bytes": WEBP_HEAD, "path": None},
            ],
            "file_name": ["nora7-01.png", "ivan9-01", "both-01"],
            "caption": [NORA7_CAPTION, IVAN9_CAPTION, ""],
            "caption_response": [
                json.dumps({"sample_id": "nora7-01.png", "status": "ok"}),
                "{}",
                "{}",
            ],
        }
    ).cast_column("image", datasets.Image())
    hub = FakeHub(files=["data/train-00000-of-00001.parquet"], dataset=dataset)
    out = tmp_path / "faces"
    assert pull.main(["--repo", "someone/faces", "--to", str(out)], hub=hub) == 0
    manifest = read_manifest(out)
    assert (manifest["count"], manifest["with_caption"], manifest["without_caption"]) == (3, 2, 1)
    assert sorted(p.name for p in out.iterdir()) == [
        "both-01.webp",
        "ivan9-01.jpg",
        "ivan9-01.txt",
        "manifest.json",
        "metadata.jsonl",
        "nora7-01.json",
        "nora7-01.png",
        "nora7-01.txt",
    ]
    assert (out / "nora7-01.png").read_bytes() == png_bytes()
    assert json.loads((out / "nora7-01.json").read_text(encoding="utf-8"))["status"] == "ok"
    assert read_metadata(out)[2] == {"file_name": "both-01.webp", "caption": None}


def test_in_memory_dataset_with_id_column_and_custom_caption_column(tmp_path: Path):
    datasets = pytest.importorskip("datasets")
    dataset = datasets.Dataset.from_dict(
        {
            "img": [{"bytes": png_bytes(), "path": None}],
            "uid": ["k-7"],
            "text": [IVAN9_CAPTION],
            "caption": ["ignored"],
        }
    ).cast_column("img", datasets.Image())
    hub = FakeHub(files=["train.parquet"], dataset=dataset)
    out = tmp_path / "faces"
    args = [
        "--repo",
        "someone/faces",
        "--to",
        str(out),
        "--image-column",
        "img",
        "--caption-column",
        "text",
        "--id-column",
        "uid",
    ]
    assert pull.main(args, hub=hub) == 0
    assert (out / "k-7.txt").read_text(encoding="utf-8") == IVAN9_CAPTION
    assert read_manifest(out)["caption_column"] == "text"


def test_in_memory_dataset_without_the_image_column_fails_cleanly(tmp_path: Path, capsys):
    datasets = pytest.importorskip("datasets")
    hub = FakeHub(files=["train.parquet"], dataset=datasets.Dataset.from_dict({"caption": ["x"]}))
    out = tmp_path / "faces"
    assert pull.main(["--repo", "someone/faces", "--to", str(out)], hub=hub) == 1
    assert "no column 'image'" in capsys.readouterr().err
    assert not out.exists() and not (tmp_path / "faces.partial").exists()


# --- the script as a program ---------------------------------------------------------------------


def test_help_runs_isolated_without_heavy_imports():
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "SYSTEMROOT")}
    result = subprocess.run(
        [sys.executable, "-I", str(SCRIPT), "--help"],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "--require-captions" in result.stdout
    probe = (
        "import importlib.util, sys\n"
        f"spec = importlib.util.spec_from_file_location('m', {str(SCRIPT)!r})\n"
        "m = importlib.util.module_from_spec(spec); sys.modules['m'] = m; spec.loader.exec_module(m)\n"
        "print(sorted(k.split('.')[0] for k in sys.modules if k.split('.')[0] in {'huggingface_hub', 'datasets', 'PIL', 'pydantic'}))\n"
    )
    result = subprocess.run(
        [sys.executable, "-I", "-c", probe], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "[]"


def test_metadata_only_pull_keeps_exact_approved_video_and_sidecars(tmp_path):
    snapshot = tmp_path / "snapshot"
    snapshot.mkdir()
    (snapshot / "approved.mp4").write_bytes(b"exact selected clip bytes")
    (snapshot / "approved.txt").write_text("NORA7 walks through a room")
    (snapshot / "approved.json").write_text('{"source":"human"}')
    (snapshot / "excluded.png").write_bytes(b"stale unrelated photo")
    (snapshot / "metadata.jsonl").write_text(
        '{"file_name":"approved.mp4","caption":"NORA7 walks through a room"}\n'
    )
    entries = pull.collect_imagefolder(
        snapshot, split="train", caption_column="caption", only_metadata=True
    )
    out = tmp_path / "pulled"
    pull.write_entries(entries, out)
    assert [e.file_name for e in entries] == ["approved.mp4"]
    assert (out / "approved.mp4").read_bytes() == b"exact selected clip bytes"
    assert (out / "approved.txt").read_text() == "NORA7 walks through a room"
    assert (out / "approved.json").read_text() == '{"source":"human"}'
    assert not (out / "excluded.png").exists()


def test_metadata_only_pull_refuses_unlisted_training_media(tmp_path):
    (tmp_path / "clip.mp4").write_bytes(b"video")
    with pytest.raises(pull.PullError, match="metadata"):
        pull.collect_imagefolder(
            tmp_path, split="train", caption_column="caption", only_metadata=True
        )
