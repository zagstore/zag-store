#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-onboarding.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library "$ROOT/Feather/Utilities/ZagOnboardingPolicy.swift" \
    "$ROOT/Feather/Utilities/ZagPairingLaunchCoordinator.swift" \
    "$ROOT/scripts/ZagOnboardingPolicyTests.swift" -o "$WORK/tests"
"$WORK/tests"
swiftc -warnings-as-errors -parse-as-library "$ROOT/Feather/Utilities/ZagOnboardingPolicy.swift" \
    "$ROOT/Feather/Utilities/ZagPairingLaunchCoordinator.swift" \
    "$ROOT/Feather/Utilities/ZagRPPairingLaunchService.swift" \
    "$ROOT/Feather/Utilities/ZagDeviceLink.swift" \
    "$ROOT/scripts/ZagPairingLaunchServiceTests.swift" -o "$WORK/service-tests"
"$WORK/service-tests"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
policy = (root / 'Feather/Utilities/ZagOnboardingPolicy.swift').read_text()
coordinator = (root / 'Feather/Utilities/ZagPairingLaunchCoordinator.swift').read_text()
app = (root / 'Feather/FeatherApp.swift').read_text()
welcome = (root / 'Feather/Views/Settings/ZagWelcomeView.swift').read_text()
assert all(token not in policy + coordinator for token in ['UserDefaults', 'AppStorage', 'beginInstallation', 'onboardingState'])
assert 'if !launch.policy.canEnterMain' in app and 'launch.startIfNeeded()' in app
assert 'launch.enqueue(url)' in app and 'launch.takeURLs()' in app
assert 'pairingFileExists' not in welcome and 'onboardingState' not in app
assert 'InstallationView()' in welcome and 'launch.retry()' in welcome and 'launch.skip()' in welcome
print('PASS: app integration has no persisted/file-existence bypass; setup, retry and deferred URL gate remain connected')
PY
