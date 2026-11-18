#!/bin/bash
# Free Apple Account foundation (phase 1): sign-in state, provisioning plans,
# entitlements, refresh policy and ledger, redaction. Pure logic, no network,
# no Keychain, nothing signed or installed. The Keychain store is checked on
# the simulator by test-zag-free-account-keychain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-free-account.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos13" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" \
	"$ROOT/scripts/ZagFreeAccountFoundationTests.swift" -o "$WORK/tests"
"$WORK/tests"
python3 -I - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
sources = "\n".join(p.read_text() for p in (root / "Feather/Utilities/FreeAccount").glob("*.swift"))
files = {p.name: p.read_text() for p in (root / "Feather/Utilities/FreeAccount").glob("*.swift")}
# No Apple endpoint exists in the code, nothing is logged, and only the
# transport may open network connections (with the system's TLS validation).
assert not re.search(r'"https?://[^"]*apple\.com', sources), "Apple service URL in code"
for forbidden in ["print(", "Logger", "NSLog", "os_log", "serverTrust", "didReceive challenge", "allowsArbitraryLoads"]:
    assert forbidden not in sources, forbidden
assert [name for name, text in files.items() if "URLSession" in text] == ["ZagFreeAccountTransport.swift"]
print("PASS: no Apple endpoints, no logging; only the transport touches the network")
# Live sign-in, live anisette and the free-account UI all stay off.
for flag in ["static let freeAccountEnabled = false", "enum ZagLiveAuthentication {\n\t/// Live Apple Account authentication is not implemented or enabled.\n\tstatic let isEnabled = false",
             "static let isEnabled = false\n}\n\n/// Stands in for every configured provider"]:
    assert flag in sources, flag
assert "enum ZagLivePortal {\n\t/// The live developer-portal service is not implemented or enabled.\n\tstatic let isEnabled = false" in sources
print("PASS: live sign-in, live anisette, live portal and free-account UI are disabled")
# Release builds have no free-account UI; the simulated screen is Debug-only
# (checked in detail by test-zag-free-account-sign-in.sh).
debug_screen = root / "Feather/Views/Settings/FreeAccount/ZagFreeAccountDebugSignInView.swift"
views = "\n".join(p.read_text() for p in (root / "Feather/Views").rglob("*.swift") if p != debug_screen)
assert "freeAppleAccount" not in views
assert re.sub(r"#if DEBUG.*?#endif", "", views, flags=re.S).count("ZagFreeAccount") == 0
assert debug_screen.read_text().startswith("#if DEBUG")
print("PASS: no free-account UI in release builds")
# The entitlement matcher was moved, not copied.
assert len(re.findall(r"enum ZagEntitlementCompatibility\b", sources + views + (root / "Feather/Utilities/ZagEntitlementCompatibility.swift").read_text())) == 1
print("PASS: one shared entitlement matcher")
PY
