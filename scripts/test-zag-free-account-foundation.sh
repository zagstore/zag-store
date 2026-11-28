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
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$ROOT/scripts/ZagFreeAccountFoundationTests.swift" -o "$WORK/tests"
"$WORK/tests"
python3 -I - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
sources = "\n".join(p.read_text() for p in (root / "Feather/Utilities/FreeAccount").glob("*.swift"))
files = {p.name: p.read_text() for p in (root / "Feather/Utilities/FreeAccount").glob("*.swift")}
# Only the pinned developer-services codec declares an Apple service URL.
apple_urls = {
    name: set(re.findall(r'"(https?://[^"]*apple\.com[^"]*)"', text))
    for name, text in files.items()
    if re.search(r'"https?://[^"]*apple\.com', text)
}
assert apple_urls == {"ZagDeveloperServicesProtocol.swift": {"https://developerservices2.apple.com/services/v1/"}}, apple_urls
assert not re.search(r"(?<![A-Za-z0-9_])print\(", sources), "print"
for forbidden in ["NSLog", "os_log", "serverTrust", "didReceive challenge", "allowsArbitraryLoads"]:
    assert forbidden not in sources, forbidden
assert not re.search(r"(?<![A-Za-z])Logger\b", sources), "Logger"
assert {name for name, text in files.items() if re.search(r"\bURLSession\s*\(", text)} == {
    "ZagAppleAuthMachine.swift", "ZagFreeAccountTransport.swift"
}
print("PASS: native authentication and developer services use bounded transport without logging credentials")
availability = files["ZagSigningMethod.swift"]
assert re.search(r"#if canImport\(ZagAppleAuth\) && ZAG_ZSIGN_STRICT\s+static let freeAccountEnabled = true", availability)
native = (root / "Feather/Utilities/ZagNativeAccountInstall.swift").read_text()
assert native.startswith("#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT")
assert "ZagNativeSigningPipeline.run" in native and "ZagKeychainSigningKeyFactory" in native
assert "ZagLiveExperiment" not in native and "ZagIsideload" not in native
debug_screen = root / "Feather/Views/Settings/FreeAccount/ZagFreeAccountDebugSignInView.swift"
views = "\n".join(p.read_text() for p in (root / "Feather/Views").rglob("*.swift") if p != debug_screen)
assert debug_screen.read_text().startswith("#if DEBUG")
print("PASS: production signing uses the native session and Keychain key without experiment dependencies")
# The entitlement matcher was moved, not copied.
assert len(re.findall(r"enum ZagEntitlementCompatibility\b", sources + views + (root / "Feather/Utilities/ZagEntitlementCompatibility.swift").read_text())) == 1
print("PASS: one shared entitlement matcher")
PY
