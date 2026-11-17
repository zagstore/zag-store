#!/bin/bash
# Simulator captures of Software Update's up-to-date state and More Details
# (production views, sample Beta 4 release), for comparison with the iOS
# Settings references. Builds a throwaway app; signs, installs on devices and
# publishes nothing.
#
#   capture-zag-software-update-screens.sh <output dir> [release-notes.md]
#   SIMULATOR_ID=<udid>    default: iPhone 17 Pro Max (430 × 932 pt, as the references)
#   CONTENT_SIZE=<size>    default: extra-large (the references' Dynamic Type)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; NOTES="${2:-}"
mkdir -p "$OUT"
SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro Max' | grep -oE '[0-9A-F-]{36}')}"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-software-update-screens.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
BUNDLE_ID=local.zagstore.software-update-screens
APP="$WORK/Screens.app"
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios17.0-simulator" -parse-as-library \
	-module-cache-path "$WORK/module-cache" \
	"$ROOT/Feather/Utilities/ZagUpdateReleaseNotes.swift" \
	"$ROOT/Feather/Utilities/ZagInstalledRelease.swift" \
	"$ROOT/Feather/Views/Settings/ZagSoftwareUpToDateView.swift" \
	"$ROOT/scripts/ZagSoftwareUpdateScreensHarness.swift" -o "$APP/Screens"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>Screens</string>
<key>CFBundleName</key><string>Screens</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" >/dev/null
xcrun simctl status_bar "$SIMULATOR_ID" override --time 8:33 >/dev/null 2>&1 || true
xcrun simctl ui "$SIMULATOR_ID" content_size "${CONTENT_SIZE:-extra-large}"
xcrun simctl install "$SIMULATOR_ID" "$APP"
for appearance in dark light; do
	xcrun simctl ui "$SIMULATOR_ID" appearance "$appearance"
	for screen in uptodate details legacy; do
		mode=$screen; legacy=0
		[ "$screen" = legacy ] && { mode=details; legacy=1; }
		SIMCTL_CHILD_ZAG_SCREEN=$mode SIMCTL_CHILD_ZAG_LEGACY=$legacy SIMCTL_CHILD_ZAG_NOTES="$NOTES" \
			xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
		sleep 3
		xcrun simctl io "$SIMULATOR_ID" screenshot "$OUT/$screen-$appearance.png" >/dev/null 2>&1
	done
done
xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" || true
xcrun simctl uninstall "$SIMULATOR_ID" "$BUNDLE_ID" || true
ls "$OUT"
