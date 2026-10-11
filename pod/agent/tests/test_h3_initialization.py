"""Real agent admission/capture of fixed H3 initializer slots; inference stays offline."""

import hashlib
import json
import runpy
import shutil
import struct
from pathlib import Path

import pytest
from pydantic import ValidationError

from podagent.catalog import CATALOG, parse_params
from podagent.errors import Validation
from podagent.uploads import claim_initialization, claim_stage, release_stage

RULES = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts/h3_recipe.py"))


def initializer(paths):
    folder = paths.uploads / "init-fixture"
    folder.mkdir(parents=True)
    key = "diffusion_model.blocks.20.attn.out_proj"
    header = json.dumps(
        {
            key + ".lora_A.weight": {"dtype": "F32", "shape": [2, 4], "data_offsets": [0, 32]},
            key + ".lora_B.weight": {"dtype": "F32", "shape": [4, 2], "data_offsets": [32, 64]},
        }
    ).encode()
    (folder / "initial-lora.safetensors").write_bytes(
        struct.pack("<Q", len(header)) + header + bytes(64)
    )
    recipe = RULES["quality_settings"]()
    recipe["network"].update(linear=2, linear_alpha=2)
    recipe["network"]["network_kwargs"] = {"only_if_contains": ["blocks.20.attn.out_proj"]}
    (folder / "initial-recipe.json").write_text(json.dumps(recipe))
    return {
        "name": folder.name,
        "lora_sha256": hashlib.sha256(
            (folder / "initial-lora.safetensors").read_bytes()
        ).hexdigest(),
        "recipe_sha256": hashlib.sha256((folder / "initial-recipe.json").read_bytes()).hexdigest(),
    }


def request(paths, init):
    dataset = paths.datasets / "approved"
    dataset.mkdir(parents=True, exist_ok=True)
    (dataset / "photo.png").write_bytes(b"synthetic input")
    (dataset / "photo.txt").write_text("NORA7 beside IVAN9")
    return {
        "run_id": "fresh-h3",
        "dataset": {"path": str(dataset)},
        "base_model": "Comfy-Org/MiniMax-H3",
        "triggers": ["NORA7", "IVAN9"],
        "rank": 2,
        "alpha": 4,
        "steps": 3,
        "initialization": init,
    }


def test_upload_only_exact_weight_slot_and_auth_before_body(client, anon_client, settings):
    assert (
        anon_client.put("/uploads/init-test/initial-lora.safetensors", content=b"bytes").status_code
        == 401
    )
    assert (
        client.put("/uploads/init-test/initial-lora.safetensors", content=b"bytes").status_code
        == 200
    )
    assert (
        client.put("/uploads/init-test/arbitrary.safetensors", content=b"bytes").status_code == 422
    )
    assert not (settings.paths.uploads / "init-test/arbitrary.safetensors").exists()


def test_claim_fixed_pair_blocks_writes_and_cannot_install_as_dataset(settings, client):
    init = initializer(settings.paths)
    claim_initialization(settings.paths, init["name"])
    try:
        assert (
            client.put(f"/uploads/{init['name']}/initial-recipe.json", content=b"new").status_code
            == 422
        )
    finally:
        release_stage(settings.paths, init["name"])
    (settings.paths.uploads / init["name"] / "metadata.jsonl").write_text("{}\n")
    with pytest.raises(Validation, match="separate stage"):
        claim_stage(settings.paths, init["name"])
    with pytest.raises(Validation, match="exactly"):
        claim_initialization(settings.paths, init["name"])


@pytest.mark.parametrize(
    "change",
    [
        {"rank": 4},
        {"base_model": "black-forest-labs/FLUX.1-dev"},
        {
            "initialization": {
                "name": "../outside",
                "lora_sha256": "a" * 64,
                "recipe_sha256": "b" * 64,
            }
        },
    ],
)
def test_initializer_rejected_before_run_created(settings, change):
    init = initializer(settings.paths)
    with pytest.raises(ValidationError):
        parse_params(
            "trainer-aitoolkit", {**request(settings.paths, init), **change}, settings.paths
        )
    assert not settings.paths.run_dir("fresh-h3").exists()


