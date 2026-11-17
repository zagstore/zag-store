#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-developer-mode.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library "$ROOT/Feather/Utilities/ZagDeveloperModeGuidance.swift" \
    "$ROOT/scripts/ZagDeveloperModeGuidanceTests.swift" -o "$WORK/tests"
"$WORK/tests"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
view = (root / 'Feather/Views/Settings/Installation/ZagDeveloperModeGuidanceView.swift').read_text()
page = (root / 'Feather/Views/Settings/Installation/InstallationView.swift').read_text()
assert page.count('ZagDeveloperModeGuidanceView()') == 1
assert 'DisclosureGroup' in view and 'ZagDeveloperModeGuidance.status' in view
assert not any(api in view for api in ['openURL', 'UIApplication', 'pairingFileExists', 'gate2State', 'App-prefs', 'UserDefaults'])
print('PASS: one expandable native guide, no fabricated detection or system-navigation hooks')
PY
