#!/bin/bash
# G5: scans an experiment executable before the IPA is handed over
# (G5-EXPERIMENT-BUILD-PLAN.md §4.4, check 4; checklist S4).
#   test-zag-g5-experiment-binary.sh <Feather.app> <campaign ID> <anisette host>
#   test-zag-g5-experiment-binary.sh <Feather.app> G5-C0 -     (placeholder build:
#       the link check's; no campaign or provider is compiled in)
#   A fourth argument, existing-account, scans an existing-account build
#   (issue #37); without it, the existing-account code must be absent.
# It must contain the live bridge, the campaign (with its ID), the logger and
# the G3 host as the only anisette host; it must not contain any DEBUG-only,
# simulation or mock-backend symbol. A production build fails the first part.
set -euo pipefail
APP="${1:?Feather.app}"
CAMPAIGN="${2:?campaign ID}" # selects the mode; see `required` for why it is not scanned
HOST="${3:?anisette host}"
MODE="${4:-empty-account}"
case "$MODE" in empty-account | existing-account) ;; *) echo "unknown mode $MODE" >&2; exit 2 ;; esac
EXE="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-g5-binary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
{ strings -a "$EXE"; nm -a "$EXE" 2>/dev/null || true; } > "$WORK/symbols.txt"
missing=0
PLACEHOLDER=no
[ "$CAMPAIGN" = G5-C0 ] && [ "$HOST" = - ] && PLACEHOLDER=yes
# String literals and symbols an optimised build keeps. (Enums of static
# functions leave no type name, and a campaign ID such as "G5-C1" is a Swift
# small string stored inline, so neither can be scanned for.)
required=(zag_bridge_configure_live zag_bridge_configure_time_window zag_bridge_time_gate_status zag_bridge_take_policy_decisions
	ZagLiveExperimentCampaign ZagExperimentLogger ZagLiveExperimentView ZagStore.live-test.registry campaign-marker.json
	ZagStore.accounts.live-test cert.budget build.identity "Stop the Campaign" "Provision, Sign and Install")
[ "$PLACEHOLDER" = yes ] || required+=("$HOST")
existing=(ZagStore.live-test.existing-approvals "Read Account Inventory (read-only)" ZagExistingAccountApprovals)
if [ "$MODE" = existing-account ]; then
	required+=("${existing[@]}")
else
	for marker in "${existing[@]}"; do grep -qF -- "$marker" "$WORK/symbols.txt" && { echo "FOUND (existing-account code): $marker"; missing=$((missing + 1)); }; done
fi
for marker in "${required[@]}"; do
	grep -qF -- "$marker" "$WORK/symbols.txt" || { echo "MISSING: $marker"; missing=$((missing + 1)); }
done
found=0
for marker in ZagSecuritySigningKeyFactory configureMock zag_bridge_configure_mock ZagFreeAccountSimulation ZagDeveloperPortalSimulation \
	ZagSimulatedDeveloperPortal ZagSimulatedAuthenticationService simulationOnly MockBackend mock_backend ZAG_G5_TESTS \
	MemoryCampaignRegistry MemoryCampaignMarker testAllowsAbandon "Apple Account (Simulated)" zag-simulated-password "@example.invalid"; do
	grep -qF -- "$marker" "$WORK/symbols.txt" && { echo "FOUND: $marker"; found=$((found + 1)); }
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist" 2>/dev/null)" = "Zag LIVE TEST" ] \
	|| { echo "MISSING: the display name Zag LIVE TEST"; missing=$((missing + 1)); }
# The only anisette host is the campaign's.
others=$(grep -oE '(https|wss)://[A-Za-z0-9.-]*anisette[A-Za-z0-9.-]*' "$WORK/symbols.txt" | sed -E 's#^[a-z]+://##' | sort -u | grep -vxF -- "$HOST" || true)
[ -z "$others" ] || { echo "FOUND other anisette hosts: $others"; found=$((found + 1)); }
[ "$missing" -eq 0 ] && [ "$found" -eq 0 ] || { echo "FAIL: $missing missing, $found forbidden marker(s) in $EXE"; exit 1; }
echo "SUCCESS: $EXE is a $CAMPAIGN $MODE experiment build with no debug, simulation or mock code"
