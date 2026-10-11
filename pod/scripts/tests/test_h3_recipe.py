"""Pinned H3 contracts and meaningful CPU controls; no model, GPU or network execution."""

import importlib.util
import json
import struct
import sys
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

import pytest


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recipe = load("h3_recipe")
dataset = load("h3_dataset")
wrapper = load("launch_aitoolkit")
generation = load("generate_results")


def weights(rank=2, prefix="diffusion_model.blocks.20.attn.out_proj"):
    header = json.dumps(
        {
            prefix + ".lora_A.weight": {
                "dtype": "F32",
                "shape": [rank, 4],
                "data_offsets": [0, rank * 16],
            },
            prefix + ".lora_B.weight": {
                "dtype": "F32",
                "shape": [4, rank],
                "data_offsets": [rank * 16, rank * 32],
            },
        }
    ).encode()
    return struct.pack("<Q", len(header)) + header + bytes(rank * 32)


def canonical():
    value = recipe.quality_settings()
    value["network"].update(linear=2, linear_alpha=2)
    return value


@pytest.mark.parametrize(
    "prefix", ["diffusion_model.blocks.20.attn.out_proj", "transformer.blocks.20.attn.out_proj"]
)
def test_actual_comfy_and_native_h3_export_names_and_rank(tmp_path, prefix):
    path = tmp_path / "initial-lora.safetensors"
    path.write_bytes(weights(prefix=prefix))
    recipe.validate_weights(path, 2)
    with pytest.raises(ValueError, match="rank"):
        recipe.validate_weights(path, 4)
    with pytest.raises(ValueError, match="excluded"):
        recipe.validate_weights(path, 2, {"only_if_contains": ["blocks.21."]})


@pytest.mark.parametrize(
    "change",
    [
        {"job": "extension"},
        {"model": {"te_name_or_path": "/old/pod/model"}},
        {"train": {"start_step": 601}},
        {"train": {"steps": 5000}},
        {"dataset": {"folder_path": "/private/photos"}},
        {"network": {"pretrained_lora_path": "/old/pod/lora"}},
        {"hub": {"token": "not-a-real-token"}},
    ],
)
def test_raw_jobs_paths_counters_and_secrets_are_not_canonical(change):
    value = canonical()
    for key, contents in change.items():
        if key in value:
            value[key].update(contents)
        else:
            value[key] = contents
    with pytest.raises(ValueError):
        recipe.validate_recipe(value)


def probe(count=22, width=512, height=288, fps="24/1", interval=1 / 24, time_base="1/24000"):
    return {
        "streams": [
            {
                "nb_read_frames": str(count),
                "width": width,
                "height": height,
                "avg_frame_rate": fps,
                "time_base": time_base,
                "duration": str(count * interval),
            }
        ],
        "frames": [{"best_effort_timestamp_time": str(i * interval)} for i in range(count)],
    }


def install_probe(monkeypatch, value):
    monkeypatch.setattr(
        dataset.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=json.dumps(value)),
    )


@pytest.mark.parametrize(
    "value",
    [
        probe(count=17),
        probe(count=4),
        probe(count=260),
        probe(width=510),
        probe(fps="30000/1001", interval=1001 / 30000),
        probe(fps="24000/1001", interval=1001 / 24000),
        probe(fps="24/1", interval=1 / 30, time_base="1/30"),
        probe(width=1152, height=864),
    ],
)
def test_bad_counts_cadence_geometry_or_cap_refused_before_native_model(monkeypatch, value):
    install_probe(monkeypatch, value)
    with pytest.raises(ValueError):
        dataset.probe_clip(Path("approved.mp4"), 512)


def test_full_mixed_approved_inputs_grouped_without_global_trigger(tmp_path, monkeypatch):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    root = tmp_path / "datasets/approved"
    root.mkdir(parents=True)
    for name in ("still.png", "clip22.mp4", "clip39.mp4"):
        (root / name).write_bytes(b"synthetic media boundary")
        (root / name).with_suffix(".txt").write_text("NORA7 and IVAN9 in an approved target")
    monkeypatch.setattr(
        dataset.subprocess,
        "run",
        lambda args, **kwargs: SimpleNamespace(
            returncode=0,
            stdout=json.dumps(
                probe(count=39 if "39" in Path(args[-1]).name else 22, width=1152, height=864)
            ),
        ),
    )
    run = tmp_path / "runs/new"
    run.mkdir(parents=True)
    cfg = wrapper.validate_run_config(
        {
            "run_id": "new",
            "dataset": {"path": str(root)},
            "base_model": recipe.MODEL,
            "triggers": ["NORA7", "IVAN9"],
            "steps": 5,
            "rank": 32,
            "resolution": [768, 1024],
            "gradient_accumulation": 2,
        },
        tmp_path,
    )
    native = wrapper.build_native_config(cfg, run)
    process = native["config"]["process"][0]
    assert "trigger_word" not in process
    assert process["model"]["arch"] == "minimax_h3"
    assert process["model"]["quantize"] is False and process["model"]["quantize_te"] is False
    assert process["train"]["optimizer"] == "adamw"
    assert process["train"]["gradient_accumulation"] == 2
    assert "gradient_accumulation_steps" not in process["train"]
    assert process["train"]["audio_loss_multiplier"] == 1.0
    assert [d["num_frames"] for d in process["datasets"]] == [1, 22, 39]
    assert process["datasets"][0]["resolution"] == [768, 1024]
    for row in process["datasets"][1:]:
        assert row["resolution"] == [1024] and row["fps"] == 24
        assert row["auto_frame_count"] is False and row["shrink_video_to_frames"] is True
        assert row["do_audio"] is True and row["square_crop"] is False
        alias = next(Path(row["folder_path"]).glob("*.mp4"))
        assert alias.resolve().parent == root
        assert alias.with_suffix(".txt").read_text().startswith("NORA7 and IVAN9")
    facts = json.loads((run / "h3-inputs.json").read_text())
    assert {(r["width"], r["height"], r["frames"]) for r in facts if r["frames"] > 1} == {
        (1152, 864, 22),
        (1152, 864, 39),
    }


