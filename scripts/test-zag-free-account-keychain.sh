#!/bin/bash
# The free-account Keychain secret store against a real iOS Keychain, in a
# throwaway simulator app. Signs, installs on devices and publishes nothing.
#
#   SIMULATOR_ID=<udid>   default: the first available iPhone 17 Pro
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro (' | grep -oE '[0-9A-F-]{36}')}"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-free-account-keychain.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
BUNDLE_ID=local.zagstore.free-account-keychain
APP="$WORK/Keychain.app"
mkdir -p "$APP"
# Simulator apps take their entitlements from this section; without a
# keychain access group the Keychain refuses every call (-34018).
cat > "$WORK/entitlements.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>LOCALTEST1.$BUNDLE_ID</string>
<key>keychain-access-groups</key><array><string>LOCALTEST1.$BUNDLE_ID</string></array>
</dict></plist>
PLIST
xcrun -sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios16.4-simulator" -parse-as-library \
	-module-cache-path "$WORK/module-cache" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$ROOT/scripts/ZagFreeAccountKeychainHarness.swift" -o "$APP/Keychain" \
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$WORK/entitlements.plist"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>Keychain</string>
<key>CFBundleName</key><string>Keychain</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>16.4</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" >/dev/null
xcrun simctl install "$SIMULATOR_ID" "$APP"
LOG="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" data)/tmp/keychain.log"
rm -f "$LOG"
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
for _ in $(seq 1 40); do grep -q DONE "$LOG" 2>/dev/null && break; sleep 0.5; done
cp "$LOG" "$WORK/keychain.log" 2>/dev/null || touch "$WORK/keychain.log"
xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIMULATOR_ID" "$BUNDLE_ID" || true
grep -v DONE "$WORK/keychain.log" || true
grep -q DONE "$WORK/keychain.log" || { echo "FAILED: the harness did not finish"; exit 1; }
if grep -q '^FAIL' "$WORK/keychain.log"; then echo "FAILED: free-account Keychain"; exit 1; fi
echo "SUCCESS: free-account Keychain checks passed"
