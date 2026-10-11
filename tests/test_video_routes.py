import json

import httpx2
import pytest

from concept_captioner import models
from concept_captioner.job import EndpointSpec
from concept_captioner.models import resolve
from concept_captioner.stages import CaptionDeps, build_captioner, image_content
from concept_captioner.types import ConfigurationError, Sample


@pytest.fixture(autouse=True)
def keys(monkeypatch):
    for name in ("GOOGLE_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"):
        monkeypatch.setenv(name, "fixture")
    monkeypatch.setenv("VLLM_BASE_URL", "http://localhost:8000/v1")


@pytest.mark.parametrize("kind", ["google", "openrouter"])
async def test_actual_sdk_video_wire_and_structured_output(kind):
    seen = []
    caption = '{"caption":"NORA7 moves left to right."}'

    def respond(request):
        seen.append(json.loads(request.content))
        if kind == "google":
            return httpx2.Response(
                200,
                json={
                    "candidates": [
                        {"content": {"parts": [{"text": caption}]}, "finishReason": "STOP"}
                    ]
                },
            )
        return httpx2.Response(
            200,
            json={
                "id": "fixture",
                "object": "chat.completion",
                "created": 0,
                "model": "m",
                "provider": "fixture",
                "choices": [
                    {
                        "index": 0,
                        "finish_reason": "stop",
                        "message": {"role": "assistant", "content": caption},
                    }
                ],
            },
        )

    async with httpx2.AsyncClient(transport=httpx2.MockTransport(respond)) as client:
        resolved = resolve(
            EndpointSpec(
                kind=kind,
                model="gemini-3.8-flash" if kind == "google" else "google/gemini-3.8-flash",
            ),
            http_client=client,
        )
        resolved.require_video()
        result = await build_captioner(resolved).run(
            [
                "Observe the selected clip.",
                image_content(Sample("clip.mp4", b"exact-selected-clip", ".mp4")),
            ],
            instructions="Caption motion.",
            deps=CaptionDeps({"NORA7": "movement"}, ("NORA7",)),
        )
    assert result.output.caption == "NORA7 moves left to right."
    assert len(seen) == 1
    if kind == "google":
        part = seen[0]["contents"][0]["parts"][1]
        assert part["inlineData"]["mime_type"] == "video/mp4"
        assert part["inlineData"]["data"] == "ZXhhY3Qtc2VsZWN0ZWQtY2xpcA=="
        assert part["videoMetadata"]["fps"] == 24
        assert (
            seen[0]["generationConfig"]["responseJsonSchema"]["properties"]["caption"]["type"]
            == "string"
        )
    else:
        part = seen[0]["messages"][-1]["content"][1]
        assert part == {
            "type": "video_url",
            "video_url": {"url": "data:video/mp4;base64,ZXhhY3Qtc2VsZWN0ZWQtY2xpcA=="},
        }
        assert seen[0]["response_format"]["type"] == "json_schema"


@pytest.mark.parametrize("kind", ["openai", "anthropic", "vllm", "vercel", "gateway/openai-chat"])
async def test_python_unsupported_video_route_refuses_before_agent_or_send(kind, monkeypatch):
    import tempfile
    from dataclasses import replace
    from pathlib import Path

    # Resolve is tested separately for these public SDKs; refusal keys off the actual spec kind.
    from conftest import function_model

    from concept_captioner.job import Concept, Job
    from concept_captioner.runner import Runner
    from concept_captioner.sources.local import LocalFolderSource, SidecarSink

    resolved = replace(
        function_model(lambda *_: pytest.fail("Unsupported video reached model")), kind=kind
    )
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder)
        (path / "clip.mp4").write_bytes(b"clip")
        runner = Runner(
            job=Job(
                concepts=[Concept(trigger="NORA7", target_concept="motion")],
                samples={"clip.mp4": {"NORA7": "movement"}},
            ),
            captioner=resolved,
        )
        summary = await runner.run(LocalFolderSource(path), SidecarSink(path))
        assert summary.outcomes[0].status == "failed"
        assert "does not accept video" in summary.outcomes[0].notes[0]
        assert not (path / "clip.txt").exists()


