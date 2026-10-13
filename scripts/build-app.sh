#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Use debug or release." >&2; exit 2 ;; esac
signing_identity="${CONCEPTSTUDIO_SIGNING_IDENTITY:-}"
notary_profile="${CONCEPTSTUDIO_NOTARY_PROFILE:-}"
if [ "$configuration" = debug ] && [ -z "$signing_identity" ]; then
    # A stable certificate keeps the code identity the same across rebuilds, so Keychain items and
    # folder bookmarks survive them, and it is what makes the sandbox entitlement apply at all.
    signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
    if [ -z "$signing_identity" ]; then
        echo "warning: no Apple Development identity in this Mac's Keychain; the debug build is unsigned and NOT sandboxed." >&2
    fi
fi
if [ "$configuration" = release ]; then
    case "$signing_identity" in
        "Developer ID Application: "*) ;;
        *) echo 'Release builds require CONCEPTSTUDIO_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)".' >&2; exit 2 ;;
    esac
    if ! security find-identity -v -p codesigning | grep -Fq "\"$signing_identity\""; then
        echo "The selected Developer ID Application identity is not available in this Mac's Keychain." >&2
        exit 2
    fi
fi
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
<key>NSPhotoLibraryUsageDescription</key><string>Choose images and video clips for your training project.</string>
</dict></plist>
PLIST
if [ -n "$signing_identity" ]; then
    timestamp="--timestamp"
    [ "$configuration" = debug ] && timestamp="--timestamp=none"
    codesign --force --sign "$signing_identity" --options runtime "$timestamp" \
        --entitlements "$repo_dir/app/ConceptStudio.entitlements" "$bundle"
    codesign --verify --strict --verbose=2 "$bundle"
    if ! codesign -d --entitlements - --xml "$bundle" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
        echo "The signed app does not carry the sandbox entitlement." >&2
        exit 1
    fi
fi
if [ "$configuration" = release ] && [ -n "$notary_profile" ]; then
    # notarytool reads the Apple ID and app-specific password stored once with
    # `xcrun notarytool store-credentials <profile>`; nothing secret passes through this script.
    archive="$repo_dir/app/dist/ConceptStudio-notarize.zip"
    ditto -c -k --keepParent "$bundle" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
    rm -f "$archive"
    xcrun stapler staple "$bundle"
    spctl --assess --type execute --verbose=2 "$bundle"
elif [ "$configuration" = release ]; then
    echo "warning: CONCEPTSTUDIO_NOTARY_PROFILE is not set; the release build is signed but not notarized." >&2
fi
echo "$bundle"
