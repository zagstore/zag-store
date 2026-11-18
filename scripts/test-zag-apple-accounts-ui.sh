#!/bin/bash
# Simulator UI walkthrough of the debug-only Apple Accounts screen. Builds a
# throwaway simulator app from the real screen, the account directory, the
# sign-in model and the simulation (with DEBUG, as the Debug app does),
# launches it with -ZagAppleAccountsDebugDemo (the screen plays a scripted
# flow through the same calls its buttons make, with synthetic accounts
# only), takes a screenshot at every step, records a video, and fails on any
# failed in-app check. Nothing contacts Apple or an anisette provider; the
# simulator's real Keychain stores the simulated sessions.
#
# Usage: scripts/test-zag-apple-accounts-ui.sh [output-directory]
#   ZAG_SIMULATOR=<name>   default: iPhone 17 (booted here and shut down after)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-apple-accounts-ui-build.XXXXXX")
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp/}zag-apple-accounts-ui.XXXXXX")}"
mkdir -p "$OUT"
BUNDLE=local.zagstore.apple-accounts-ui
APP="$WORK/SignIn.app"
mkdir -p "$APP"
cat > "$WORK/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>LOCALTEST1.$BUNDLE</string>
<key>keychain-access-groups</key><array><string>LOCALTEST1.$BUNDLE</string></array>
</dict></plist>
PLIST
# The app's tint helper, taken verbatim from its source (it lives in a file
# with many app dependencies); its Color(hex:) fallback is unused for 6-digit hex.
python3 -I - "$ROOT/Feather/Views/TabView/VariedTabbarView.swift" "$WORK/ZagWideGamutTint.swift" <<'PY2'
import re, sys
text = open(sys.argv[1]).read()
block = re.search(r"enum ZagWideGamutTint \{.*?\n\}\n", text, re.S).group(0)
open(sys.argv[2], "w").write("import SwiftUI\nimport UIKit\n\n" + block.replace("return Color(hex: hex)", "return .accentColor"))
PY2
xcrun -sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios16.4-simulator" -parse-as-library -D DEBUG \
	-module-cache-path "$WORK/module-cache" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$ROOT/Feather/Views/Settings/Appearance/ZagWallpaper.swift" \
	"$ROOT/Feather/Views/Settings/FreeAccount/ZagFreeAccountDebugSignInView.swift" \
	"$ROOT/Feather/Views/Settings/FreeAccount/ZagAppleAccountsDebugView.swift" \
	"$WORK/ZagWideGamutTint.swift" "$ROOT/scripts/ZagAppleAccountsUIHarness.swift" -o "$APP/SignIn" \
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$WORK/entitlements.plist"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE</string>
<key>CFBundleExecutable</key><string>SignIn</string>
<key>CFBundleName</key><string>Zag Store</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>16.4</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
DEVICE_NAME="${ZAG_SIMULATOR:-iPhone 17}"
UDID=$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for device in devices:
        if device["name"] == name and "iOS" in runtime:
            print(device["udid"], device["state"]); raise SystemExit
' "$DEVICE_NAME")
read -r UDID STATE <<<"$UDID"
[ -n "$UDID" ] || { echo "FAIL: no simulator named $DEVICE_NAME"; exit 1; }

BOOTED_HERE=0
if [ "$STATE" != "Booted" ]; then
	xcrun simctl boot "$UDID"
	BOOTED_HERE=1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
VIDEO_PID=""
cleanup() {
	[ -n "$VIDEO_PID" ] && kill -INT "$VIDEO_PID" 2>/dev/null && wait "$VIDEO_PID" 2>/dev/null || true
	xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
	xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
	[ "$BOOTED_HERE" = 1 ] && xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
LOG="$DATA/tmp/zag-apple-accounts-demo.log"
rm -f "$LOG"

xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT/apple-accounts-flow.mp4" >/dev/null 2>&1 &
VIDEO_PID=$!
sleep 1
xcrun simctl launch "$UDID" "$BUNDLE" -ZagAppleAccountsDebugDemo >/dev/null

SEEN=0
for _ in $(seq 1 900); do
	if [ -f "$LOG" ]; then
		STEPS=$(grep -c '^STEP ' "$LOG" || true)
		while [ "$SEEN" -lt "$STEPS" ]; do
			SEEN=$((SEEN + 1))
			NAME=$(grep '^STEP ' "$LOG" | sed -n "${SEEN}p" | awk '{print $2}')
			sleep 0.7
			xcrun simctl io "$UDID" screenshot "$OUT/$NAME.png" >/dev/null 2>&1
			echo "SCREENSHOT: $NAME"
		done
		grep -q '^DONE' "$LOG" && break
	fi
	sleep 0.2
done
sleep 1
kill -INT "$VIDEO_PID" 2>/dev/null; wait "$VIDEO_PID" 2>/dev/null || true
VIDEO_PID=""
cp "$LOG" "$OUT/demo.log" 2>/dev/null || { echo "FAIL: the demo never started"; exit 1; }

grep '^PASS\|^FAIL' "$OUT/demo.log"
grep -q '^DONE' "$OUT/demo.log" || { echo "FAIL: the demo did not finish"; exit 1; }
! grep -q '^FAIL' "$OUT/demo.log" || { echo "FAIL: an in-app check failed"; exit 1; }
[ "$(grep -c '^PASS' "$OUT/demo.log")" -eq 11 ] || { echo "FAIL: expected 11 in-app checks"; exit 1; }
[ "$(grep -c '^STEP' "$OUT/demo.log")" -eq 10 ] || { echo "FAIL: expected 10 steps"; exit 1; }
[ "$(ls "$OUT"/*.png | wc -l | tr -d ' ')" -eq 10 ] || { echo "FAIL: expected 10 screenshots"; exit 1; }
echo "SUCCESS: Apple Accounts screen walkthrough on $DEVICE_NAME; screenshots and video in $OUT"
