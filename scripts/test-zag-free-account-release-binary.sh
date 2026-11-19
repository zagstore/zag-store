#!/bin/bash
# Scans a compiled Zag Store app for the debug-only Apple Account screen,
# simulation and test credentials, and the G5 live experiment.
#   test-zag-free-account-release-binary.sh [Feather.app]          Release: must contain none
#   test-zag-free-account-release-binary.sh <Feather.app> debug    Debug-flag build: must contain all
# Both modes first require the free-account authenticator itself, so an
# empty or wrong binary cannot pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/_build/Applications/Feather.app}"
MODE="${2:-release}"
EXE="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-free-account-binary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
{ strings -a "$EXE"; nm -a "$EXE" 2>/dev/null || true; } > "$WORK/symbols.txt"
grep -qF ZagFreeAccountAuthenticator "$WORK/symbols.txt" || { echo "FAIL: $EXE does not contain the free-account code"; exit 1; }
DEBUG_ONLY=("Apple Account (Simulated)" ZagFreeAccountDebugSignInView ZagSimulatedAuthenticationService
	ZagFreeAccountSimulation ZagSimulationClock zag-simulated-password "@example.invalid" "Fill Test Account")
found=0
for marker in "${DEBUG_ONLY[@]}"; do
	if grep -qF -- "$marker" "$WORK/symbols.txt"; then found=$((found + 1)); [ "$MODE" = release ] && echo "FOUND: $marker"; fi
done
# Phase 3 portal simulation, the open (simulation-only) signing gate and the
# synthetic accounts (not in builds made before they existed, so release mode
# only). The signing adapter and lifecycle are production code behind the
# closed gate (`ZagFreeAccountSigning.isEnabled`), checked in the source below.
# Zsign itself exposes `signComponents` from f34e51a on, so the library name
# is in every build; Zag Store's caller (ZagStrictComponentSigning, compiled
# only with ZAG_ZSIGN_STRICT) is what must be absent. The G4 bridge to
# zag-isideload (compiled only with ZAG_APPLE_BRIDGE, its library never
# linked by the Xcode project) must be absent too.
for marker in ZagSecuritySigningKeyFactory ZagIsideloadAuthenticationService ZagIsideloadDeveloperPortal ZagBridgeAnisetteSource zag_bridge_open_slot \
	ZagStore.anisette.bridge ZagSimulatedDeveloperPortal ZagSimulatedSigningKeyFactory SIMULATED-PROFILE SIMULATED-CERTIFICATE \
	simulationOnly SIMULATED0002 SIMPAID001 ZagSimulatedAnisetteSource ZagAppleAccountsDebugView ZagAppleAccountsLab \
	"Apple Accounts (Simulated)" ZagStrictComponentSigning "Installed Profiles (Read Only)" ZagInstalledProfilesProbe \
	"Lose a Certificate Response" "Leave Items From an Earlier Installation"; do
	if [ "$MODE" = release ] && grep -qF -- "$marker" "$WORK/symbols.txt"; then found=$((found + 1)); echo "FOUND: $marker"; fi
done
# The G5 live experiment (compiled only with ZAG_LIVE_EXPERIMENT): its
# campaign, logger, screen, stores and bridge calls. None may be in a
# production build. Only strings longer than 15 bytes are listed: shorter
# Swift strings are stored inline and are invisible to `strings`, so the
# experiment event names the production provisioner passes to its hooks
# (logging spec L7) are checked in the source instead, by
# test-zag-g5-experiment.sh (the hooks' bodies are empty outside the
# experiment).
for marker in ZagLiveExperimentCampaign ZagExperimentLogger ZagExperimentReport ZagExperimentReadback ZagExperimentInstaller \
	ZagLiveExperimentView ZagCampaignRegistry ZagStore.live-test.registry ZagStore.accounts.live-test campaign-marker.json \
	zag_bridge_take_policy_decisions zag_bridge_configure_time_window zag_bridge_time_gate_status "Stop the Campaign" \
	"Provision, Sign and Install" submissionUnconfirmedSet submissionUnconfirmedCleared portal.certificateLimit cert.possessionMismatch; do
	if [ "$MODE" = release ] && grep -qF -- "$marker" "$WORK/symbols.txt"; then found=$((found + 1)); echo "FOUND: $marker"; fi
done
if [ "$MODE" = release ]; then
	grep -qE '^\s*static let isEnabled = false$' "$ROOT/Feather/Utilities/FreeAccount/ZagFreeAccountSigningAdapter.swift" \
		|| { echo "FAIL: the free-account signing gate is not closed in the source"; exit 1; }
	# The Apple Accounts recovery screens (Stored Account Data, unresolved
	# certificate request) are Release code, reachable only through the closed
	# Apple Accounts feature gate.
	sed -n '/^enum ZagAppleAccountsFeature {/,/^}/p' "$ROOT/Feather/Utilities/FreeAccount/ZagAccountRecoveryModels.swift" | grep -qE '^\s*static let isEnabled = false$' \
		|| { echo "FAIL: the Apple Accounts feature gate is not closed in the source"; exit 1; }
	for file in Feather/Utilities/FreeAccount/ZagAccountRecoveryModels.swift Feather/Views/Settings/FreeAccount/ZagAccountRecoveryViews.swift; do
		! grep -qE '^#if DEBUG' "$ROOT/$file" || { echo "FAIL: $file is Debug-only; the recovery screens must be in Release"; exit 1; }
	done
	python3 -I - "$ROOT/Feather/Views/Settings/SettingsView.swift" <<'PY' || { echo "FAIL: a Release Settings entry to the Apple Accounts screens is outside the feature gate"; exit 1; }
import re, sys
source = open(sys.argv[1]).read()
uses = [m.start() for m in re.finditer(r"ZagStoredAccountDataScreen|ZagCertificateRecoveryView|ZagStoredAccountDataView", source)]
gates = [(m.start(), source.index("}", source.index("NavigationLink", m.start()))) for m in re.finditer(r"if ZagAppleAccountsFeature\.isEnabled \{", source)]
assert uses, "no entry found"
for use in uses:
    assert any(start < use < end for start, end in gates), use
PY
	[ "$found" -eq 0 ] || { echo "FAIL: $found debug-only marker(s) in $EXE"; exit 1; }
	echo "SUCCESS: no simulation UI or test credentials in $EXE"
else
	[ "$found" -eq "${#DEBUG_ONLY[@]}" ] || { echo "FAIL: only $found of ${#DEBUG_ONLY[@]} markers in the debug build; the scan would miss them"; exit 1; }
	echo "SUCCESS: the debug build contains all ${#DEBUG_ONLY[@]} markers (the scan detects them)"
fi
