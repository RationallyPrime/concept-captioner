#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Use debug or release." >&2; exit 2 ;; esac
cd "$repo_dir/app"
swift build -c "$configuration" --product ConceptStudio
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
bundle="$repo_dir/app/dist/ConceptStudio.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/ConceptStudio" "$bundle/Contents/MacOS/ConceptStudio"
for resource in "$bin_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    cp -R "$resource" "$bundle/Contents/Resources/"
done
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>is.conceptstudio.app</string>
<key>CFBundleName</key><string>ConceptStudio</string>
<key>CFBundleDisplayName</key><string>ConceptStudio</string>
<key>CFBundleExecutable</key><string>ConceptStudio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>Choose photos for your training project.</string>
</dict></plist>
PLIST
echo "$bundle"
