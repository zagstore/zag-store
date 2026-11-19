#!/bin/bash
# G5: the experiment's safeguards, offline (G5-EXPERIMENT-BUILD-PLAN.md §5.4,
# §5.5; G5-DIAGNOSTIC-LOGGING-SPEC.md §10; G5-IMPLEMENTATION-CHECKLIST.md).
# Builds the bridge with its mock backend and the strict Zsign branch, runs
# scripts/ZagG5ExperimentTests.swift (T1–T16, C1–C8, E5, L1–L11) with a local
# test authority, then the static checks and the no-`consume` mutant, which
# must fail. Nothing contacts Apple or an anisette provider.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/AppleAuthCore/zag-apple-bridge"
FA="$ROOT/Feather/Utilities/FreeAccount"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-g5.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SSL="${ZAG_OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null || true)}"

# Static checks first (T11, L5, L9, M8, the allowlist).
python3 -I - "$ROOT" <<'PY'
from pathlib import Path
import os, re, subprocess, sys
root = Path(sys.argv[1])
fa = root / "Feather/Utilities/FreeAccount"
swift = {p: p.read_text() for p in (root / "Feather").rglob("*.swift")}
def code(text):
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))

# T11: one certificate-submission path.
bridge = (fa / "ZagIsideloadBridge.swift").read_text()
assert code(bridge).count('"op": "submitCertificateRequest"') == 1, "the submit op string appears once"
assert sum(code(t).count('"submitCertificateRequest"') for p, t in swift.items() if p.name != "ZagIsideloadBridge.swift") == 0
consume = [p.name for p, t in swift.items() if "ZagCertificateBudget.consume(" in code(t)]
assert consume == ["ZagIsideloadBridge.swift"] and code(bridge).count("ZagCertificateBudget.consume(") == 1, consume
submit = bridge[bridge.index("func submitCertificateRequest("):]
assert submit.index("ZagCertificateBudget.consume(") < submit.index("sendCertificateRequest("), "consume precedes the send"
for name in ["recordSubmission(", "authorizeSubmission("]:
    callers = sorted(p.name for p, t in swift.items() if re.search(r"\.\s*" + re.escape(name), code(t)))
    assert callers == ["ZagCertificateBudget.swift"], (name, callers)
callers = sorted({p.name for p, t in swift.items() if re.search(r"\.submitCertificateRequest\(", code(t))})
assert callers == ["ZagFreeAccountProvisioner.swift"], callers
print("PASS: T11 one submission path: the op string once, consume once and before the send, the budget only in ZagCertificateBudget")

# G4 network invariants the experiment relies on (C5): every Apple request
# goes through the guarded client, which follows no redirects, and an
# experiment build never has a live backend without the time window.
import re
def production(path):
    text = path.read_text()
    cut = text.find("#[cfg(test)]\nmod tests")
    text = text if cut < 0 else text[:cut]
    # Code only: comment lines (upstream's disabled relay, docs) do not count.
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
rust = {p.relative_to(root).as_posix(): production(p)
        for crate in ["AppleAuthCore/zag-isideload/src", "AppleAuthCore/zag-apple-bridge/src"]
        for p in sorted((root / crate).rglob("*.rs"))}
policy = "AppleAuthCore/zag-isideload/src/net_policy.rs"
for pattern in [r"reqwest::Client(?!Builder|\w)", r"Client::new\(", r"Client::builder\(", r"reqwest::get\(", r"reqwest::blocking",
                r"\bureq\b", r"\bisahc\b", r"\bsurf::", r"hyper::Client", r"std::net::", r"UdpSocket"]:
    hits = [f for f, t in rust.items() if re.search(pattern, t)]
    assert not hits, (pattern, hits)
builders = sorted(f for f, t in rust.items() if "ClientBuilder::new()" in t)
assert builders == ["AppleAuthCore/zag-isideload/src/anisette/remote_v3/mod.rs", "AppleAuthCore/zag-isideload/src/auth/grandslam.rs"], builders
assert all("net_policy::guarded_client(" in rust[f] for f in builders), builders
assert [f for f, t in rust.items() if "MwClientBuilder::new(" in t or ".redirect(" in t] == [policy]
src = rust[policy]
guarded = src[src.index("pub fn guarded_client("):src.index("struct Guard")]
assert src.count("MwClientBuilder::new(") == 1 and src.count(".redirect(") == 1
for needle in [".https_only(true)", ".redirect(redirect::Policy::none())", ".with(Guard { allowed })"]:
    assert needle in guarded, needle
