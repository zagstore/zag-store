#!/bin/bash
# G5 existing-account path (issue #37), offline: static checks, then
# scripts/ZagExistingAccountTests.swift (D1–D12, K1–K13, J1–J10, X1–X16)
# compiled with ZAG_EXISTING_ACCOUNT_EXPERIMENT over the bridge's mock
# backend, the strict Zsign branch and a local test authority, then three
# mutants that must fail: the approval journal bypassed, the preflight made
# able to register a device, and Keychain errors read as absent keys. Nothing contacts Apple or an anisette provider. The empty-account
# G5 campaign is tested, unchanged, by test-zag-g5-experiment.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/AppleAuthCore/zag-apple-bridge"
FA="$ROOT/Feather/Utilities/FreeAccount"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-existing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SSL="${ZAG_OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null || true)}"

python3 -I - "$ROOT" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
fa = root / "Feather/Utilities/FreeAccount"
def code(text):
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
new = {name: (fa / name).read_text() for name in ["ZagExistingAccountPreflight.swift", "ZagExistingAccountApprovals.swift"]}
for name, text in new.items():
    assert text.startswith("#if ZAG_EXISTING_ACCOUNT_EXPERIMENT\n") and text.rstrip().endswith("#endif"), name
    assert not re.search(r"revoke|delete|remove", code(text), re.I), f"{name}: no revocation or deletion"
print("PASS: the existing-account files compile only with ZAG_EXISTING_ACCOUNT_EXPERIMENT; no revocation or deletion in them")

pre = new["ZagExistingAccountPreflight.swift"]
reader = pre[pre.index("protocol ZagPortalReader"):pre.index("/// A portal seen through")]
assert re.findall(r"func (\w+)\(", reader) == ["devices", "appIDs", "certificates"], reader
wrapper = pre[pre.index("struct ZagReadOnlyPortal"):pre.index("enum ZagExistingAccountPreflight {")]
assert re.findall(r"func (\w+)\(", wrapper) == ["devices", "appIDs", "certificates"]
assert re.findall(r"portal\.(\w+)\(", wrapper) == ["devices", "appIDs", "certificates"], wrapper
read = pre[pre.index("static func read("):pre.index("static func localKeys(")]
assert set(re.findall(r"reader\.(\w+)\(", read)) == {"devices", "appIDs", "certificates"} and "portal" not in read
run = pre[pre.index("static func run("):]
assert "reader: ZagPortalReader" in run and "ZagDeveloperPortalService" not in run
print("PASS: the preflight sees only the three listings (ZagPortalReader); profiles are never listed")

bridge = (fa / "ZagIsideloadBridge.swift").read_text()
for op in ["registerDevice", "registerAppId", "registerAppGroup", "assignAppGroups", "profile"]:
    line = next(l for l in bridge.splitlines() if f'"op": "{op}"' in l)
    assert "try await change(." in line or "change(." in bridge[bridge.rfind("try await gate(.portalMutate", 0, bridge.index(line)):bridge.index(line)], op
submit = bridge[bridge.index("func submitCertificateRequest("):bridge.index("private func sendCertificateRequest(")]
order = [submit.index(n) for n in ["approvals.check(.certificate", "ZagCertificateBudget.consume(", "approvals.consume(.certificate", "sendCertificateRequest(request"]]
assert order == sorted(order), order
print("PASS: every bridge mutation passes the approval journal; the certificate: approval check, budget, journal, then send")
assert bridge.count("guard approvals.campaignID == campaign.constants.campaignID") == 2
assert "guard approvals.campaignID == campaign.constants.campaignID" in run
print("PASS: the bridge and the preflight refuse another campaign's approvals journal")

live = (root / "AppleAuthCore/zag-apple-bridge/src/live.rs").read_text()
arm = live[live.index("PortalRequest::Certificates { team: t } =>"):live.index("PortalRequest::SubmitCertificateRequest")]
assert "list_all_development_certs(" in arm and "list_ios_certs(" not in arm and ".ok_or(BridgeError::new(FailureKind::Malformed))" in arm
print("PASS: the certificate listing is unfiltered (no certificate dropped by platform) and one incomplete entry fails the whole listing")

