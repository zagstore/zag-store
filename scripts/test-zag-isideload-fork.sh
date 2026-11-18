#!/bin/bash
# Tests the trimmed isideload fork (AppleAuthCore/zag-isideload). Nothing
# here contacts a network service: the fork's own tests check that requests
# are refused without the live-network feature, and that the policy refuses
# other hosts, schemes, ports and credentials when the feature is on (no
# request is sent in either case).
#   1. cargo tests, without and with live-network
#   2. builds for aarch64-apple-ios, without and with live-network
#   3. source checks: removed behaviours stay removed
#   4. dependencies: Cargo.lock matches LICENCE-INVENTORY.tsv, and no
#      copyleft crate is compiled for iOS
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/AppleAuthCore/zag-isideload"
export CARGO_TARGET_DIR="$CRATE/target"
FAILED=0
fail() { echo "FAIL: $1"; FAILED=1; }
pass() { echo "PASS: $1"; }

cd "$CRATE"
cargo test --locked --quiet >/dev/null 2>&1 \
	&& pass "tests without live-network (Apple and anisette requests refused)" || fail "tests without live-network"
cargo test --locked --quiet --features live-network >/dev/null 2>&1 \
	&& pass "tests with live-network (allowlist, https/wss only, no ports or credentials, no redirects)" || fail "tests with live-network"

if rustup target list --installed 2>/dev/null | grep -qx aarch64-apple-ios; then
	cargo build --locked --quiet --target aarch64-apple-ios >/dev/null 2>&1 \
		&& pass "builds for aarch64-apple-ios" || fail "aarch64-apple-ios build"
	cargo build --locked --quiet --target aarch64-apple-ios --features live-network >/dev/null 2>&1 \
		&& pass "builds for aarch64-apple-ios with live-network" || fail "aarch64-apple-ios build with live-network"
else
	echo "SKIP: aarch64-apple-ios target not installed"
fi

# Removed behaviours: insecure TLS switches, logging, relays, the default
# anisette server, plain http/ws, file and keyring storage, signing code.
check_absent() {
	local pattern="$1" what="$2" hits
	# Comment lines (which describe what was removed) are not code.
	hits=$(grep -rnE "$pattern" src Cargo.toml | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|#)' || true)
	[ -z "$hits" ] && pass "no $what" || { fail "$what present"; echo "$hits"; }
}
check_absent 'danger_|accept_invalid|dangerous' "insecure TLS options"
check_absent 'tracing|log::|println!|eprintln!|dbg!' "logging"
check_absent 'proxy_url|websocket_proxy|\.proxy\(' "request relay"
check_absent 'iloader|set_url|DEFAULT_ANISETTE' "default or changeable anisette server"
# net_policy.rs's tests use such URLs to check they are refused.
hits=$(grep -rnE '"http://|"ws://' src Cargo.toml | grep -v '^src/net_policy.rs:' || true)
[ -z "$hits" ] && pass "no plain http or ws URLs" || { fail "plain http or ws URLs present"; echo "$hits"; }
check_absent 'keyring|fs_storage|apple-codesign|p12-keystore|isideload-vfs|idevice|rcgen' "storage backends or signing dependencies"
[ ! -e src/sideload ] && [ ! -e src/auth/middleware.rs ] && pass "sideload/ and the relay middleware are removed" || fail "removed modules are back"
grep -q '^default = \[\]' Cargo.toml && pass "live-network is off by default" || fail "default features not empty"
grep -q 'redirect(redirect::Policy::none())' src/net_policy.rs \
	&& pass "redirects are not followed" || fail "redirect policy not found"

# Dependencies.
python3 -I - Cargo.lock LICENCE-INVENTORY.tsv <<'PY' || FAILED=1
import re, sys
text = open(sys.argv[1]).read()
locked = set()
for block in text.split("[[package]]")[1:]:
    source = re.search(r'^source = "([^"]+)"', block, re.M)
    if source and source.group(1).startswith("registry"):
        locked.add((re.search(r'^name = "([^"]+)"', block, re.M).group(1),
                    re.search(r'^version = "([^"]+)"', block, re.M).group(1)))
inventory = {}
for line in open(sys.argv[2]):
    if line.startswith("#") or line.startswith("crate\t"):
        continue
    name, version, licence, ios = line.rstrip("\n").split("\t")
    inventory[(name, version)] = (licence, ios)
ok = True
if set(inventory) != locked:
    print("FAIL: LICENCE-INVENTORY.tsv does not match Cargo.lock:",
          sorted(locked - set(inventory))[:5], sorted(set(inventory) - locked)[:5])
    ok = False
copyleft = [f"{n} {v} ({l})" for (n, v), (l, ios) in inventory.items()
            if ios == "yes" and re.search(r"GPL|MPL|EPL|CDDL|SSPL|EUPL", l)]
if copyleft:
    print("FAIL: copyleft crates compiled for iOS:", copyleft)
    ok = False
if ok:
    print(f"PASS: {len(locked)} locked crates match the inventory; "
          f"{sum(1 for l, ios in inventory.values() if ios == 'yes')} compiled for iOS, none copyleft")
sys.exit(0 if ok else 1)
PY
ios_set=$(cargo tree --locked --target aarch64-apple-ios -e normal,build --prefix none --format '{p}' 2>/dev/null \
	| sed -E 's/ \(.*//; s/ v/\t/' | grep -v '^zag-isideload' | sort -u)
inv_set=$(awk -F'\t' '$4 == "yes" { print $1 "\t" $2 }' LICENCE-INVENTORY.tsv | sort -u)
[ "$ios_set" = "$inv_set" ] && pass "the inventory's iOS column matches cargo tree" || fail "the inventory's iOS column is out of date"

[ "$FAILED" = 0 ] && echo "SUCCESS: zag-isideload fork checks passed" || { echo "FAIL: zag-isideload fork checks"; exit 1; }
