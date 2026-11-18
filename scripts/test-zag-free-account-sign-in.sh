#!/bin/bash
# Debug-only Apple Account sign-in screen: state transitions of the screen's
# model against the simulated service (synthetic credentials, no network),
# plus checks that the screen, the simulation and their entry points exist
# only in Debug builds. The screen itself is exercised on the simulator by
# test-zag-free-account-sign-in-ui.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-free-account-sign-in.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SOURCES=("$ROOT"/Feather/Utilities/FreeAccount/*.swift "$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift")
swiftc -warnings-as-errors -parse-as-library -D DEBUG -target "$(uname -m)-apple-macos13" \
	"${SOURCES[@]}" "$ROOT/scripts/ZagFreeAccountSignInModelTests.swift" -o "$WORK/tests"
"$WORK/tests"

# Without DEBUG the simulation is not compiled at all.
swiftc -parse-as-library -emit-library -target "$(uname -m)-apple-macos13" -module-name ZagRelease \
	"${SOURCES[@]}" -o "$WORK/librelease.dylib" 2>/dev/null
nm "$WORK/librelease.dylib" > "$WORK/symbols.txt"
grep -q ZagFreeAccountAuthenticator "$WORK/symbols.txt" || { echo "FAIL: release library is empty"; exit 1; }
if grep -q -E 'ZagSimulatedAuthentication|ZagFreeAccountSimulation|ZagSimulationClock' "$WORK/symbols.txt"; then
	echo "FAIL: simulation compiled without DEBUG"; exit 1
fi
echo "PASS: the simulation is absent from non-Debug builds"

python3 -I - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
def debug_only(path):
    text = (root / path).read_text().strip()
    return text.startswith("#if DEBUG") and text.endswith("#endif") and text.count("#if DEBUG") == 1
for path in ["Feather/Utilities/FreeAccount/ZagFreeAccountSimulation.swift",
             "Feather/Views/Settings/FreeAccount/ZagFreeAccountDebugSignInView.swift"]:
    assert debug_only(path), path
print("PASS: the debug screen and the simulation are wrapped in #if DEBUG")
# Every other mention of the screen is inside an #if DEBUG block.
for path in (root / "Feather").rglob("*.swift"):
    if path.name in {"ZagFreeAccountDebugSignInView.swift", "ZagFreeAccountSimulation.swift"}:
        continue
    text = path.read_text()
    for match in re.finditer(r"ZagFreeAccountDebug|ZagFreeAccountSimulation|ZagSimulatedAuthentication", text):
        before = text[:match.start()]
        assert before.rfind("#if DEBUG") > before.rfind("#endif"), f"{path.name}: {match.group()} outside #if DEBUG"
print("PASS: entry points (Settings link, launch hook) exist only in Debug builds")
# The screen's only entry point is the Settings link in the Advanced
# settings section; nothing else (routes, deep links, launch hooks) opens it.
uses = [(path.name, m.start()) for path in (root / "Feather").rglob("*.swift")
        if path.name != "ZagFreeAccountDebugSignInView.swift"
        for m in re.finditer(r"ZagFreeAccountDebug(SignInView|LaunchHook|Demo|Lab)", path.read_text())]
assert [name for name, _ in uses] == ["SettingsView.swift"], uses
settings = (root / "Feather/Views/Settings/SettingsView.swift").read_text()
section = settings[settings.index("private var _advancedSettingsSections"):settings.index("// Search covers")]
assert "ZagFreeAccountDebugSignInView()" in section
print("PASS: the only entry point is Settings > Advanced > Experimental Features")
# The simulation and the debug screen have no path to the network: no
# transport, no URLs, no anisette broker, no live service.
for path in ["Feather/Utilities/FreeAccount/ZagFreeAccountSimulation.swift",
             "Feather/Views/Settings/FreeAccount/ZagFreeAccountDebugSignInView.swift"]:
    text = (root / path).read_text()
    for forbidden in ["URLSession", "ZagHTTPTransport", "ZagURLSessionTransport", "URL(string", "URLRequest",
                      "ZagAnisetteBroker", "ZagDisabledAuthenticationService", "http://", "https://", "NWConnection"]:
        assert forbidden not in text, (path, forbidden)
simulation = (root / "Feather/Utilities/FreeAccount/ZagFreeAccountSimulation.swift").read_text()
assert "anisette: ZagSimulatedAnisetteSource(" in simulation and "service: service," in simulation
screen = (root / "Feather/Views/Settings/FreeAccount/ZagFreeAccountDebugSignInView.swift").read_text()
assert "ZagFreeAccountAuthenticator(" not in screen and "ZagFreeAccountSimulation.makeAuthenticator(" in screen
print("PASS: the simulation and the screen cannot reach the network or a live service")
model = (root / "Feather/Utilities/FreeAccount/ZagFreeAccountSignInModel.swift").read_text()
for forbidden in ["UserDefaults", "AppStorage", "SecItem", "write(", "Keychain"]:
    assert forbidden not in model, forbidden
print("PASS: the sign-in model writes nothing itself; passwords and codes stay in memory")
PY