def test_h3_pair_binds_actual_trained_network_recipe_and_no_assistant(tmp_path, monkeypatch):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    calls = {"models": [], "networks": [], "configs": []}

    class Config:
        def __init__(self, **kwargs):
            self.__dict__.update(kwargs)

    class NetworkConfig(Config):
        def __init__(self, **kwargs):
            super().__init__(conv=None, conv_alpha=None, dropout=None, **kwargs)

    class Network:
        def __init__(self, **kwargs):
            calls["networks"].append(kwargs)

        def force_to(self, *args, **kwargs):
            pass

        def _update_torch_multiplier(self):
            pass

        def apply_to(self, *args):
            calls["apply"] = args

        def load_weights(self, value):
            calls["weights"] = value

        def eval(self):
            pass

    class Model:
        is_transformer = True
        target_lora_modules = ["MiniMaxH3Transformer"]
        device_torch = "cuda:0"

        def __init__(self, **kwargs):
            calls["models"].append(kwargs)

        @classmethod
        def get_train_scheduler(cls):
            return "native-H3-scheduler"

        def load_model(self):
            pass

        def get_model_to_train(self):
            return "trained-transformer"

        def generate_images(self, configs, sampler):
            assert self.network.can_merge_in is False
            calls["configs"].append(configs)
            for config in configs:
                Path(config.output_path).write_bytes(b"synthetic inference boundary")

    monkeypatch.setitem(
        sys.modules,
        "torch",
        SimpleNamespace(
            no_grad=nullcontext, float32="fp32", cuda=SimpleNamespace(empty_cache=lambda: None)
        ),
    )
    monkeypatch.setitem(
        sys.modules,
        "toolkit.config_modules",
        SimpleNamespace(
            GenerateImageConfig=Config, ModelConfig=Config, NetworkConfig=NetworkConfig
        ),
    )
    monkeypatch.setitem(
        sys.modules, "toolkit.util.get_model", SimpleNamespace(get_model_class=lambda _: Model)
    )
    monkeypatch.setitem(
        sys.modules, "toolkit.lora_special", SimpleNamespace(LoRASpecialNetwork=Network)
    )
    run = tmp_path / "runs/comparison"
    run.mkdir(parents=True)
    cfg = {"base_model": recipe.MODEL, "rank": 2, "alpha": 4}
    (run / "source-run.json").write_text(json.dumps(cfg))
    checkpoint = run / "selected-checkpoint.safetensors"
    checkpoint.write_bytes(weights())
    model = recipe.model_config(tmp_path)
    native = {
        "config": {
            "process": [
                {
                    "model": model,
                    "network": {
                        "type": "lora",
                        "linear": 2,
                        "linear_alpha": 4,
                        "transformer_only": True,
                        "network_kwargs": {"only_if_contains": ["blocks.20.attn.out_proj"]},
                        "pretrained_lora_path": "/private/initializer.safetensors",
                    },
                    "train": {"dtype": "bf16", "optimizer": "adamw"},
                    "datasets": [
                        {
                            "folder_path": "/private/input",
                            "num_frames": 1,
                            "fps": 24,
                            "resolution": [1024],
                        }
                    ],
                }
            ]
        }
    }
    (run / "source-native-config.json").write_text(json.dumps(native))
    request = {
        "run_id": "comparison",
        "source_run_id": "source",
        "checkpoint": "chosen.safetensors",
        "checkpoint_sha256": recipe.sha256(checkpoint),
        "prompts": ["NORA7 beside IVAN9"],
        "seeds": [7, 42],
        "width": 512,
        "height": 288,
        "num_frames": 39,
        "frame_rate": 24,
        "inference_steps": 12,
        "guidance_scale": 4,
    }
    path = run / "generation.json"
    path.write_text(json.dumps(request))
    real_runpy = generation.runpy.run_path

    def offline_rules(value):
        result = real_runpy(value)
        result["download_assets"] = lambda *args, **kwargs: calls.update(download=kwargs)
        return result

    monkeypatch.setattr(generation.runpy, "run_path", offline_rules)
    assert generation.generate(path, "aitoolkit") == 0
    assert len(calls["models"]) == 1 and calls["download"] == {"training_adapter": False}
    assert "assistant_lora_path" not in vars(calls["models"][0]["model_config"])
    assert "lora_path" not in vars(calls["models"][0]["model_config"])
    binding = calls["networks"][0]
    assert binding["lora_dim"] == 2 and binding["alpha"] == 4
    assert binding["only_if_contains"] == ["blocks.20.attn.out_proj"]
    assert binding["base_model"].network is not None
    assert calls["weights"] == str(checkpoint)
    base, trained = calls["configs"]
    for left, right in zip(base, trained, strict=True):
        assert (left.prompt, left.seed, left.num_frames, left.fps) == (
            right.prompt,
            right.seed,
            39,
            24,
        )
        assert left.network_multiplier == 0 and right.network_multiplier == 1
        assert left.output_ext == right.output_ext == "mp4"
    manifest = json.loads((run / "output/comparison.json").read_text())
    assert manifest["state"] == "complete" and manifest["comparison_training_adapter"] is False
    assert "/private/" not in json.dumps(manifest["effective_native_config"])
    assert not checkpoint.exists()
