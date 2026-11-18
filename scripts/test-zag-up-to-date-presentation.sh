#!/bin/bash
# Software Update's up-to-date state must be in its final place on the FIRST
# presentation and stay there: centred between the section above and the
# bottom (3 pt below the middle), unmoving once the push has settled, and in
# the same place after More Details and back and after leaving and returning.
# Builds a throwaway simulator app from the production views
# (scripts/ZagUpToDatePresentationHarness.swift); signs, installs on devices
# and publishes nothing.
#
#   SIMULATOR_ID=<udid>   default: the first available iPhone 17 Pro
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro (' | grep -oE '[0-9A-F-]{36}')}"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-up-to-date-presentation.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
BUNDLE_ID=local.zagstore.up-to-date-presentation
APP="$WORK/Presentation.app"
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios17.0-simulator" -parse-as-library \
	-module-cache-path "$WORK/module-cache" \
	"$ROOT/Feather/Utilities/ZagUpdateReleaseNotes.swift" \
	"$ROOT/Feather/Utilities/ZagInstalledRelease.swift" \
	"$ROOT/Feather/Views/Settings/ZagSoftwareUpToDateView.swift" \
	"$ROOT/scripts/ZagAccountCloseEnvironmentStub.swift" \
	"$ROOT/scripts/ZagUpToDatePresentationHarness.swift" -o "$APP/Presentation"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>Presentation</string>
<key>CFBundleName</key><string>Presentation</string>
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
xcrun simctl install "$SIMULATOR_ID" "$APP"
LOG="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" data)/tmp/presentation.log"
failures=0
for size in large extra-large; do
	xcrun simctl ui "$SIMULATOR_ID" content_size "$size"
	rm -f "$LOG"
	xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
	for _ in $(seq 1 40); do grep -q DONE "$LOG" 2>/dev/null && break; sleep 0.5; done
	grep -q DONE "$LOG" || { echo "FAIL: $size: the harness did not finish"; failures=$((failures + 1)); continue; }
	/usr/bin/python3 -I - "$LOG" "$size" <<'PY' || failures=$((failures + 1))
import re, sys
log = open(sys.argv[1]).read(); size = sys.argv[2]; failed = 0
def check(ok, message):
    global failed
    print(("PASS: " if ok else "FAIL: ") + f"{size}: {message}"); failed += not ok
steps = {m[0]: dict(mid=float(m[1]), expected=float(m[2]))
         for m in re.findall(r"STEP (\w+) .*mid=([-\d.]+) expected=([-\d.]+)", log)}
samples = {m[0]: (float(m[1]), float(m[2])) for m in re.findall(r"SAMPLES (\w+) min=([-\d.]+) max=([-\d.]+)", log)}
for step in ("first", "back", "second"):
    s = steps[step]
    check(abs(s["mid"] - s["expected"]) <= 1, f"{step}: centred below the section ({s['mid']:.1f} vs {s['expected']:.1f})")
for step in ("first", "second"):
    low, high = samples[step]
    check(high - low <= 0.5, f"{step}: does not move once presented ({low:.1f}-{high:.1f})")
check(abs(steps["first"]["mid"] - steps["back"]["mid"]) <= 0.5, "More Details and back leave it in place")
check(abs(steps["first"]["mid"] - steps["second"]["mid"]) <= 0.5, "leaving and returning puts it in the same place")
sys.exit(1 if failed else 0)
PY
done
xcrun simctl ui "$SIMULATOR_ID" content_size large
xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIMULATOR_ID" "$BUNDLE_ID" || true
[ "$failures" -eq 0 ] && echo "SUCCESS: up-to-date presentation checks passed" || { echo "FAILED: up-to-date presentation"; exit 1; }
