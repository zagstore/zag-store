#!/bin/bash
# Scans a compiled Zag Store app for the debug-only Apple Account screen,
# simulation and test credentials.
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
if [ "$MODE" = release ]; then
	[ "$found" -eq 0 ] || { echo "FAIL: $found debug-only marker(s) in $EXE"; exit 1; }
	echo "SUCCESS: no simulation UI or test credentials in $EXE"
else
	[ "$found" -eq "${#DEBUG_ONLY[@]}" ] || { echo "FAIL: only $found of ${#DEBUG_ONLY[@]} markers in the debug build; the scan would miss them"; exit 1; }
	echo "SUCCESS: the debug build contains all ${#DEBUG_ONLY[@]} markers (the scan detects them)"
fi