campaign = (fa / "ZagLiveExperimentCampaign.swift").read_text()
verify = campaign[campaign.index("func verifyAccountState("):campaign.index("func needsAccountStateCheck(")]
assert "let empty = certificates == 0 && appIDs == 0 && devices == 0" in verify and "#if" not in verify
print("PASS: the empty-account E4 (verifyAccountState) is unchanged")
PY

# S1 for this mode: the conditions and the authorisation must agree.
python3 -I - "$ROOT/docs/free-developer-accounts/G5-CAMPAIGNS.md" "$WORK" <<'PY'
import datetime, sys
source, work = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)
fmt = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
text = open(source).read()
rule = next(line for line in text.splitlines() if line.startswith("|----"))
for name, quote in [("existing", "\"existing account, approved changes only\""), ("empty", "\"test\"")]:
    row = f"| G5-C1 | 1 | {quote} | {fmt(now)} | {fmt(now + datetime.timedelta(days=2))} | A | https://anisette.example.org | g3Fixed | | | | authorised |"
    open(f"{work}/ledger-{name}.md", "w").write(text.replace(rule, rule + "\n" + row, 1))
PY
G5="ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT"
s1() { ZAG_G5_DEVICE_SERIAL=TESTSERIAL01 ZAG_G5_CONDITIONS="$1" ZAG_G5_LEDGER="$WORK/ledger-$2.md" bash "$ROOT/scripts/zag-g5-build-check.sh" check >/dev/null 2>&1; }
s1 "$G5 ZAG_EXISTING_ACCOUNT_EXPERIMENT" existing || { echo "FAIL: S1 refuses an existing-account build of an existing-account campaign" >&2; exit 1; }
! s1 "$G5 ZAG_EXISTING_ACCOUNT_EXPERIMENT" empty || { echo "FAIL: S1 builds the existing-account path for an empty-account campaign" >&2; exit 1; }
! s1 "$G5" existing || { echo "FAIL: S1 builds the empty-account path for an existing-account campaign" >&2; exit 1; }
! s1 "$G5 ZAG_EXISTING_ACCOUNT_EXPERIMENT DEBUG" existing || { echo "FAIL: S1 accepts DEBUG" >&2; exit 1; }
s1 "$G5" empty || { echo "FAIL: S1 refuses the empty-account campaign" >&2; exit 1; }
echo "PASS: S1 matches the build's mode to the authorisation, both ways; DEBUG refused"

(cd "$BRIDGE" && cargo build --quiet --release --features mock 2>/dev/null)
mkdir -p "$WORK/zsign"
git -C "$ROOT/Zsign" archive "${ZAG_ZSIGN_BRANCH:-zag-free-account-signing}" | tar -x -C "$WORK/zsign"
ZAG_ZSIGN_SRC="$WORK/zsign/src" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/branchlib" >/dev/null
mkdir -p "$WORK/authority"
"$SSL/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=Zag Store Test Intermediate (not Apple)" \
	-keyout "$WORK/authority/ca.key" -out "$WORK/authority/ca.pem" 2>/dev/null

