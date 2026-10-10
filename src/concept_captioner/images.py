"""Build the image bytes that leave the machine: resized under provider limits and re-encoded.

Re-encoding drops EXIF/IPTC/XMP as a side effect (the ICC profile is kept). The resize exists
because providers reject large images and charge more tokens for them.
"""

from __future__ import annotations

import io

from PIL import Image, ImageOps

from .types import ConfigurationError


def provider_image(
    data: bytes,
    *,
    suffix: str,
    max_bytes: int = 8 * 1024 * 1024,
    max_side: int = 3072,
) -> tuple[bytes, str]:
    """Return ``(bytes, media_type)`` for the request."""
    if max_bytes <= 0 or max_side <= 0:
        raise ConfigurationError("image limits must be positive")
    with Image.open(io.BytesIO(data)) as opened:
        opened.load()
        image = ImageOps.exif_transpose(opened)
        image.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
        icc = image.info.get("icc_profile")
        common = {"icc_profile": icc} if icc else {}
        if image.mode not in {"RGB", "L"}:
            image = image.convert("RGB")
        use_jpeg = suffix.lower() in {".jpg", ".jpeg"}
        while True:
            out = io.BytesIO()
            if use_jpeg:
                image.save(out, format="JPEG", quality=95, subsampling=0, optimize=True, **common)
                media_type = "image/jpeg"
            else:
                image.save(out, format="PNG", optimize=True, **common)
                media_type = "image/png"
            payload = out.getvalue()
            if len(payload) <= max_bytes:
                return payload, media_type
            w, h = image.size
            if w == 1 and h == 1:
                raise ConfigurationError("image could not be encoded below the byte cap")
            image = image.resize(
                (max(1, int(w * 0.8)), max(1, int(h * 0.8))), Image.Resampling.LANCZOS
            )