@pytest.mark.parametrize("kind", ["google", "openrouter"])
async def test_encoded_video_guard_counts_prompts_and_schema_before_send(kind, monkeypatch):
    seen = []
    monkeypatch.setattr(models, "MAX_VIDEO_REQUEST_BYTES", 1000)

    def respond(request):
        seen.append(request)
        pytest.fail("Oversized body reached transport")

    async with httpx2.AsyncClient(transport=httpx2.MockTransport(respond)) as client:
        resolved = resolve(
            EndpointSpec(
                kind=kind,
                model="google/gemini-3.8-flash" if kind == "openrouter" else "gemini-3.8-flash",
            ),
            http_client=client,
        )
        with pytest.raises(ConfigurationError, match="20 MiB client limit"):
            await build_captioner(resolved).run(
                ["x" * 1200, image_content(Sample("clip.mp4", b"small-clip", ".mp4"))],
                instructions="Prompt and schema count.",
                deps=CaptionDeps({"NORA7": "movement"}, ("NORA7",)),
            )
    assert seen == []


@pytest.mark.parametrize("google", [True, False])
async def test_production_twenty_mib_boundary_is_encoded_not_raw(google):
    payload = (
        {"contents": [{"parts": [{"inlineData": {"mimeType": "video/mp4", "data": "AA=="}}]}]}
        if google
        else {
            "messages": [
                {
                    "content": [
                        {"type": "video_url", "video_url": {"url": "data:video/mp4;base64,AA=="}}
                    ]
                }
            ]
        }
    )
    payload["instructions"] = ""
    payload["instructions"] = "x" * (
        models.MAX_VIDEO_REQUEST_BYTES - len(json.dumps(payload).encode()) - 1
    )
    body = json.dumps(payload).encode()
    assert len(body) < models.MAX_VIDEO_REQUEST_BYTES
    await models._check_video_request_size(
        httpx2.Request("POST", "https://fixture.invalid", content=body)
    )
    payload["instructions"] += "x" * 100
    with pytest.raises(ConfigurationError, match="20 MiB client limit"):
        await models._check_video_request_size(
            httpx2.Request("POST", "https://fixture.invalid", json=payload)
        )


@pytest.mark.parametrize("kind", ["google", "openrouter"])
async def test_retry_body_is_measured_again_before_second_send(kind, monkeypatch):
    requests = []

    def respond(request):
        requests.append(request)
        # The first request fits; the SDK's real retry adds response + validator feedback.
        monkeypatch.setattr(models, "MAX_VIDEO_REQUEST_BYTES", len(request.content) + 50)
        caption = json.dumps({"caption": "Unmapped " + "x" * 256})
        if kind == "google":
            return httpx2.Response(
                200,
                json={
                    "candidates": [
                        {"content": {"parts": [{"text": caption}]}, "finishReason": "STOP"}
                    ]
                },
            )
        return httpx2.Response(
            200,
            json={
                "id": "fixture",
                "object": "chat.completion",
                "created": 0,
                "model": "m",
                "provider": "fixture",
                "choices": [
                    {
                        "index": 0,
                        "finish_reason": "stop",
                        "message": {"role": "assistant", "content": caption},
                    }
                ],
            },
        )

    async with httpx2.AsyncClient(transport=httpx2.MockTransport(respond)) as client:
        resolved = resolve(
            EndpointSpec(
                kind=kind,
                model="google/gemini-3.8-flash" if kind == "openrouter" else "gemini-3.8-flash",
            ),
            http_client=client,
        )
        with pytest.raises(ConfigurationError, match="20 MiB client limit"):
            await build_captioner(resolved).run(
                ["Caption this clip.", image_content(Sample("clip.mp4", b"clip", ".mp4"))],
                instructions="Describe motion.",
                deps=CaptionDeps({"NORA7": "movement"}, ("NORA7",)),
            )
    assert len(requests) == 1