build() { # sources-dir output
	swiftc -warnings-as-errors -parse-as-library \
		-D DEBUG -D ZAG_G5_TESTS -D ZAG_LIVE_EXPERIMENT -D ZAG_EXISTING_ACCOUNT_EXPERIMENT -D ZAG_APPLE_BRIDGE -D ZAG_ZSIGN_STRICT -D ZAG_ZSIGN_TESTS \
		-target "$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)" \
		-I "$WORK/branchlib/include" -import-objc-header "$BRIDGE/include/zag_apple_bridge.h" \
		"$1"/*.swift \
		"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
		"$WORK/zsign/Sources/zsign.swift" "$ROOT/scripts/ZagFreeAccountTestSupport.swift" "$ROOT/scripts/ZagG5TestHarness.swift" "$ROOT/scripts/ZagExistingAccountTests.swift" \
		"$BRIDGE/target/release/libzag_apple_bridge.a" -Xlinker "$WORK/branchlib/libzsign.a" -lc++ \
		-framework Security -framework CoreFoundation -framework SystemConfiguration -o "$2" 2>&1 | grep -E 'error|warning' || true
	[ -x "$2" ] || { echo "FAIL: $(basename "$2") did not build" >&2; exit 1; }
}
run() { # binary log
	(cd "$WORK" && ZAG_TEST_OPENSSL="$SSL/bin/openssl" ZAG_TEST_AUTHORITY="$WORK/authority" ZAG_TEST_WORK="$WORK" "$1" > "$2" 2>&1)
}

build "$FA" "$WORK/existing"
run "$WORK/existing" "$WORK/existing.log" || { grep -aE '^(FAIL|RESULT)' "$WORK/existing.log"; echo "FAIL: existing-account tests" >&2; exit 1; }
grep -aE '^(PASS|SUCCESS)|^  \|' "$WORK/existing.log"

mutant() { # name python-edit
	mkdir -p "$WORK/$1"
	cp "$FA"/*.swift "$WORK/$1/"
	python3 -I -c "$2" "$WORK/$1"
	build "$WORK/$1" "$WORK/$1.bin"
	if run "$WORK/$1.bin" "$WORK/$1.log"; then echo "FAIL: the suite passes with the $1 mutant" >&2; exit 1; fi
	echo "PASS: the $1 mutant fails $(grep -acE '^FAILED: ' "$WORK/$1.log") checks, in $(grep -aE '^FAILED: ' "$WORK/$1.log" | sed -E 's/^FAILED: ([A-Z][0-9]+).*/\1/' | sort -uV | tr '\n' ' ')"
}
# The journal bypassed: changes are sent without approval.
mutant no-approval '
import sys; p = sys.argv[1] + "/ZagIsideloadBridge.swift"; s = open(p).read()
start = s.index("\t\tdo {\n\t\t\t// The journal must be this campaign\x27s"); end = s.index("\t\t}\n", s.index("throw ZagPortalError.livePortalDisabled", start)) + 4
open(p, "w").write(s[:start] + "\t\t_ = mutation // MUTANT\n" + s[end:])'
# The preflight given a writable portal that registers this iPhone. The
# bridge refuses any change before an accepted inventory (C8) and without an
# approval, so both guards are removed too: the tests' own read-only checks
# (X1, X3, X6) must then catch the write.
mutant writing-preflight '
import sys; p = sys.argv[1] + "/ZagIsideloadBridge.swift"; s = open(p).read()
a = "\t\tthrow ZagLiveExperimentRefusal.check(\"C8\")\n\t\t#else"
assert s.count(a) == 1; s = s.replace(a, "\t\treturn // MUTANT\n\t\t#else")
start = s.index("\t\tdo {\n\t\t\t// The journal must be this campaign\x27s"); end = s.index("\t\t}\n", s.index("throw ZagPortalError.livePortalDisabled", start)) + 4
open(p, "w").write(s[:start] + "\t\t_ = mutation // MUTANT\n" + s[end:])
p = sys.argv[1] + "/ZagExistingAccountPreflight.swift"; s = open(p).read()
a = "\tfunc devices(team: String) async throws -> [ZagRegisteredDevice] { try await portal.devices(team: team) }\n\tfunc appIDs"
b = "\tfunc devices(team: String) async throws -> [ZagRegisteredDevice] { _ = try? await portal.registerDevice(udid: \"00000000-SIMULATED000000\", name: \"x\", team: team); return try await portal.devices(team: team) }\n\tfunc appIDs"
assert s.count(a) == 1; open(p, "w").write(s.replace(a, b))'
# Keychain and secret-store errors swallowed: read as "no key", which would
# lead to a new certificate (the defect fixed after 64711e52).
mutant swallowed-keychain-errors '
import sys; p = sys.argv[1] + "/ZagExistingAccountPreflight.swift"; s = open(p).read()
for case in ["secretStore", "keyStore"]:
    a = "\t\t\tlocal.unreadable = ." + case + "\n"
    assert a in s; s = s.replace(a, "")
open(p, "w").write(s)'
echo "SUCCESS: G5 existing-account path"
