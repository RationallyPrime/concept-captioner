#!/bin/bash
# Render actual SwiftUI content offscreen with offline demo services.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
output=${1:-"$repo/app/dist/visual-check"}
mkdir -p "$output"
output=$(cd "$output" && pwd)
snapshot=$(mktemp -d "${TMPDIR:-/tmp}/conceptstudio-preview.XXXXXX")

python3 - "$repo" "$snapshot" "$output" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

repo, snapshot, output = map(Path, sys.argv[1:])
app = repo / "app"
yams = app / ".build/checkouts/Yams"
if not (yams / "Package.swift").is_file():
    raise SystemExit("Missing local Yams checkout. Run the existing app build once before rendering.")

original_manifest = (app / "Package.swift").read_text()
remote = '.package(url: "https://github.com/jpsim/Yams.git", from: "6.0.2")'
if original_manifest.count(remote) != 1:
    raise SystemExit("App dependency declaration changed; inspect before adapting the preview snapshot.")
(snapshot / "Package.swift").write_text(
    original_manifest.replace(remote, f".package(path: {json.dumps(str(yams))})")
)
source_files = sorted(
    path for folder in ("Sources", "Tests") for path in (app / folder).rglob("*") if path.is_file()
)
hashes = {}
for source in source_files:
    relative = source.relative_to(app)
    target = snapshot / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    data = source.read_bytes()
    target.write_bytes(data)
    hashes[str(relative)] = hashlib.sha256(data).hexdigest()

for relative, expected in hashes.items():
    if hashlib.sha256((app / relative).read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Source changed while taking snapshot: {relative}. Run again after the author freezes it.")
if (app / "Package.swift").read_text() != original_manifest:
    raise SystemExit("Package.swift changed while taking snapshot. Run again after the author freezes it.")

manifest = {
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
    "snapshot": str(snapshot),
    "package_manifest_sha256": hashlib.sha256(original_manifest.encode()).hexdigest(),
    "dependency": "Existing local Yams checkout; no package download",
    "source_sha256": hashes,
}
(output / "source-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

export CONCEPTSTUDIO_RENDER_PREVIEWS=1
export CONCEPTSTUDIO_PREVIEW_OUTPUT="$output"
swift test --package-path "$snapshot" --filter PreviewRenderTests 2>&1 | tee "$output/render.log"
printf '\nOffscreen PNGs: %s\nSource snapshot: %s\n' "$output" "$snapshot"
