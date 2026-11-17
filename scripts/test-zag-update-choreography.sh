#!/bin/bash
# On-screen choreography of the update control in a simulator: morph timing,
# status-line ordering after geometry arrival, same-stage digit updates, the
# website success green and interruption. Builds a throwaway app from the
# production control sources; signs, installs on devices and publishes nothing.
#
#   SIMULATOR_ID=<udid>   simulator to use (default: first booted iPhone)
#   SIMCTL_CHILD_ZAG_DUMP=<dir>   also write every sampled frame as PNG to <dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}' || true)}"
if [ -z "$SIMULATOR_ID" ]; then
	echo "No booted iPhone simulator; set SIMULATOR_ID" >&2
	exit 2
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-update-choreography.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
BUNDLE_ID=local.zagstore.update-choreography
APP="$WORK/Choreography.app"
mkdir -p "$APP"
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:])
s=(root/'Feather/Views/TabView/Bars/ZagAppsTabIcon.swift').read_text()
palette=s.split('enum ZagSelfUpdateSpectrum {',1)[1].split('/// A single lightweight animated gradient',1)[0]
(work/'Spectrum.swift').write_text('import SwiftUI\nenum ZagSelfUpdateSpectrum {'+palette)
(work/'HostTint.swift').write_text('import SwiftUI\nenum ZagWideGamutTint { static func color(hex: String) -> Color { .blue } }')
PY
xcrun -sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios17.0-simulator" -parse-as-library \
	-module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" \
	"$ROOT/Feather/Utilities/ZagUpdateProgressPresentation.swift" \
	"$ROOT/Feather/Views/Settings/ZagUpdateSpectrumSurface.swift" \
	"$ROOT/Feather/Views/Settings/ZagSelfUpdateActionControl.swift" \
	"$ROOT/Feather/Views/Common/ZagNumericTextTransition.swift" \
	"$WORK/Spectrum.swift" "$WORK/HostTint.swift" "$ROOT/scripts/ZagUpdateChoreographyHarness.swift" \
	-o "$APP/Choreography"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>Choreography</string>
<key>CFBundleName</key><string>Choreography</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
xcrun simctl install "$SIMULATOR_ID" "$APP"
set +e
xcrun simctl launch --console-pty --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" | tee "$WORK/out.log"
set -e
xcrun simctl uninstall "$SIMULATOR_ID" "$BUNDLE_ID" || true
grep -q '^SUCCESS: ' "$WORK/out.log"
