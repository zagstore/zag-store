#!/bin/bash
# Free Apple Account foundation (phase 1): sign-in state, provisioning plans,
# entitlements, refresh policy and ledger, redaction. Pure logic, no network,
# no Keychain, nothing signed or installed. The Keychain store is checked on
# the simulator by test-zag-free-account-keychain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-free-account.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" \
	"$ROOT/scripts/ZagFreeAccountFoundationTests.swift" -o "$WORK/tests"
"$WORK/tests"
python3 -I - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
sources = "\n".join(p.read_text() for p in (root / "Feather/Utilities/FreeAccount").glob("*.swift"))
# Phase 1 talks to nothing: no Apple endpoints, no anisette service, no logging of values.
for forbidden in ["URLSession", "gsa.apple.com", "developerservices", "anisette.", "print(", "Logger"]:
    assert forbidden not in sources, forbidden
print("PASS: phase 1 makes no network requests and logs nothing")
# Free-account UI stays hidden until it works end to end.
assert "static let freeAccountEnabled = false" in sources
views = "\n".join(p.read_text() for p in (root / "Feather/Views").rglob("*.swift"))
assert "freeAppleAccount" not in views and "ZagFreeAccount" not in views
print("PASS: no free-account UI is exposed yet")
# The entitlement matcher was moved, not copied.
assert len(re.findall(r"enum ZagEntitlementCompatibility\b", sources + views + (root / "Feather/Utilities/ZagEntitlementCompatibility.swift").read_text())) == 1
print("PASS: one shared entitlement matcher")
PY
