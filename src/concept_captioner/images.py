"""Build the visual derivative that leaves the machine: metadata-stripped, size-capped, ICC kept."""

from __future__ import annotations

import io

from PIL import Image, ImageOps

from .types import ConfigurationError, ImageRef


def provider_image(
    data: bytes,
    *,
    suffix: str,
    max_bytes: int = 8 * 1024 * 1024,
    max_side: int = 3072,
) -> ImageRef:
    """Re-encode in memory without EXIF/IPTC/XMP. Original bytes are never sent as-is."""
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
                mime = "image/jpeg"
            else:
                image.save(out, format="PNG", optimize=True, **common)
                mime = "image/png"
            payload = out.getvalue()
            if len(payload) <= max_bytes:
                return ImageRef(payload, mime)
            w, h = image.size
            if w == 1 and h == 1:
                raise ConfigurationError("image could not be encoded below the byte cap")
            image = image.resize((max(1, int(w * 0.8)), max(1, int(h * 0.8))), Image.Resampling.LANCZOS)


def image_dimensions(data: bytes) -> tuple[int, int]:
    with Image.open(io.BytesIO(data)) as image:
        return image.size
