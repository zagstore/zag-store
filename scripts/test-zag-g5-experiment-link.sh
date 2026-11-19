#!/bin/bash
# G5: the experiment configuration builds and LINKS for iOS, offline, with
# live operations impossible (checklist S1/S4; remediation item 4):
#  1. the iOS bridge library with default features (no `live`: the bridge
#     cannot reach the network) and the placeholder constants (never arm);
#  2. Release, the three experiment conditions, never DEBUG: must link, and
#     the executable must pass the experiment scan (placeholder mode);
#  3. the same without the library: must FAIL to link on zag_bridge_*
#     (no stub hides a missing bridge).
# Builds go to a temporary folder, deleted afterwards. No IPA is made.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/AppleAuthCore/zag-apple-bridge"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-g5-link.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
grep -q 'static let campaignID = "G5-C0"' "$ROOT/Feather/Utilities/FreeAccount/ZagLiveExperimentCampaignConstants.swift" \
	|| { echo "FAIL: the link check runs only with the placeholder constants" >&2; exit 1; }

(cd "$BRIDGE" && cargo build --quiet --release --target aarch64-apple-ios 2>/dev/null)
LIB="$BRIDGE/target/aarch64-apple-ios/release/libzag_apple_bridge.a"
SETTINGS=()
while IFS= read -r line; do SETTINGS+=("$line"); done < <(bash "$ROOT/scripts/zag-g5-build-check.sh" link-settings "$LIB")
CONDITIONS="${SETTINGS[0]}"

build() { # log [settings...]
	local log="$1"; shift
	xcodebuild -project "$ROOT/Feather.xcodeproj" -scheme Feather -configuration Release -destination "generic/platform=iOS" \
		-derivedDataPath "$WORK/dd" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO \
		DSTROOT="$WORK/root" "$@" > "$log" 2>&1
}

build "$WORK/linked.log" "${SETTINGS[@]}" || { grep -E 'error:|Undefined' "$WORK/linked.log" | sort -u | head -20; echo "FAIL: the experiment configuration does not link" >&2; exit 1; }
APP="$WORK/root/Applications/Feather.app"
echo "PASS: the experiment configuration (Release, $CONDITIONS) builds and links with the iOS bridge library"
bash "$ROOT/scripts/test-zag-g5-experiment-binary.sh" "$APP" G5-C0 -
rm -rf "$WORK/root"

if build "$WORK/unlinked.log" "$CONDITIONS" "INFOPLIST_KEY_CFBundleDisplayName=Zag LIVE TEST"; then
	echo "FAIL: the experiment configuration linked without the bridge library" >&2; exit 1
fi
grep -q 'Undefined symbols' "$WORK/unlinked.log" && grep -qE '"_zag_bridge_[a-z_]+"' "$WORK/unlinked.log" \
	|| { grep -E 'error:' "$WORK/unlinked.log" | sort -u | head; echo "FAIL: the build without the library failed for another reason" >&2; exit 1; }
others=$(grep -oE '"_[A-Za-z0-9_]+", referenced' "$WORK/unlinked.log" | grep -v '"_zag_bridge_' | sort -u || true)
[ -z "$others" ] || { echo "FAIL: other undefined symbols: $others" >&2; exit 1; }
[ ! -e "$WORK/root/Applications/Feather.app/Feather" ] || { echo "FAIL: an executable was produced without the library" >&2; exit 1; }
echo "PASS: without the bridge library the build fails to link, on zag_bridge_* only, and produces no executable"
echo "SUCCESS: the G5 experiment configuration links offline (placeholder constants, no live network); products deleted"
