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
ZAG_ASC_REQUEST_DUMP="$WORK/exchanges.jsonl" "$WORK/tests"

# 1b. Optional: every request and mock response checked against Apple's
# published OpenAPI document (set ZAG_ASC_OPENAPI to its openapi.oas.json;
# it is not vendored here). Nothing is sent to Apple.
if [ -n "${ZAG_ASC_OPENAPI:-}" ]; then
	python3 -I "$ROOT/scripts/zag-asc-openapi-check.py" "$ZAG_ASC_OPENAPI" "$WORK/exchanges.jsonl"
else
	echo "SKIP: ZAG_ASC_OPENAPI is not set; the requests were not checked against Apple's OpenAPI document"
fi

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
       root / "Feather/Utilities/FreeAccount/ZagDeveloperAccountOnboardingModel.swift",
       root / "Feather/Utilities/FreeAccount/ZagDeveloperAccountService.swift",
       root / "Feather/Utilities/FreeAccount/ZagDeveloperAccountInstallModel.swift",
       root / "Feather/Utilities/ZagDeveloperAccountLive.swift",
       root / "Feather/Views/Settings/DeveloperAccount/ZagDeveloperAccountOnboardingView.swift",
       root / "Feather/Views/Settings/DeveloperAccount/ZagSigningMethodsSection.swift"]
assert len(asc) == 12, [p.name for p in asc]
sources = "\n".join(p.read_text() for p in asc)
assert not re.search(r'"https?://[^"]*apple\.com', sources), "an Apple URL string in the ASC code"
for forbidden in ["print(", "NSLog", "os_log", "debugPrint", "dump(", "serverTrust", "allowsArbitraryLoads"]:
    assert forbidden not in sources, forbidden
# No session of its own: only the transport file's ZagURLSessionTransport.
assert not re.search(r"(?<![A-Za-z])URLSession\b", sources), "URLSession"
assert not re.search(r"(?<![A-Za-z])Logger\b", sources), "Logger"
# The gate is closed by default and the production gate follows it.
method = (root / "Feather/Utilities/FreeAccount/ZagSigningMethod.swift").read_text()
assert "static let developerAccountEnabled = false" in method, "the gate must default closed"
# Opened only by the live-test condition, which cannot build without strict
# Keychain-key signing; nothing else in the app or project sets it.
assert re.search(r"#if ZAG_DEVELOPER_ACCOUNT_LIVE_TEST\s*\n\s*#if !ZAG_ZSIGN_STRICT\s*\n\s*#error\(", method)
# No build input sets it: project, xcconfigs, schemes, Makefile, packager, CI.
inputs = [root / "Feather.xcodeproj/project.pbxproj", root / "Makefile", root / "ZagStore-Package.zsh"]
inputs += list(root.rglob("*.xcconfig")) + list(root.rglob("*.xcscheme")) + list((root / ".github").rglob("*"))
for path in inputs:
    if path.is_file() and ".git/" not in str(path):
        assert "ZAG_DEVELOPER_ACCOUNT_LIVE_TEST" not in path.read_text(errors="ignore"), f"{path.name} sets the live-test condition"
assert [p.name for p in (root / "Feather").rglob("*.swift") if "ZAG_DEVELOPER_ACCOUNT_LIVE_TEST" in p.read_text()] == ["ZagSigningMethod.swift"]
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
# One entry point: the Signing screen's Signing Methods section, inside the
# closed gate. The onboarding view's only caller is that section's file.
def callers(symbol, skip):
    return sorted(str(p.relative_to(root)) for p in (root / "Feather").rglob("*.swift")
                  if p.name not in skip and re.search(r"\b" + symbol + r"\b\s*\(", p.read_text()))
assert callers("ZagDeveloperAccountOnboardingView", {"ZagDeveloperAccountOnboardingView.swift"}) == \
    ["Feather/Views/Settings/DeveloperAccount/ZagSigningMethodsSection.swift"], "the onboarding screen has another caller"
assert callers("ZagSigningMethodsSection", {"ZagSigningMethodsSection.swift"}) == ["Feather/Views/Settings/SettingsView.swift"]
settings = (root / "Feather/Views/Settings/SettingsView.swift").read_text()
use = settings.index("ZagSigningMethodsSection()")
gate = settings.rindex("if ZagSigningMethodAvailability.developerAccountEnabled {", 0, use)
assert settings.find("}", gate) > use, "the Signing Methods section is outside the gate"
# The live wiring: the ASC-only transport, made only in the transport file;
# the adapter and installer behind the developer-account gate, never the
# free-account one.
live = (root / "Feather/Utilities/ZagDeveloperAccountLive.swift").read_text()
assert "ZagURLSessionTransport.appStoreConnect()" in live and "ZagURLSessionTransport(" not in live
assert "ZagRPPairingFreeAccountInstaller(gate: .developerAccount)" in live
assert "gate: .developerAccount, keychainKeys: keys" in live
assert ".production" not in live and "simulationOnly" not in live and "print(" not in live
transport = (root / "Feather/Utilities/FreeAccount/ZagFreeAccountTransport.swift").read_text()
assert "ZagTransportPolicy(allowedHosts: [ZagASCClient.host])" in transport
print("PASS: no logging, no Apple URL; gate closed; one gated entry point; live wiring behind the developer-account gates")
PY
echo "SUCCESS: developer-account (M1-M3) checks passed"