def test_new_run_captures_private_weights_and_recipe_and_preserves_effective_settings(settings):
    paths = settings.paths
    init = initializer(paths)
    raw = request(paths, init)
    params = parse_params("trainer-aitoolkit", raw, paths)
    CATALOG["trainer-aitoolkit"].prepare(params, paths)
    run = paths.run_dir(raw["run_id"])
    payload = json.loads((run / "run.json").read_text())
    assert payload["extra"]["network"]["linear"] == 2
    assert payload["extra"]["network"]["linear_alpha"] == 4
    assert payload["extra"]["network"]["network_kwargs"]["only_if_contains"] == [
        "blocks.20.attn.out_proj"
    ]
    original = (run / "initial-lora.safetensors").read_bytes()
    (paths.uploads / init["name"] / "initial-lora.safetensors").write_bytes(b"later replacement")
    assert (run / "initial-lora.safetensors").read_bytes() == original
    assert not (paths.uploads / init["name"] / ".installing").exists()
    assert not (run / "output").exists()
    with pytest.raises(ValidationError, match="NEW"):
        parse_params("trainer-aitoolkit", raw, paths)


def test_changed_sha_or_old_native_job_refused(settings):
    init = initializer(settings.paths)
    raw = request(settings.paths, init)
    init["lora_sha256"] = "0" * 64
    with pytest.raises(ValidationError, match="checksum"):
        parse_params("trainer-aitoolkit", raw, settings.paths)


def test_h3_generation_captures_native_recipe_and_allows_still_or_video(settings):
    paths = settings.paths
    run = paths.run_dir("source")
    (run / "output").mkdir(parents=True)
    (run / "output/chosen.safetensors").write_bytes(b"synthetic weights")
    (run / "run.json").write_text(json.dumps({"base_model": RULES["MODEL"]}))
    native = {"config": {"process": [{"model": {"arch": "minimax_h3"}, "network": {"linear": 32}}]}}
    (run / "native-config.json").write_text(json.dumps(native))
    raw = {
        "run_id": "comparison",
        "source_run_id": "source",
        "checkpoint": "chosen.safetensors",
        "prompts": ["NORA7 and IVAN9 walk"],
        "seeds": [42],
        "num_frames": 39,
        "frame_rate": 24,
    }
    for count in (1, 5, 22, 39, 243):
        parse_params("generate-aitoolkit", {**raw, "num_frames": count}, paths)
    for change in ({"num_frames": 17}, {"num_frames": 4}, {"frame_rate": 30}):
        with pytest.raises(ValidationError):
            parse_params("generate-aitoolkit", {**raw, **change}, paths)
    params = parse_params("generate-aitoolkit", raw, paths)
    CATALOG["generate-aitoolkit"].prepare(params, paths)
    target = paths.run_dir("comparison")
    (run / "native-config.json").write_text("replacement")
    assert json.loads((target / "source-native-config.json").read_text()) == native


def test_initialized_resume_uses_captured_pair_after_stage_deleted(settings, monkeypatch):
    paths = settings.paths
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(paths.workspace))
    init = initializer(paths)
    raw = request(paths, init)
    CATALOG["trainer-aitoolkit"].prepare(parse_params("trainer-aitoolkit", raw, paths), paths)
    run = paths.run_dir(raw["run_id"])
    shutil.rmtree(paths.uploads / init["name"])
    checkpoint = run / f"output/{raw['run_id']}/{raw['run_id']}_000002.safetensors"
    checkpoint.parent.mkdir(parents=True)
    header = json.dumps({"__metadata__": {"training_info": json.dumps({"step": 2})}}).encode()
    checkpoint.write_bytes(struct.pack("<Q", len(header)) + header)
    saved = json.loads((run / "run.json").read_text())
    resumed = {**saved, "resume": True, "steps": 4}
    params = parse_params("trainer-aitoolkit", resumed, paths)
    CATALOG["trainer-aitoolkit"].prepare(params, paths)
    wrapper = runpy.run_path(
        str(Path(__file__).resolve().parents[2] / "scripts/launch_aitoolkit.py")
    )
    native = wrapper["build_native_config"](
        wrapper["validate_run_config"](resumed, paths.workspace), run
    )
    process = native["config"]["process"][0]
    assert process["network"]["pretrained_lora_path"] == str(run / "initial-lora.safetensors")
    assert "start_step" not in process["train"]
    assert process["train"]["steps"] == 4
    assert (run / "initial-recipe.json").exists() and checkpoint.exists()
    with pytest.raises(ValidationError, match="initialization"):
        parse_params("trainer-aitoolkit", {**resumed, "initialization": None}, paths)
