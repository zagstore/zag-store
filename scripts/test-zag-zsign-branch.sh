#!/bin/bash
# Tests the Zsign feature branch (zag-free-account-signing) without moving
# the submodule: exports the branch with git archive, runs its own strict
# signing regression suite, and checks that its cryptographic chain
# selection accepts a real Apple-issued certificate, taken (public data
# only) from the signed canonical IPA when it is present. The production
# submodule pointer is unchanged.
#   ZAG_ZSIGN_BRANCH  default: zag-free-account-signing
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${ZAG_ZSIGN_BRANCH:-zag-free-account-signing}"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-zsign-branch.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SSL="${ZAG_OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null || true)}"

PINNED=$(git -C "$ROOT" ls-tree HEAD Zsign | awk '{print $3}')
echo "Zsign pinned at $PINNED; testing $BRANCH at $(git -C "$ROOT/Zsign" rev-parse --short "$BRANCH")"
mkdir -p "$WORK/zsign"
git -C "$ROOT/Zsign" archive "$BRANCH" | tar -x -C "$WORK/zsign"
OPENSSL_PREFIX="$SSL" bash "$WORK/zsign/test/zag/run-tests.sh"

Z="$WORK/zsign/src"
ZAG_ZSIGN_SRC="$Z" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/branchlib" >/dev/null

# Zag Store's adapter on the branch: per-component signing through a
# Security framework key, compiled with ZAG_ZSIGN_STRICT (never set in the
# Xcode project), against a local authority with an ordinary name.
mkdir -p "$WORK/authority"
"$SSL/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=Zag Store Test Intermediate (not Apple)" \
	-keyout "$WORK/authority/ca.key" -out "$WORK/authority/ca.pem" 2>/dev/null
"$SSL/bin/openssl" x509 -in "$WORK/authority/ca.pem" -outform DER -out "$WORK/authority/ca.der"
printf 'int main(void) { return 0; }\n' | xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.4 -x c - -o "$WORK/Notes"
swiftc -parse-as-library -D DEBUG -D ZAG_ZSIGN_TESTS -D ZAG_ZSIGN_STRICT -target "$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)" \
	-I "$WORK/branchlib/include" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" \
	"$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" \
	"$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$WORK/zsign/Sources/zsign.swift" \
	"$ROOT/scripts/ZagFreeAccountTestSupport.swift" "$ROOT/scripts/ZagStrictSigningIntegrationTests.swift" \
	-Xlinker "$WORK/branchlib/libzsign.a" -lc++ -framework Security -o "$WORK/integration" 2>&1 | grep -E 'error' || true
[ -x "$WORK/integration" ] || { echo "FAIL: the integration tests did not build" >&2; exit 1; }
(cd "$WORK" && ZAG_TEST_OPENSSL="$SSL/bin/openssl" ZAG_TEST_AUTHORITY="$WORK/authority" ZAG_TEST_EXECUTABLE="$WORK/Notes" ZAG_TEST_WORK="$WORK" \
	"$WORK/integration" > "$WORK/integration.log" 2>&1) || { grep -aoE '(PASS|FAIL|SUCCESS)[^>]*' "$WORK/integration.log" | tail -20; exit 1; }
grep -aoE '(PASS|SUCCESS): .*' "$WORK/integration.log"

IPA="${ZAG_REAL_CERT_IPA:-$HOME/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa}"
if [ -f "$IPA" ]; then
	mkdir -p "$WORK/ipa" && (cd "$WORK/ipa" && unzip -q "$IPA" 'Payload/*')
	APP=$(ls -d "$WORK"/ipa/Payload/*.app | head -1)
	(cd "$WORK/ipa" && codesign -d --extract-certificates "$APP" >/dev/null 2>&1)
	clang++ -target "$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)" -std=c++17 -w -I"$Z" -I"$Z/common" -I"$SSL/include" \
		"$WORK/zsign/test/zag/chain-check.cpp" "$WORK/branchlib/libzsign.a" -framework Foundation -framework Security -o "$WORK/chain-check"
	RESULT=$("$WORK/chain-check" "$WORK/ipa/codesign0")
	[ "$RESULT" = APPLE-WWDR ] || { echo "FAIL: a real Apple-issued certificate was not accepted: $RESULT" >&2; exit 1; }
	echo "PASS: the canonical IPA's real signing certificate is accepted, verified against Apple's WWDR intermediate"
else
	echo "SKIP: no signed IPA to take a real Apple-issued certificate from"
fi
echo "SUCCESS: Zsign branch $BRANCH"
