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
# No Apple endpoint exists in the code, nothing is logged, and only the
# transport may open network connections (with the system's TLS validation).
assert not re.search(r'"https?://[^"]*apple\.com', sources), "Apple service URL in code"
for forbidden in ["print(", "NSLog", "os_log", "serverTrust", "didReceive challenge", "allowsArbitraryLoads"]:
    assert forbidden not in sources, forbidden
# The system Logger (the G5 experiment's typed `ZagExperimentLogger` writes a
# local file only, and only in the experiment build).
assert not re.search(r"(?<![A-Za-z])Logger\b", sources), "Logger"
assert [name for name, text in files.items() if "URLSession" in text] == ["ZagFreeAccountTransport.swift"]
print("PASS: no Apple endpoints, no logging; only the transport touches the network")
# Live sign-in, live anisette and the free-account UI all stay off.
# Each live switch is false unless the G5 experiment build's exact condition
# holds (plan §3.2); DEBUG never satisfies it.
assert "static let freeAccountEnabled = false" in sources
experiment = (re.escape("\t#if ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT && !DEBUG\n\t/// G5 experiment build only (plan §3.2): ")
              + r"[^\n]*\n" + re.escape("\tstatic let isEnabled = true\n\t#else\n"))
for switch in [r"enum ZagLiveAuthentication \{\n" + experiment + r"\t/// Live Apple Account authentication is not implemented or enabled\.\n\tstatic let isEnabled = false\n\t#endif\n\}",
               r"enum ZagLivePortal \{\n" + experiment + r"\t/// The live developer-portal service is not implemented or enabled\.\n\tstatic let isEnabled = false\n\t#endif\n\}",
               experiment + r"\tstatic let isEnabled = false\n\t#endif\n\}\n\n/// Stands in for every configured provider"]:
    assert re.search(switch, sources), switch
assert sources.count("static let isEnabled = true") == sources.count("#if ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT && !DEBUG\n\t/// G5 experiment build only")
print("PASS: live sign-in, live anisette, live portal and free-account UI are disabled")
# Release builds have no free-account UI; the simulated screen is Debug-only
# (checked in detail by test-zag-free-account-sign-in.sh).
debug_screen = root / "Feather/Views/Settings/FreeAccount/ZagFreeAccountDebugSignInView.swift"
views = "\n".join(p.read_text() for p in (root / "Feather/Views").rglob("*.swift") if p != debug_screen)
assert "freeAppleAccount" not in views
assert re.sub(r"#if (DEBUG|ZAG_LIVE_EXPERIMENT|DEBUG \|\| ZAG_LIVE_EXPERIMENT)\n.*?\n#endif", "", views, flags=re.S).count("ZagFreeAccount") == 0
assert debug_screen.read_text().startswith("#if DEBUG")
print("PASS: no free-account UI in release builds")
# The entitlement matcher was moved, not copied.
assert len(re.findall(r"enum ZagEntitlementCompatibility\b", sources + views + (root / "Feather/Utilities/ZagEntitlementCompatibility.swift").read_text())) == 1
print("PASS: one shared entitlement matcher")
PY
