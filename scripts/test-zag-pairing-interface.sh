#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
view = (root / 'Feather/Views/Settings/Installation/InstallationView.swift').read_text().split('private struct RPPairingView:', 1)[1].split('struct RPPairingDiagnosticsView:', 1)[0]
assert view.count('Button(role: (pairingCore.pairingFileExists || pairingCore.localPairingCleanupPending)') == 1
assert view.count('Label("Pairing File"') == 1
assert view.index('Button(role: (pairingCore.pairingFileExists || pairingCore.localPairingCleanupPending)') < view.index('Label("Pairing File"')
assert '"Forget Local Pairing"' in view and '"Retry Local Cleanup"' in view and '"Pair This iPhone"' in view
assert view.count('\n\t\tSection {') == 4
assert 'Settings App → Privacy & Security → Developer Mode → Pair with Zag Store' in view
assert 'pairingCore.start()' in view and 'try pairingCore.forgetPairing()' in view
assert '.disabled(pairingCore.isRunning)' in view
assert 'Button {\n                        guard let code = ZagPairingCodeNotification.validCode(pin)' in view
assert '.localOnly: true' in view and '.expirationDate: Date().addingTimeInterval(120)' in view
assert '.frame(width: 22, alignment: .center)' in view
assert view.count('ZagPairingIcon().frame(width: 25, height: 25)') == 3
assert 'App-prefs:' not in view and 'prefs:root' not in view and 'openSettingsURLString' not in view
popup = (root / 'Feather/Views/Settings/Installation/ZagLocalPairingConfirmationPopup.swift').read_text()
style = (root / 'Feather/Views/Settings/Installation/ZagInstallationRowLabelStyle.swift').read_text()
guide = (root / 'Feather/Views/Settings/Installation/ZagDeveloperModeGuidanceView.swift').read_text()
assert '.sheet(isPresented: $showUnpairConfirmation, onDismiss: presentCleanupFeedback)' in view
assert 'confirm: confirmLocalCleanup' in view and 'guard let feedback = cleanupFeedback else { return }' in view
assert 'forgetPairing' not in view.split('private func presentCleanupFeedback()', 1)[1].split('private var tunnelVerified', 1)[0]
assert view.count('try pairingCore.forgetPairing()') == 1
assert '.popover(' not in view and 'ZagUnpairConfirmationBubble' not in view
assert 'NBNavigationView("Forget Local Pairing?", displayMode: .inline)' in popup
assert 'NBSheetButton(title: "Forget Local Pairing", style: .prominent)' in popup
assert 'NBSheetButton(title: "Cancel")' in popup
assert 'Image(systemName: "xmark")' in popup and '.accessibilityLabel("Close")' in popup
assert 'Removes local pairing credentials. To fully unpair, also remove Zag Store in iOS Settings.' in popup
assert 'ZagLocalPairingRemoval.systemRemovalInstructions' in popup
assert 'triangle.fill' not in popup and '.popover' not in popup
assert '.safeAreaInset(edge: .bottom' in popup and 'dynamicTypeSize.isAccessibilitySize' in popup
assert '.frame(width: 25, alignment: .center)' in style and 'HStack(spacing: 8)' in style
assert view.count('ZagInstallationRowLabelStyle(') == 5 and 'ZagInstallationRowLabelStyle(tinted: true)' in guide
assert 'ZagDeveloperModeIcon().frame(width: 25, height: 25)' in guide
footer = view.split('Text("Control")', 1)[1].split('\n\t\tSection {', 1)[0]
assert 'systemRemovalInstructions' not in footer
print('PASS: custom sheet reuses existing navigation/glass buttons; no arrow or automatic cleanup on cancellation')
print('PASS: status/control/guidance share one icon column and spacing; permanent instructions deduplicated')
print('PASS: paired/unpaired control precedes file row once, without adding sections')
print('PASS: exact manual instructions and existing actions/trailing indicators retained')
print('PASS: copy is explicit, local-only and expiring; no unsupported Settings shortcut')
PY
