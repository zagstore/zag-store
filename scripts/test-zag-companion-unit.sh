#!/bin/bash
# Device-independent focused tests for the Zag Companion core (registry,
# renewal timing, IPA inspection, pairing session crypto, signer fail-closed).
# Builds the engine + core + the unit harness and runs it. No iPhone required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${ZAG_ZSIGN_BRANCH:-zag-free-account-signing}"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-companion-unit.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/zsign"
git -C "$ROOT/Zsign" archive "$BRANCH" | tar -x -C "$WORK/zsign"
ZAG_ZSIGN_SRC="$WORK/zsign/src" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/branchlib" >/dev/null

swiftc -parse-as-library -D DEBUG -D ZAG_ZSIGN_TESTS -D ZAG_ZSIGN_STRICT -target "$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)" \
	-I "$WORK/branchlib/include" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" \
	"$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" \
	"$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$WORK/zsign/Sources/zsign.swift" \
	"$ROOT"/ZagCompanion/Core/*.swift \
	"$ROOT/ZagCompanion/Tests/ZagCompanionCoreTests.swift" \
	-Xlinker "$WORK/branchlib/libzsign.a" -lc++ -framework Security -framework Foundation -framework CryptoKit -o "$WORK/companion-unit" 2>&1 | grep -E 'error:' || true
[ -x "$WORK/companion-unit" ] || { echo "FAIL: the companion unit-test build did not compile" >&2; exit 1; }
"$WORK/companion-unit"
