#!/bin/bash
# Developer Account (App Store Connect API) signing, Milestone 1: the ES256
# token, the typed client over a mock transport, per-account Keychain storage,
# the onboarding model and the feature gate (ASC_API_ARCHITECTURE.md). Pure
# logic and mock HTTP; nothing contacts Apple, nothing is signed or installed.
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
asc = [root / "Feather/Utilities/FreeAccount/ZagASCToken.swift",
       root / "Feather/Utilities/FreeAccount/ZagASCClient.swift",
       root / "Feather/Utilities/FreeAccount/ZagDeveloperAccount.swift",
       root / "Feather/Utilities/FreeAccount/ZagDeveloperAccountOnboardingModel.swift"]
sources = "\n".join(p.read_text() for p in asc)
assert not re.search(r'"https?://[^"]*apple\.com', sources), "an Apple URL string in the ASC code"
for forbidden in ["print(", "NSLog", "os_log", "URLSession", "serverTrust", "allowsArbitraryLoads"]:
    assert forbidden not in sources, forbidden
assert not re.search(r"(?<![A-Za-z])Logger\b", sources), "Logger"
# The gate is closed by default and the production gate follows it.
method = (root / "Feather/Utilities/FreeAccount/ZagSigningMethod.swift").read_text()
assert "static let developerAccountEnabled = false" in method, "the gate must default closed"
assert "ZagDeveloperAccountGate(isOpen: ZagSigningMethodAvailability.developerAccountEnabled)" in sources
# The onboarding view is not referenced anywhere outside its own file, so the
# gate-closed feature has no entry point in release.
views = "\n".join(p.read_text() for p in (root / "Feather/Views").rglob("*.swift")
                  if p.name != "ZagDeveloperAccountOnboardingView.swift")
assert "ZagDeveloperAccountOnboardingView" not in views, "the onboarding screen has a caller"
print("PASS: no logging, no Apple URL; gate closed; no release entry point")
PY
echo "SUCCESS: developer-account (M1) checks passed"
