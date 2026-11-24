#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
staging=$(mktemp -d "${TMPDIR:-/tmp}/volumemac.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/VolumeMac.app"
mkdir -p "$app/Contents/MacOS"
xcrun clang -std=c11 -O2 -mmacosx-version-min=14.2 -c Sources/MixerDSP.c -o "$staging/MixerDSP.o"
MACOSX_DEPLOYMENT_TARGET=14.2 xcrun swiftc -swift-version 5 -O -parse-as-library -import-objc-header Sources/MixerDSP.h Sources/*.swift "$staging/MixerDSP.o" \
  -o "$app/Contents/MacOS/VolumeMac"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>studio.dreamar.volumemac.prototype</string>
    <key>CFBundleExecutable</key><string>VolumeMac</string>
    <key>CFBundleName</key><string>VolumeMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>CFBundleShortVersionString</key><string>0.7.1</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>VolumeMac processes audio from the selected app to adjust its volume. Audio stays on this Mac and is not recorded.</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
mkdir -p build
ditto --norsrc "$app" build/VolumeMac.app
find build/VolumeMac.app -name '._*' -type f -delete
codesign --verify --strict build/VolumeMac.app
