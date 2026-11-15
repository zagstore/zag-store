#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
view = (root / 'Feather/Views/Settings/Installation/InstallationView.swift').read_text().split('private struct RPPairingView:', 1)[1].split('private struct ZagUnpairConfirmationBubble:', 1)[0]
assert view.count('Button(role: pairingCore.pairingFileExists') == 1
assert view.count('Label("Pairing File"') == 1
assert view.index('Button(role: pairingCore.pairingFileExists') < view.index('Label("Pairing File"')
assert '? "Unpair This iPhone"' in view and '"Pair This iPhone"' in view
assert view.count('\n\t\tSection {') == 4
assert 'Settings App → Privacy & Security → Developer Mode → Pair with Zag Store' in view
assert 'pairingCore.start()' in view and 'try pairingCore.forgetPairing()' in view
assert '.disabled(pairingCore.isRunning)' in view
assert 'Button {\n                        guard let code = ZagPairingCodeNotification.validCode(pin)' in view
assert '.localOnly: true' in view and '.expirationDate: Date().addingTimeInterval(120)' in view
assert '.frame(width: 22, alignment: .center)' in view
assert view.count('ZagPairingIcon().frame(width: 25, height: 25)') == 3
assert 'App-prefs:' not in view and 'prefs:root' not in view and 'openSettingsURLString' not in view
print('PASS: paired/unpaired control precedes file row once, without adding sections')
print('PASS: exact manual instructions and existing actions/trailing indicators retained')
print('PASS: copy is explicit, local-only and expiring; no unsupported Settings shortcut')
PY
