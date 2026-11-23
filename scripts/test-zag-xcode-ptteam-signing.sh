#!/bin/bash
# Proves Zag Store's existing strict signing engine can sign a disposable app
# with the Xcode-issued free Apple Account ("Personal Team") identity already
# in the login Keychain, reusing ZagExternalKeychainSigningKey +
# ZagStrictComponentSigning. The engine signs; codesign only verifies.
#
# Nothing here contacts Apple: it reuses the certificate and profile Xcode
# already issued. The private key is never exported.
#
# Inputs (environment, with defaults for this experiment):
#   ZAG_XCODE_APP   the app Xcode built and signed (its cert chain + a copy to
#                   re-sign are taken from it)
#   ZAG_PROFILE     the .mobileprovision Xcode issued for dev.zagstore.ptteamprobe
#   ZAG_DEVICE_UDID optional device UDID to test eligibility against
#   ZAG_ZSIGN_BRANCH  default: zag-free-account-signing
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${ZAG_ZSIGN_BRANCH:-zag-free-account-signing}"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-ptteam-sign.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Locate the Xcode-signed app and its profile.
XCODE_APP="${ZAG_XCODE_APP:-}"
if [ -z "$XCODE_APP" ]; then
	XCODE_APP=$(find "${TMPDIR:-/tmp}" "$HOME/Library/Developer/Xcode/DerivedData" -type d -name PTTeamProbe.app -path '*Debug-iphoneos*' 2>/dev/null | head -1)
fi
[ -d "$XCODE_APP" ] || { echo "FAIL: no Xcode-signed PTTeamProbe.app found; set ZAG_XCODE_APP" >&2; exit 1; }

PROFILE="${ZAG_PROFILE:-}"
if [ -z "$PROFILE" ]; then
	DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
	for p in "$DIR"/*.mobileprovision; do
		[ -f "$p" ] || continue
		if security cms -D -i "$p" 2>/dev/null | grep -q "dev.zagstore.ptteamprobe"; then PROFILE="$p"; break; fi
	done
fi
[ -f "$PROFILE" ] || { echo "FAIL: no .mobileprovision for dev.zagstore.ptteamprobe found; set ZAG_PROFILE" >&2; exit 1; }
echo "Xcode app:  $XCODE_APP"
echo "Profile:    $PROFILE"

# A disposable copy the engine re-signs in place; the Xcode original is untouched.
cp -R "$XCODE_APP" "$WORK/Disposable.app"

# The chain certificates from the Xcode-signed app, so the engine can embed the
# full chain (leaf -> WWDR -> root) for device install.
mkdir -p "$WORK/intermediates"
(cd "$WORK/intermediates" && codesign -d --extract-certificates=cert "$XCODE_APP" >/dev/null 2>&1 || true)
[ -f "$WORK/intermediates/cert1" ] && cp "$WORK/intermediates/cert1" "$WORK/intermediates/wwdr.der" || true
[ -f "$WORK/intermediates/cert2" ] && cp "$WORK/intermediates/cert2" "$WORK/intermediates/root.der" || true

# Build Zsign (feature branch) exactly as the strict signing suite does.
mkdir -p "$WORK/zsign"
git -C "$ROOT/Zsign" archive "$BRANCH" | tar -x -C "$WORK/zsign"
ZAG_ZSIGN_SRC="$WORK/zsign/src" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/branchlib" >/dev/null

# Compile the real signing engine (ZagExternalKeychainSigningKey is picked up by
# the FreeAccount glob) + the proof harness, with ZAG_ZSIGN_STRICT.
swiftc -parse-as-library -D DEBUG -D ZAG_ZSIGN_TESTS -D ZAG_ZSIGN_STRICT -target "$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)" \
	-I "$WORK/branchlib/include" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" \
	"$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" \
	"$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$WORK/zsign/Sources/zsign.swift" \
	"$ROOT/scripts/ZagExternalKeychainSigningProof.swift" \
	-Xlinker "$WORK/branchlib/libzsign.a" -lc++ -framework Security -framework Foundation -o "$WORK/proof" 2>&1 | grep -E 'error' || true
[ -x "$WORK/proof" ] || { echo "FAIL: the proof harness did not build" >&2; exit 1; }

ZAG_PROFILE="$PROFILE" ZAG_APP="$WORK/Disposable.app" ZAG_XCODE_APP="$XCODE_APP" \
	ZAG_INTERMEDIATES="$WORK/intermediates" ZAG_WORK="$WORK" ZAG_DEVICE_UDID="${ZAG_DEVICE_UDID:-}" \
	"$WORK/proof"
