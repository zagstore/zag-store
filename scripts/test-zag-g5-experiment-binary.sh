#!/bin/bash
# G5: scans an experiment executable before the IPA is handed over
# (G5-EXPERIMENT-BUILD-PLAN.md §4.4, check 4; checklist S4).
#   test-zag-g5-experiment-binary.sh <Feather.app> <campaign ID> <anisette host>
# It must contain the live bridge, the campaign (with its ID), the logger and
# the G3 host as the only anisette host; it must not contain any DEBUG-only,
# simulation or mock-backend symbol. A production build fails the first part.
set -euo pipefail
APP="${1:?Feather.app}"
CAMPAIGN="${2:?campaign ID}"
HOST="${3:?anisette host}"
EXE="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-g5-binary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
{ strings -a "$EXE"; nm -a "$EXE" 2>/dev/null || true; } > "$WORK/symbols.txt"
missing=0
for marker in zag_bridge_configure_live zag_bridge_take_policy_decisions ZagLiveExperimentCampaign ZagCertificateBudget \
	ZagExperimentLogger ZagExperimentReport ZagLiveExperimentView "$CAMPAIGN" "$HOST"; do
	grep -qF -- "$marker" "$WORK/symbols.txt" || { echo "MISSING: $marker"; missing=$((missing + 1)); }
done
found=0
for marker in ZagSecuritySigningKeyFactory configureMock zag_bridge_configure_mock ZagFreeAccountSimulation ZagDeveloperPortalSimulation \
	ZagSimulatedDeveloperPortal ZagSimulatedAuthenticationService simulationOnly MockBackend mock_backend ZAG_G5_TESTS \
	MemoryCampaignRegistry MemoryCampaignMarker testAllowsAbandon "Apple Account (Simulated)" zag-simulated-password "@example.invalid" G5-C0; do
	grep -qF -- "$marker" "$WORK/symbols.txt" && { echo "FOUND: $marker"; found=$((found + 1)); }
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist" 2>/dev/null)" = "Zag LIVE TEST" ] \
	|| { echo "MISSING: the display name Zag LIVE TEST"; missing=$((missing + 1)); }
# The only anisette host is the campaign's.
others=$(grep -oE '[a-z0-9.-]*anisette[a-z0-9.-]*\.[a-z]{2,}' "$WORK/symbols.txt" | sort -u | grep -vxF "$HOST" || true)
[ -z "$others" ] || { echo "FOUND other anisette hosts: $others"; found=$((found + 1)); }
[ "$missing" -eq 0 ] && [ "$found" -eq 0 ] || { echo "FAIL: $missing missing, $found forbidden marker(s) in $EXE"; exit 1; }
echo "SUCCESS: $EXE is a $CAMPAIGN experiment build with no debug, simulation or mock code"
