#!/bin/bash
# Free-account end-to-end offline validation harness.
#
# Runs the existing per-stage Zag Store suites in the order of the 11-stage
# free-Apple-Account sign -> sign -> install workflow, against synthetic
# fixtures and the mock/offline backends only. It does NOT add a parallel
# pipeline: each stage simply invokes the suite that already exercises that
# stage's real code, and reports PASS/FAIL per stage.
#
# What this harness CAN show: that each stage's local logic, error handling,
# redaction, gating and persistence behave as specified against synthetic
# inputs. What it CANNOT show: that Apple's live services accept the workflow.
# Nothing here signs in to Apple, contacts an anisette server or installs on a
# device. Live acceptance requires the separately gated, authorised procedure
# in docs/free-developer-accounts/LIVE-VALIDATION-PROCEDURE.md.
#
# Usage:
#   scripts/test-zag-free-account-e2e.sh            # all stages
#   scripts/test-zag-free-account-e2e.sh --rust     # only stages with Rust suites (no Xcode/swiftc)
#   scripts/test-zag-free-account-e2e.sh --list     # list the stage -> suite map and exit
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="all"
case "${1:-}" in
	--rust) MODE="rust" ;;
	--list) MODE="list" ;;
	"") ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
esac

# stage number | label | kind (rust|swift) | suite script
# A stage may list more than one suite; all must pass for the stage to pass.
STAGES=(
	"1|Sign-in and two-factor|swift|test-zag-free-account-sign-in.sh"
	"1|Sign-in and two-factor|swift|test-zag-free-account-authentication.sh"
	"2|Anisette provisioning (remote_v3, identity isolation, diagnostics)|rust|test-zag-isideload-fork.sh"
	"3|Session persistence (Keychain, fail-closed)|swift|test-zag-free-account-keychain.sh"
	"3|Session persistence (foundation: crypto/state)|swift|test-zag-free-account-foundation.sh"
	"4|Team discovery|swift|test-zag-apple-accounts.sh"
	"4|Developer-portal reads/writes (teams, devices, app IDs, certs, profiles)|swift|test-zag-free-account-portal.sh"
	"5|Device registration and install transport|swift|test-zag-device-link.sh"
	"6|App ID registration|swift|test-zag-free-account-portal.sh"
	"7|Development certificate (bridge + key handling)|rust|test-zag-apple-bridge.sh"
	"8|Provisioning profile|swift|test-zag-free-account-portal.sh"
	"9|Zsign signing (strict component signing)|swift|test-zag-free-account-signing.sh"
	"9|Zsign branch provenance|swift|test-zag-zsign-branch.sh"
	"10|RPPairing install path|swift|test-zag-install-control-taps.sh"
	"11|Post-install verification (installed-profile readback)|swift|test-zag-free-account-signing.sh"
)

if [ "$MODE" = "list" ]; then
	printf '%-4s %-8s %-55s %s\n' "STG" "KIND" "STAGE" "SUITE"
	for row in "${STAGES[@]}"; do
		IFS='|' read -r n label kind suite <<< "$row"
		printf '%-4s %-8s %-55.55s %s\n' "$n" "$kind" "$label" "$suite"
	done
	exit 0
fi

# De-duplicate suites: run each script at most once, caching its result and
# log in a temp dir (bash 3.2 on macOS has no associative arrays).
CACHE=$(mktemp -d "${TMPDIR:-/tmp/}zag-e2e.XXXXXX")
trap 'rm -rf "$CACHE"' EXIT
suite_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
run_suite() {
	local suite="$1" key; key=$(suite_key "$suite")
	if [ -f "$CACHE/$key.res" ]; then return 0; fi
	local script="$ROOT/scripts/$suite"
	if [ ! -f "$script" ]; then
		printf 'MISSING' > "$CACHE/$key.res"; printf '(script not found: %s)' "$suite" > "$CACHE/$key.log"; return 0
	fi
	local log; log=$(bash "$script" 2>&1); local rc=$?
	printf '%s' "$log" > "$CACHE/$key.log"
	if [ $rc -eq 0 ]; then printf 'PASS' > "$CACHE/$key.res"; else printf 'FAIL(%s)' "$rc" > "$CACHE/$key.res"; fi
}
suite_result() { cat "$CACHE/$(suite_key "$1").res"; }
suite_log() { cat "$CACHE/$(suite_key "$1").log"; }

echo "== Free-account end-to-end offline harness (mode: $MODE) =="
echo "   Synthetic fixtures / mock + offline backends only. No Apple contact."
echo

overall=0
for row in "${STAGES[@]}"; do
	IFS='|' read -r n label kind suite <<< "$row"
	if [ "$MODE" = "rust" ] && [ "$kind" != "rust" ]; then
		printf 'Stage %-2s  SKIP (needs Xcode/swiftc)  %s\n' "$n" "$label"
		continue
	fi
	run_suite "$suite"
	res=$(suite_result "$suite")
	printf 'Stage %-2s  %-10s %-52.52s via %s\n' "$n" "$res" "$label" "$suite"
	case "$res" in PASS) ;; *) overall=1 ;; esac
done

echo
if [ $overall -eq 0 ]; then
	echo "RESULT: all run stages PASS (offline). Live Apple acceptance NOT tested here."
else
	echo "RESULT: one or more stages did not pass; see logs below."
	for f in "$CACHE"/*.res; do
		res=$(cat "$f"); case "$res" in PASS) continue ;; esac
		key=$(basename "$f" .res); echo "--- $key ($res) ---"; tail -15 "$CACHE/$key.log"
	done
fi
exit $overall
