#!/bin/bash
# Build the independent iPhone probe as input to the existing sign-only flow.
set -euo pipefail
if [[ $# != 1 || "$1" != /*.ipa || -e "$1" ]]; then
    echo "Provide a new absolute output path ending in .ipa" >&2
    exit 2
fi
source_dir="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
app="$scratch/Payload/OTAProbe.app"
mkdir -p "$app"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OTAProbe</string>
<key>CFBundleIdentifier</key><string>app.zagstore.ota-probe</string>
<key>CFBundleName</key><string>OTA Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos swiftc -sdk "$sdk" -target arm64-apple-ios16.0 -module-cache-path "$scratch/modules" -O \
    "$source_dir/main.swift" -o "$app/OTAProbe"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
(cd "$scratch" && /usr/bin/zip -qr "$scratch/Probe.ipa" Payload)
(set -o noclobber; cat "$scratch/Probe.ipa" > "$1")
