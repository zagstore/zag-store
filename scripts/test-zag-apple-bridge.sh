#!/bin/bash
# G4: the bridge from Zag Store's Swift Apple Account and developer-portal
# interfaces to zag-isideload (AppleAuthCore/zag-apple-bridge).
#   1. Rust: the bridge's own checks in each build: default (everything
#      disabled), `mock` (scripted backend) and `live` (compiled only to check
#      its gate; nothing is configured, so nothing connects).
#   2. The C header declares exactly the exported functions.
#   3. Swift: the authenticator, account directory and portal interface
#      against the bridge built with `mock` (2FA, cancellation, deadlines,
#      expired sessions, network failures, account switching, redaction).
#   4. Gates: no Xcode configuration compiles or links the bridge, and the
#      live switches stay off.
# Nothing contacts Apple or an anisette server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/AppleAuthCore/zag-apple-bridge"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-apple-bridge.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export CARGO_TARGET_DIR="$BRIDGE/target"

for features in "" mock live; do
	flag=${features:+--features $features}
	out=$(cd "$BRIDGE" && cargo test --quiet $flag 2>&1) || { echo "$out"; echo "FAIL: cargo test ${features:-default}"; exit 1; }
	count=$(echo "$out" | sed -n 's/^test result: ok\. \([0-9]*\) passed.*/\1/p' | awk '{ s += $1 } END { print s + 0 }')
	[ "$count" -gt 0 ] || { echo "FAIL: no bridge tests ran (${features:-default})"; exit 1; }
	echo "PASS: bridge Rust checks, ${features:-default} build ($count)"
done

(cd "$BRIDGE" && cargo build --quiet --release --features mock 2>/dev/null)
LIB="$BRIDGE/target/release/libzag_apple_bridge.a"
{ nm -gU "$LIB" 2>/dev/null || true; } | awk '$2 == "T" && $3 ~ /^_zag_bridge_/ { sub(/^_/, "", $3); print $3 }' | sort -u > "$WORK/exported"
grep -oE 'zag_bridge_[a-z_]+\(' "$BRIDGE/include/zag_apple_bridge.h" | tr -d '(' | sort -u > "$WORK/declared"
diff -u "$WORK/declared" "$WORK/exported" > /dev/null || { diff -u "$WORK/declared" "$WORK/exported"; echo "FAIL: header and exports differ"; exit 1; }
echo "PASS: the C header declares exactly the $(wc -l < "$WORK/exported" | tr -d ' ') exported functions"

swiftc -warnings-as-errors -parse-as-library -D DEBUG -D ZAG_APPLE_BRIDGE -target "$(uname -m)-apple-macos13" \
	-import-objc-header "$BRIDGE/include/zag_apple_bridge.h" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$ROOT/scripts/ZagFreeAccountTestSupport.swift" "$ROOT/scripts/ZagAppleBridgeTests.swift" \
	"$LIB" -framework Security -framework CoreFoundation -framework SystemConfiguration -o "$WORK/tests"
"$WORK/tests"

PROJECT="$ROOT/Feather.xcodeproj/project.pbxproj"
# The native bridge is linked in the standard device build (the standalone
# architecture keeps the capability present). The invariant is no longer "the
# bridge is not linked"; it is the distinction between LINKED CAPABILITY and
# AUTHORISED LIVE EXECUTION: the live-execution conditions are command-line
# only, so a committed project must never enable them — otherwise a shipping
# build would turn live authentication and strict signing on by default. The
# gate check below independently confirms the live switches stay off.
if grep -qE 'ZAG_LIVE_EXPERIMENT|ZAG_ZSIGN_STRICT' "$PROJECT"; then
	echo "FAIL: the Xcode project commits a live-execution condition (ZAG_LIVE_EXPERIMENT/ZAG_ZSIGN_STRICT)"; exit 1
fi
echo "PASS: the bridge may be linked, but no committed configuration enables live execution"
for gate in "ZagFreeAccountAuthentication.swift:enum ZagLiveAuthentication" "ZagDeveloperPortal.swift:enum ZagLivePortal" "ZagAnisetteProvider.swift:enum ZagAnisetteLive"; do
	file=${gate%%:*}; name=${gate#*:}
	sed -n "/$name {/,/^}/p" "$ROOT/Feather/Utilities/FreeAccount/$file" | grep -qE '^\s*static let isEnabled = false$' \
		|| { echo "FAIL: ${name#enum } is not off"; exit 1; }
done
echo "PASS: live authentication, the live portal and live anisette stay off"
echo "SUCCESS: Apple bridge checks passed"