handle = src[src.index("impl Middleware for Guard"):src.index("pub fn permit_observed")]
order = [handle.index(n) for n in ["permit_observed(", "time_gate::before_request(", "next.run(", "time_gate::after_response("]]
assert order == sorted(order), order
assert [f for f, t in rust.items() if "connect_async(" in t] == ["AppleAuthCore/zag-isideload/src/anisette/remote_v3/websocket.rs"]
ws = rust["AppleAuthCore/zag-isideload/src/anisette/remote_v3/websocket.rs"]
assert ws.index("net_policy::permit_observed(") < ws.index("connect_async(")
assert 'time_gate::before_request(' not in "".join(t for f, t in rust.items() if f != policy)
print("PASS: G4 network: only guarded_client builds HTTP clients (https only, no redirects, Guard with the time gate around each request); the anisette socket checks the policy first; no other client or socket")

app_swift = {p.relative_to(root).as_posix(): p.read_text() for p in sorted((root / "Feather").rglob("*.swift"))}
bridge_file = "Feather/Utilities/FreeAccount/ZagIsideloadBridge.swift"
assert [f for f, t in app_swift.items() if "zag_bridge_configure_live(" in t] == [bridge_file]
bridge = app_swift[bridge_file]
live = bridge[bridge.index("static func configureLive("):bridge.index("static func configureFromCampaign(")]
assert "zag_bridge_configure_live(" in live and bridge.count("zag_bridge_configure_live(") == 1
assert live.index("#if ZAG_LIVE_EXPERIMENT\n\t\t// C5") < live.index("guard zag_bridge_time_gate_status() == 2 else { return false }") < live.index("#endif") < live.index("zag_bridge_configure_live(")
callers = [f for f, t in app_swift.items() if re.search(r"\bconfigureLive\(anisetteURL:", t.replace("static func configureLive(anisetteURL:", ""))]
assert callers == [bridge_file], callers
campaign_cfg = bridge[bridge.index("static func configureFromCampaign("):bridge.index("static func takePolicyDecisions(")]
assert campaign_cfg.count("configureLive(anisetteURL:") == 1
window = campaign_cfg.index("guard zag_bridge_configure_time_window(")
assert window < campaign_cfg.index("Int64(ZagCampaignConstants.maximumSkew)) == 0 else { return false }") < campaign_cfg.index("configureLive(anisetteURL:")
assert [f for f, t in app_swift.items() if "configureFromCampaign(" in t] == ["Feather/Utilities/FreeAccount/ZagIsideloadBridge.swift", "Feather/Views/Settings/FreeAccount/ZagLiveExperimentView.swift"]
assert not [f for f, t in app_swift.items() if re.search(r"ZagURLSessionTransport\(", t) and not f.endswith("ZagFreeAccountTransport.swift")]
assert not [f for f, t in app_swift.items() if re.search(r"gsa\.apple\.com|developerservices2\.apple\.com", t) and not f.endswith("ZagExperimentLogger.swift")]
print("PASS: C5 configuration: the live backend is configured only by configureFromCampaign, after the window is accepted; configureLive refuses an unconfigured gate in experiment builds; no Swift HTTP client reaches Apple")

# L7: outside the experiment the provisioner's hooks do nothing, so the
# event names passed to them are inert in production (and, as Swift small
# strings, not scannable in the binary).
prov = (fa / "ZagFreeAccountProvisioner.swift").read_text()
for name in ["experimentStop", "experimentFailure", "experimentEvent"]:
    start = prov.index(f"private func {name}(")
    body = prov[prov.index("{", prov.index(")", start)) + 1:]
    depth, i = 1, 0
    while depth:
        depth += {"{": 1, "}": -1}.get(body[i], 0); i += 1
    body = body[:i - 1].strip()
    assert body.startswith("#if ZAG_LIVE_EXPERIMENT\n") and body.endswith("#endif"), name
    rest = body[body.rfind("#else"):] if "#else" in body else ""
    assert rest in ("", "#else\n\t\treturn nil\n\t\t#endif"), (name, rest)
print("PASS: L7 the provisioner's experiment hooks are empty outside the experiment")

# Revocation is not implemented anywhere.
assert not re.search(r"revoke[A-Za-z]*Cert[a-zA-Z]*\s*\(", "\n".join(code(t) for t in swift.values()))
print("PASS: no certificate revocation call exists")

# L5: the failure map has no default branch.
logger = (fa / "ZagExperimentLogger.swift").read_text()
fmap = logger[logger.index("enum ZagExperimentFailureMap"):]
fmap = fmap[:fmap.index("\n}\n")]
assert "default:" not in fmap and "@unknown" not in fmap
print("PASS: L5 the failure map is total (no default)")

# L9: no private-key export outside Debug-only code.
keyexport = re.compile(r"SecKeyCopyExternalRepresentation|SecItemExport|kSecAttrIsExtractable\s*as\s*String\s*:\s*true")
for path, text in swift.items():
    stripped = re.sub(r"#if DEBUG\n.*?\n#endif", "", text, flags=re.S)
    for line in code(stripped).splitlines():
        if keyexport.search(line) and "publicKey" not in line and "SecKeyCopyPublicKey" not in line:
            raise AssertionError(f"key export in {path.name}: {line.strip()}")
