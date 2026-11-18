#!/bin/bash
# Free Apple Account signing end to end, with no Apple service: on-device
# keys and certificate requests (Security framework), a throwaway local test
# authority issuing certificates and signed profiles to the simulated portal,
# Zag Store's profile parser, the app's own Zsign sources (built for macOS)
# signing a real arm64 iOS executable, and the 7-day install and refresh
# lifecycle on a stand-in device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-free-account-signing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SSL="${ZAG_OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null || true)}"
[ -x "$SSL/bin/openssl" ] || { echo "FAIL: Homebrew openssl@3 is required (set ZAG_OPENSSL_PREFIX)" >&2; exit 1; }

# The existing signing and installation paths are not part of this change.
BASE=$(git -C "$ROOT" merge-base HEAD "${ZAG_BASE_REF:-public/main}")
git -C "$ROOT" diff --quiet "$BASE" -- Zsign RPPairingCore Feather/Utilities/Handlers \
	|| { echo "FAIL: Zsign, RPPairing or the signing handlers differ from the base branch" >&2; exit 1; }
echo "PASS: Zsign, RPPairing and the AppTesters signing handlers are unchanged from the base branch"

python3 - "$ROOT" <<'PY2'
import re, sys
from pathlib import Path
root = Path(sys.argv[1]) / "Feather/Utilities/FreeAccount"
key = (root / "ZagSigningKey.swift").read_text()
adapter = (root / "ZagFreeAccountSigningAdapter.swift").read_text()
portal = (root / "ZagDeveloperPortal.swift").read_text()
provisioner = (root / "ZagFreeAccountProvisioner.swift").read_text()
for name, text in [("key", key), ("adapter", adapter), ("provisioner", provisioner)]:
    for forbidden in ["print(", "Logger", "NSLog", "os_log", "debugPrint", "dump("]:
        assert forbidden not in text, (name, forbidden)
assert "kSecAttrIsPermanent: false" in key and "SecItemAdd" not in key
print("PASS: the key factory keeps keys out of the Keychain itself and nothing near key material logs")
assert not re.search(r"func\s+\w*[Rr]evoke", portal + provisioner)
print("PASS: the portal interface has no revoke operation, so nothing can revoke a certificate automatically")
assert "ZagSigningIdentity" in portal and '"[signing identity \\(serialNumber)]"' in portal
print("PASS: a signing identity describes itself without its key")
PY2

bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/zsign" >/dev/null

# Two throwaway local authorities, deleted with $WORK. Zsign builds the CMS
# signature only for certificates issued under Apple's WWDR intermediates,
# chosen by issuer-name hash; the first authority uses that subject name so
# Zsign takes its normal path. It is self-generated and trusted by nothing.
# The second has an ordinary name, to show what Zsign does otherwise.
mkdir -p "$WORK/authority" "$WORK/other-authority"
"$SSL/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 30 \
	-subj "/CN=Apple Worldwide Developer Relations Certification Authority/OU=G3/O=Apple Inc./C=US" \
	-keyout "$WORK/authority/ca.key" -out "$WORK/authority/ca.pem" 2>/dev/null
[ "$("$SSL/bin/openssl" x509 -in "$WORK/authority/ca.pem" -noout -subject_hash)" = 9b16b75c ] \
	|| { echo "FAIL: the test authority's name does not take Zsign's normal signing path" >&2; exit 1; }
"$SSL/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=Zag Store Test Authority (not Apple)" \
	-keyout "$WORK/other-authority/ca.key" -out "$WORK/other-authority/ca.pem" 2>/dev/null
printf 'int main(void) { return 0; }\n' | xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=16.4 -x c - -o "$WORK/Notes"

swiftc -parse-as-library -D DEBUG -D ZAG_ZSIGN_TESTS -target "$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)" \
	-I "$WORK/zsign/include" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" \
	"$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" \
	"$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$ROOT/Zsign/Sources/zsign.swift" \
	"$ROOT/scripts/ZagFreeAccountTestSupport.swift" "$ROOT/scripts/ZagFreeAccountSigningTests.swift" \
	-Xlinker "$WORK/zsign/libzsign.a" -lc++ -framework Security -o "$WORK/tests"

cd "$WORK" # Zsign writes its cache to the current directory
ZAG_TEST_OPENSSL="$SSL/bin/openssl" ZAG_TEST_AUTHORITY="$WORK/authority" ZAG_TEST_OTHER_AUTHORITY="$WORK/other-authority" ZAG_TEST_EXECUTABLE="$WORK/Notes" ZAG_TEST_WORK="$WORK" \
	"$WORK/tests" > "$WORK/output.log" 2>&1 || { grep -v '^>>>' "$WORK/output.log" | tail -30; exit 1; }
grep -E '^(PASS|SUCCESS)' "$WORK/output.log"
