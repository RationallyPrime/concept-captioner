from __future__ import annotations

import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest
from conftest import approving_critique, h3, primary_responder

from concept_captioner import cli
from concept_captioner.endpoints import register
from concept_captioner.endpoints.fake import FakeEndpoint
from concept_captioner.endpoints.openai_compat import OpenAICompatibleEndpoint
from concept_captioner.schemas import CritiqueResult, PrimaryResult
from concept_captioner.types import ImageRef, Request


def _write_job(path: Path, endpoint_kind: str = "fake") -> Path:
    job = path / "job.yaml"
    job.write_text(
        "profile: h3-still\n"
        "concepts:\n  - {trigger: NORA7, class_noun: woman}\n  - {trigger: IVAN9, class_noun: man}\n"
        "samples:\n  solo.png: {NORA7: The only person in the crop.}\n"
        "  pair.png: {NORA7: The woman on the left., IVAN9: The man on the right.}\n  unmapped.png: null\n"
        f"endpoints:\n  captioner: {{kind: {endpoint_kind}, model: test-model}}\n"
    )
    return job


def test_cli_validate_dry_run_and_run(images: Path, tmp_path: Path, capsys):
    register("fake-ok", lambda model, **opts: FakeEndpoint(primary_responder, model=model))
    job = _write_job(tmp_path, "fake-ok")
    assert cli.main(["validate", str(job)]) == 0
    assert cli.main(["run", str(job), "--images", str(images), "--out", str(tmp_path / "out"), "--dry-run"]) == 0
    dry = capsys.readouterr().out
    assert '"needs_mapping"' in dry and "unmapped.png" in dry
    assert cli.main(["run", str(job), "--images", str(images), "--out", str(tmp_path / "out"), "--receipts", str(tmp_path / "calls.jsonl")]) == 0
    assert (tmp_path / "out" / "solo.txt").read_text().startswith("integrated_multimodal_description")
    summary = json.loads((tmp_path / "out" / "_summary.json").read_text())
    assert summary["counts"] == {"ready": 2, "needs_mapping": 1}
    calls = [json.loads(line) for line in (tmp_path / "calls.jsonl").read_text().splitlines()]
    assert len(calls) == 4 and all(c["served_model"] == "test-model" for c in calls)
    assert cli.main(["show-prompt", str(job), "solo.png"]) == 0
    assert "ACTIVE JOB CONFIGURATION" in capsys.readouterr().out


class _StubHandler(BaseHTTPRequestHandler):
    served_model = "stub-model"

    def log_message(self, *args):  # silence
        return None

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = json.loads(self.rfile.read(length))
        assert self.path == "/v1/chat/completions"
        assert self.headers["Authorization"] == "Bearer none"
        schema_name = body.get("response_format", {}).get("json_schema", {}).get("name")
        system = body["messages"][0]["content"]
        user_parts = body["messages"][1]["content"]
        images = [p for p in user_parts if p["type"] == "image_url"]
        assert all(p["image_url"]["url"].startswith("data:image/png;base64,") for p in images)
        if "with NORA7" in system:
            assert images, "the captioner must attach the target image"
        if schema_name == "CritiqueResult":
            content = approving_critique(1).model_dump_json()
        else:
            caption = h3("A photograph frames NORA7, a woman, seated by a window in a blue blouse.") if "NORA7" in system else "x"
            content = PrimaryResult(caption=caption, human_subject_count=1, mapped_subjects_usable=True).model_dump_json()
        payload = {
            "id": "x", "model": self.served_model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": content}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5},
        }
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


@pytest.fixture
def stub_server():
    server = HTTPServer(("127.0.0.1", 0), _StubHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}/v1"
    server.shutdown()


def test_openai_compatible_adapter_roundtrip(stub_server, images: Path):
    endpoint = OpenAICompatibleEndpoint("stub-model", base_url=stub_server)
    request = Request(
        system="job with NORA7",
        user="caption",
        images=(ImageRef((images / "solo.png").read_bytes(), "image/png"),),
        response_schema=PrimaryResult,
    )
    response = asyncio.run(endpoint.describe(request))
    assert response.model_matches and isinstance(response.parsed, PrimaryResult)
    assert response.usage and response.usage.input_tokens == 10
    assert "Authorization" not in json.dumps(dict(response.raw))
    critique = asyncio.run(endpoint.describe(Request(system="s", user="u", response_schema=CritiqueResult)))
    assert isinstance(critique.parsed, CritiqueResult) and critique.parsed.approved
    asyncio.run(endpoint.aclose())


def test_openai_adapter_reports_served_model_mismatch(stub_server):
    endpoint = OpenAICompatibleEndpoint("requested-model", base_url=stub_server)
    response = asyncio.run(endpoint.describe(Request(system="s", user="u")))
    assert response.served_model == "stub-model" and not response.model_matches
    asyncio.run(endpoint.aclose())
