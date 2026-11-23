#!/bin/bash
# Builds the Zag Companion core service (reusing Zag Store's signing engine +
# Zsign) and runs the real end-to-end acceptance test on the connected iPhone:
# install a source IPA through the service, launch it, and renew it with the
# valid profile (no new certificate, no new Apple-side provisioning).
#
# Env: ZAG_XCODE_APP (an Xcode-built PTTeamProbe.app to package as the source
#      IPA), ZAG_ZSIGN_BRANCH (default zag-free-account-signing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${ZAG_ZSIGN_BRANCH:-zag-free-account-signing}"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-companion.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

XCODE_APP="${ZAG_XCODE_APP:-}"
if [ -z "$XCODE_APP" ]; then
	XCODE_APP=$(find "${TMPDIR:-/tmp}" "$HOME/Library/Developer/Xcode/DerivedData" -type d -name PTTeamProbe.app -path '*Debug-iphoneos*' 2>/dev/null | head -1)
fi
[ -d "$XCODE_APP" ] || { echo "FAIL: no PTTeamProbe.app found; set ZAG_XCODE_APP" >&2; exit 1; }

# Package the source IPA the companion will re-sign.
mkdir -p "$WORK/src/Payload"
cp -R "$XCODE_APP" "$WORK/src/Payload/PTTeamProbe.app"
SRC_IPA="$WORK/PTTeamProbe-source.ipa"
(cd "$WORK/src" && zip -qry "$SRC_IPA" Payload)
echo "source IPA: $SRC_IPA"

# Build Zsign (feature branch) as the strict suite does.
mkdir -p "$WORK/zsign"
git -C "$ROOT/Zsign" archive "$BRANCH" | tar -x -C "$WORK/zsign"
ZAG_ZSIGN_SRC="$WORK/zsign/src" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/branchlib" >/dev/null

# Compile the engine + companion core + acceptance driver.
swiftc -parse-as-library -D DEBUG -D ZAG_ZSIGN_TESTS -D ZAG_ZSIGN_STRICT -target "$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)" \
	-I "$WORK/branchlib/include" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" \
	"$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" \
	"$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$WORK/zsign/Sources/zsign.swift" \
	"$ROOT"/ZagCompanion/Core/*.swift \
	"$ROOT/ZagCompanion/Tests/ZagCompanionAcceptance.swift" \
	-Xlinker "$WORK/branchlib/libzsign.a" -lc++ -framework Security -framework Foundation -o "$WORK/companion-accept" 2>&1 | grep -E 'error:' || true
[ -x "$WORK/companion-accept" ] || { echo "FAIL: the companion acceptance build did not compile" >&2; exit 1; }

ZAG_REPO="$ROOT" ZAG_SOURCE_IPA="$SRC_IPA" ZAG_SUPPORT="$WORK/support" "$WORK/companion-accept"