print("PASS: L9 no private-key export call in experiment or production code")

# M8: the registry's Keychain service appears only in the campaign file.
names = [p.name for p, t in swift.items() if "ZagStore.live-test.registry" in t]
assert names == ["ZagLiveExperimentCampaign.swift"], names
print("PASS: M8 the campaign registry service is named in one file (Stored Account Data never lists it)")

# The experiment never compiles DEBUG.
campaign = (fa / "ZagLiveExperimentCampaign.swift").read_text()
assert campaign.startswith("#if ZAG_LIVE_EXPERIMENT\n#if DEBUG && !ZAG_G5_TESTS\n#error(")
for p, t in swift.items():
    for m in re.finditer(r"#if ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT(.*)", t):
        assert m.group(1).strip() == "&& !DEBUG", (p.name, m.group(0))
print("PASS: every live switch requires !DEBUG; DEBUG experiment builds are refused outside the test harness")

# The network allowlist and its checks are unchanged against the reviewed G4
# stack (PR #35 head, the frozen base of the experiment).
base = os.environ.get("ZAG_G5_BASE", "46aaa1c4")
old = subprocess.run(["git", "-C", str(root), "show", f"{base}:AppleAuthCore/zag-isideload/src/net_policy.rs"], capture_output=True, text=True, check=True).stdout
new = (root / "AppleAuthCore/zag-isideload/src/net_policy.rs").read_text()
def item(text, start):
    i = text.index(start)
    depth, j = 0, text.index("{", i) if "{" in text[i:i + 400] and not start.startswith("pub const") else text.index(";", i)
    if text[j] == ";": return text[i:j + 1]
    while True:
        depth += {"{": 1, "}": -1}.get(text[j], 0)
        if depth == 0: return text[i:j + 1]
        j += 1
for start in ["pub const APPLE_HOSTS", "pub fn permit(", "pub fn check_url("]:
    assert item(old, start) == item(new, start), f"{start} changed"
print(f"PASS: APPLE_HOSTS, permit and check_url are unchanged against {base} (PR #35 head)")
PY

# S1: the build check refuses without an authorised ledger row and with any
# DEBUG condition; on an authorised (test) row it writes constants in the
# generated form without committing.
! bash "$ROOT/scripts/zag-g5-build-check.sh" check 2>"$WORK/s1.txt" && grep -q "no campaign is authorised" "$WORK/s1.txt" \
	|| { echo "FAIL: S1 builds without an authorised campaign" >&2; exit 1; }
for conditions in "DEBUG ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT" "ZAG_G5_TESTS ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT" "ZAG_APPLE_BRIDGE ZAG_LIVE_EXPERIMENT"; do
	! ZAG_G5_CONDITIONS="$conditions" bash "$ROOT/scripts/zag-g5-build-check.sh" check 2>/dev/null || { echo "FAIL: S1 accepts conditions $conditions" >&2; exit 1; }
done
python3 -I - "$ROOT/docs/free-developer-accounts/G5-CAMPAIGNS.md" "$WORK/ledger.md" <<'PY'
import datetime, sys
source, out = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)
fmt = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
text = open(source).read()
rule = next(line for line in text.splitlines() if line.startswith("|----"))
def row(n, start, end, state, policy="g3Fixed"):
    return f"| G5-C{n} | {n} | \"test\" | {fmt(start)} | {fmt(end)} | A | https://anisette.example.org | {policy} | | | | {state} |"
rows = {"ok": [row(1, now, now + datetime.timedelta(days=2), "authorised")],
        "expired": [row(1, now - datetime.timedelta(days=3), now - datetime.timedelta(days=1), "authorised")],
        "long": [row(1, now, now + datetime.timedelta(days=8), "authorised")],
        "perAccount": [row(1, now, now + datetime.timedelta(days=2), "authorised", "g3PerAccount")],
        "reused": [row(2, now - datetime.timedelta(days=9), now - datetime.timedelta(days=8), "closed: SAFE STOP"), row(2, now, now + datetime.timedelta(days=1), "authorised")]}
for name, lines in rows.items():
    open(out.replace(".md", f"-{name}.md"), "w").write(text.replace(rule, rule + "\n" + "\n".join(lines), 1))
PY
export ZAG_G5_DEVICE_SERIAL=TESTSERIAL01
ZAG_G5_LEDGER="$WORK/ledger-ok.md" bash "$ROOT/scripts/zag-g5-build-check.sh" constants --out "$WORK/constants.swift" >/dev/null
python3 -I "$ROOT/scripts/zag-g5-constants.py" verify < "$WORK/constants.swift"
grep -q 'static let campaignID = "G5-C1"' "$WORK/constants.swift" && ! grep -q '"00000000000000000000000000000000"' "$WORK/constants.swift"
for bad in expired long reused perAccount; do
	! ZAG_G5_LEDGER="$WORK/ledger-$bad.md" bash "$ROOT/scripts/zag-g5-build-check.sh" check 2>/dev/null || { echo "FAIL: S1 accepts a $bad campaign" >&2; exit 1; }
