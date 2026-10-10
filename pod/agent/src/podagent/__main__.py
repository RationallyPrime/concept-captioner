"""``python -m podagent``: load settings (refuse without a token), serve with uvicorn."""

from __future__ import annotations

import argparse
import sys

from .settings import SettingsError, load_settings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="podagent", description="concept-captioner pod agent")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8800)
    args = parser.parse_args(argv)
    try:
        settings = load_settings()
    except SettingsError as error:
        print(f"podagent: {error}", file=sys.stderr)
        return 2
    import uvicorn

    from .app import create_app

    uvicorn.run(create_app(settings), host=args.host, port=args.port, log_level="info")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
