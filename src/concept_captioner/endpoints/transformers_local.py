"""In-process open-weights VLM via ``transformers``. No server, no network after the download.

Use this for notebooks, small models, or a single GPU box without vLLM. It declares
``structured_output=False``, so the runner wraps it in ``SchemaEnforcer`` automatically and
JSON comes from prompting plus validation rather than constrained decoding. For throughput and
native JSON-schema decoding on a pod, serve the same model with vLLM and use
``OpenAICompatibleEndpoint`` instead.
"""

from __future__ import annotations

import asyncio
import io
import time
from typing import Any

from ..types import Capabilities, EndpointError, Request, Response


class TransformersEndpoint:
    name = "transformers"
    capabilities = Capabilities(
        images=True, structured_output=False, thinking=False, seed=True, max_images_per_request=4
    )

    def __init__(
        self,
        model: str,
        *,
        device_map: str | dict[str, Any] = "auto",
        torch_dtype: str = "auto",
        trust_remote_code: bool = False,
        load_kwargs: dict[str, Any] | None = None,
    ) -> None:
        self.model = model
        try:
            import torch
            from transformers import AutoModelForImageTextToText, AutoProcessor
        except ImportError as exc:  # pragma: no cover - optional dependency
            raise EndpointError(
                "install concept-captioner[local] for the in-process transformers endpoint"
            ) from exc
        self._torch = torch
        dtype = getattr(torch, torch_dtype) if torch_dtype != "auto" else "auto"
        self._processor = AutoProcessor.from_pretrained(model, trust_remote_code=trust_remote_code)
        self._model = AutoModelForImageTextToText.from_pretrained(
            model,
            device_map=device_map,
            torch_dtype=dtype,
            trust_remote_code=trust_remote_code,
            **(load_kwargs or {}),
        )
        self._lock = asyncio.Lock()

    def _generate(self, request: Request) -> str:
        from PIL import Image

        images = [Image.open(io.BytesIO(image.data)).convert("RGB") for image in request.images]
        content: list[dict[str, Any]] = [{"type": "image"} for _ in images]
        content.append({"type": "text", "text": request.user})
        messages = [
            {"role": "system", "content": [{"type": "text", "text": request.system}]},
            {"role": "user", "content": content},
        ]
        prompt = self._processor.apply_chat_template(messages, add_generation_prompt=True)
        inputs = self._processor(text=[prompt], images=images or None, return_tensors="pt").to(
            self._model.device
        )
        generate_kwargs: dict[str, Any] = {"max_new_tokens": request.max_output_tokens}
        if request.temperature is None or request.temperature == 0:
            generate_kwargs["do_sample"] = False
        else:
            generate_kwargs["do_sample"] = True
            generate_kwargs["temperature"] = request.temperature
        if request.seed is not None:
            self._torch.manual_seed(request.seed)
        with self._torch.inference_mode():
            output = self._model.generate(**inputs, **generate_kwargs)
        new_tokens = output[:, inputs["input_ids"].shape[1] :]
        return self._processor.batch_decode(new_tokens, skip_special_tokens=True)[0]

    async def describe(self, request: Request) -> Response:
        started = time.monotonic()
        async with self._lock:  # one generation at a time on a single model
            text = await asyncio.to_thread(self._generate, request)
        return Response(
            text=text,
            parsed=None,
            requested_model=self.model,
            served_model=self.model,
            latency_ms=int((time.monotonic() - started) * 1000),
            request_sha256=request.sha256,
            raw={"backend": "transformers", "model": self.model},
        )

    async def aclose(self) -> None:
        return None