done
unset ZAG_G5_DEVICE_SERIAL
! ZAG_G5_LEDGER="$WORK/ledger-ok.md" bash "$ROOT/scripts/zag-g5-build-check.sh" check 2>/dev/null || { echo "FAIL: S1 accepts g3Fixed without a device serial" >&2; exit 1; }
grep -q 'static let campaignID = "G5-C0"' "$ROOT/Feather/Utilities/FreeAccount/ZagLiveExperimentCampaignConstants.swift" || { echo "FAIL: the committed constants are not the placeholder" >&2; exit 1; }
echo "PASS: S1 refuses no authorisation, DEBUG/test/missing conditions, an expired, over-long or reused campaign, g3PerAccount (unsupported by the bridge) and g3Fixed without a serial; writes constants in the generated form; the committed constants stay the placeholder"

# Libraries: the bridge with its mock backend; the strict Zsign branch.
(cd "$BRIDGE" && cargo build --quiet --release --features mock 2>/dev/null)
mkdir -p "$WORK/zsign"
git -C "$ROOT/Zsign" archive "${ZAG_ZSIGN_BRANCH:-zag-free-account-signing}" | tar -x -C "$WORK/zsign"
ZAG_ZSIGN_SRC="$WORK/zsign/src" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/branchlib" >/dev/null
mkdir -p "$WORK/authority"
"$SSL/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=Zag Store Test Intermediate (not Apple)" \
	-keyout "$WORK/authority/ca.key" -out "$WORK/authority/ca.pem" 2>/dev/null

build() { # sources-dir output
	swiftc -warnings-as-errors -parse-as-library \
		-D DEBUG -D ZAG_G5_TESTS -D ZAG_LIVE_EXPERIMENT -D ZAG_APPLE_BRIDGE -D ZAG_ZSIGN_STRICT -D ZAG_ZSIGN_TESTS \
		-target "$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)" \
		-I "$WORK/branchlib/include" -import-objc-header "$BRIDGE/include/zag_apple_bridge.h" \
		"$1"/*.swift \
		"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
		"$WORK/zsign/Sources/zsign.swift" "$ROOT/scripts/ZagFreeAccountTestSupport.swift" "$ROOT/scripts/ZagG5ExperimentTests.swift" \
		"$BRIDGE/target/release/libzag_apple_bridge.a" -Xlinker "$WORK/branchlib/libzsign.a" -lc++ \
		-framework Security -framework CoreFoundation -framework SystemConfiguration -o "$2" 2>&1 | grep -E 'error|warning' || true
	[ -x "$2" ] || { echo "FAIL: $(basename "$2") did not build" >&2; exit 1; }
}
run() { # binary log [groups]
	(cd "$WORK" && ZAG_G5_ONLY="${3:-}" ZAG_TEST_OPENSSL="$SSL/bin/openssl" ZAG_TEST_AUTHORITY="$WORK/authority" ZAG_TEST_WORK="$WORK" "$1" > "$2" 2>&1)
}

build "$FA" "$WORK/g5"
run "$WORK/g5" "$WORK/g5.log" || { grep -aE '^(FAIL|RESULT)' "$WORK/g5.log"; echo "FAIL: G5 experiment tests" >&2; exit 1; }
grep -aE '^(PASS|SUCCESS)' "$WORK/g5.log"

# The no-consume mutant: the choke point removed, the suite must fail.
mkdir -p "$WORK/mutant"
cp "$FA"/*.swift "$WORK/mutant/"
python3 -I - "$WORK/mutant/ZagIsideloadBridge.swift" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
start = s.index("\t\ttry await ZagCertificateBudget.consume(")
end = s.index("\t\t)\n", start) + 4
open(p, "w").write(s[:start] + "\t\t_ = accountKey // MUTANT: consume removed\n" + s[end:])
PY
build "$WORK/mutant" "$WORK/mutant-g5"
if run "$WORK/mutant-g5" "$WORK/mutant.log" budget; then
	echo "FAIL: the suite passes with ZagCertificateBudget.consume removed" >&2
	exit 1
fi
echo "PASS: the no-consume mutant fails: $(grep -acE '^FAILED: ' "$WORK/mutant.log") checks, in $(grep -aE '^FAILED: ' "$WORK/mutant.log" | sed -E 's/^FAILED: (L10\/)?(T[0-9]+).*/\2/' | sort -uV | tr '\n' ' ')"
echo "SUCCESS: G5 experiment safeguards"
