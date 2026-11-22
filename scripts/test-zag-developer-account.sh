#!/bin/bash
# Developer Account (App Store Connect API) signing, Milestones 1-3
# (ASC_API_ARCHITECTURE.md): the ES256 token, the typed client, per-account
# Keychain storage, onboarding and the gates (M1); the ASC portal and
# provisioner end to end against a stateful mock of the ASC API (M2); the
# signing + install coordinator, cancellation and recovery (M3). Pure logic
# and mock HTTP; nothing contacts Apple, nothing real is signed or installed.
# The real Keychain store is checked on the simulator by
# test-zag-free-account-keychain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-developer-account.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
EXTRA=("$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift")

# 1. Offline logic + mock-transport tests.
swiftc -warnings-as-errors -parse-as-library -D DEBUG -target "$(uname -m)-apple-macos13" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"${EXTRA[@]}" \
	"$ROOT/scripts/ZagDeveloperAccountTests.swift" -o "$WORK/tests"
"$WORK/tests"

# 2. The SwiftUI onboarding screen type-checks against the model, on the iOS
# SDK the app ships on (and this also compiles the sources without -D DEBUG).
xcrun -sdk iphonesimulator swiftc -typecheck -parse-as-library -target "$(uname -m)-apple-ios16.4-simulator" \
	-module-cache-path "$WORK/module-cache" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"${EXTRA[@]}" \
	"$ROOT/Feather/Views/Settings/DeveloperAccount/ZagDeveloperAccountOnboardingView.swift"
echo "PASS: the SwiftUI onboarding screen type-checks"

# 3. Guards: the new code never logs, never embeds an Apple URL, and keeps the
# gate closed and the feature out of release UI.
python3 -I - "$ROOT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
asc = sorted((root / "Feather/Utilities/FreeAccount").glob("ZagASC*.swift")) + [
       root / "Feather/Utilities/FreeAccount/ZagDeveloperAccount.swift",
       root / "Feather/Utilities/FreeAccount/ZagDeveloperAccountOnboardingModel.swift"]
assert len(asc) == 7, [p.name for p in asc]
sources = "\n".join(p.read_text() for p in asc)
assert not re.search(r'"https?://[^"]*apple\.com', sources), "an Apple URL string in the ASC code"
for forbidden in ["print(", "NSLog", "os_log", "URLSession", "serverTrust", "allowsArbitraryLoads"]:
    assert forbidden not in sources, forbidden
assert not re.search(r"(?<![A-Za-z])Logger\b", sources), "Logger"
# The gate is closed by default and the production gate follows it.
method = (root / "Feather/Utilities/FreeAccount/ZagSigningMethod.swift").read_text()
assert "static let developerAccountEnabled = false" in method, "the gate must default closed"
assert "ZagDeveloperAccountGate(isOpen: ZagSigningMethodAvailability.developerAccountEnabled)" in sources
adapter = (root / "Feather/Utilities/FreeAccount/ZagFreeAccountSigningAdapter.swift").read_text()
assert "static let developerAccount = ZagFreeAccountSigningGate(isOpen: ZagSigningMethodAvailability.developerAccountEnabled)" in adapter
assert re.search(r"^\s*static let isEnabled = false$", adapter, re.M), "free-account signing must stay closed"
# The open gates exist only in Debug, and production ASC code never names a
# simulation, an open gate or the free-account gate.
account = (root / "Feather/Utilities/FreeAccount/ZagDeveloperAccount.swift").read_text()
assert re.search(r"#if DEBUG\s*\n\s*static let testingOpen", account), "testingOpen must be Debug-only"
for marker in ["Simulated", "simulationOnly", "testingOpen", "ZagFreeAccountSigning.isEnabled"]:
    assert marker not in sources.replace("#if DEBUG\n\tstatic let testingOpen", ""), marker
# The onboarding view is not referenced anywhere outside its own file, so the
# gate-closed feature has no entry point in release.
views = "\n".join(p.read_text() for p in (root / "Feather/Views").rglob("*.swift")
                  if p.name != "ZagDeveloperAccountOnboardingView.swift")
assert "ZagDeveloperAccountOnboardingView" not in views, "the onboarding screen has a caller"
print("PASS: no logging, no Apple URL; gate closed; no release entry point")
PY
echo "SUCCESS: developer-account (M1-M3) checks passed"
