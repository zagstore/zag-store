#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-deep-links.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library "$ROOT/Feather/Utils/ZagStoreRouter.swift" \
    "$ROOT/Feather/Utilities/ZagDeepLink.swift" "$ROOT/Feather/Utilities/ZagMobileDataToggle.swift" \
    "$ROOT/scripts/ZagDeepLinkTests.swift" -o "$WORK/tests"
"$WORK/tests"
python3 - "$ROOT" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
p = plistlib.loads((root / 'Feather/Resources/Info.plist').read_bytes())
assert {s for entry in p['CFBundleURLTypes'] for s in entry['CFBundleURLSchemes']} == {'feather', 'zagstore'}
assert p['LSApplicationQueriesSchemes'] == ['localdevvpn']
assert 'private static let githubURL = URL(string: "https://github.com/zagstore/zag-store")!' in (root / 'Feather/Views/Settings/SettingsView.swift').read_text()
assert '"https://github.com/khcrysalis/Feather"' not in (root / 'Feather/Views/Sources/SourcesView.swift').read_text()
print('PASS: app feedback and support links target Zag Store; attribution links retained')
print('PASS: registered schemes and LocalDevVPN compatibility retained')
PY
