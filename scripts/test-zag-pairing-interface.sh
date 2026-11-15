#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
import subprocess
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
guide = (root / 'Feather/Views/Settings/Installation/ZagDeveloperModeGuidanceView.swift').read_text()
assert '.sheet(isPresented: $showUnpairConfirmation, onDismiss: presentCleanupFeedback)' in view
assert 'confirm: confirmLocalCleanup' in view and 'guard let feedback = cleanupFeedback else { return }' in view
assert 'forgetPairing' not in view.split('private func presentCleanupFeedback()', 1)[1].split('private var tunnelVerified', 1)[0]
assert view.count('try pairingCore.forgetPairing()') == 1
assert '.popover(' not in view and 'ZagUnpairConfirmationBubble' not in view
assert 'ZagRemovalConfirmationSheet(' in popup
library = (root / 'Feather/Views/Library/LibraryView.swift').read_text()
assert 'ZagRemovalConfirmationSheet(' in library
assert 'NBNavigationView' not in popup and 'NBSheetButton' not in popup
assert 'xmark' not in popup and 'systemRemovalInstructions' not in popup
assert 'Removes local pairing credentials. To fully unpair, also remove Zag Store in iOS Settings.' in popup
assert 'VStack(spacing: 10)' in popup
assert popup.count('Color(uiColor: .tertiarySystemFill)') == 2
assert popup.count('RoundedRectangle(cornerRadius: 26, style: .continuous)') == 2
assert popup.count('.frame(minHeight: 52)') == 2
assert '.foregroundStyle(.red)' in popup and '.height(contentHeight)' in popup
assert '.padding(.horizontal, 20)' in popup and '.padding(.top, 24)' in popup and '.padding(.bottom, 8)' in popup
assert '.presentationDragIndicator(.visible)' in popup
assert 'dynamicTypeSize > .large' not in popup and '[.large]' not in popup
assert '.fixedSize(horizontal: false, vertical: true)' in popup
assert 'geometry.size.height' in popup and 'contentHeight = height' in popup
assert '.scrollBounceBehavior(.basedOnSize)' in popup
assert '.presentationBackground(.ultraThinMaterial)' in popup
# Inspect actual presentation closures, not just the shared content implementation.
pairing_site = view.split('.sheet(isPresented: $showUnpairConfirmation', 1)[1].split('\n\t\t\tHStack', 1)[0]
apps_site = library.split('.sheet(item: $_pendingRemoveApp)', 1)[1].split('.sheet(item: $_selectedInfoAppPresenting)', 1)[0]
for site in [pairing_site, apps_site]:
    assert '.modifier(ZagRemovalSheetPresentation())' in site
# The two presentation sites are the only edits to either host view.
for name in ['Feather/Views/Settings/Installation/InstallationView.swift', 'Feather/Views/Library/LibraryView.swift']:
    current = (root / name).read_text()
    previous = subprocess.check_output(['git', 'show', '32647357:' + name], cwd=root, text=True)
    assert current.replace('                .modifier(ZagRemovalSheetPresentation())\n', '') == previous

assert '.presentationCornerRadius' not in popup  # same native rounded sheet geometry as Apps
assert '.ignoresSafeArea' not in popup and '.frame(maxHeight: .infinity)' not in popup
assert 'ZagInstallationRowLabelStyle(' not in view and 'ZagInstallationRowLabelStyle(' not in guide
assert '.labelStyle(.titleAndIcon)' in view and '.labelStyle(.titleAndIcon)' in guide
assert 'DisclosureGroup(isExpanded: $expanded)' in guide and '} label: {' in guide
assert 'Text(step)' in guide and '.alignmentGuide(.leading) { $0[.trailing] + numberSpacing }' in guide
assert '.padding(.leading, columns.offset)' in guide
assert 'return label - content' in guide
assert '.accessibilityLabel("\\(index + 1). \\(step)")' in guide
assert '.frame(width: 22, alignment: .center)' in guide
assert '.position(x: geometry.size.width - 11, y: geometry[anchor].midY)' in guide
assert '.allowsHitTesting(false)' in guide and '.accessibilityHidden(true)' in guide
assert '.tint(.clear)' in guide and '.tint(Color(hex: themeColorHex))' in guide
for competing in ['disclosureGroupStyle', 'withAnimation', '.animation(', '.transition(', 'if expanded {']:
    assert competing not in guide
# Only the local pairing labels change; Apps shared content/presentation are identical.
prior_popup = subprocess.check_output(['git', 'show', 'fe05fb61:Feather/Views/Settings/Installation/ZagLocalPairingConfirmationPopup.swift'], cwd=root, text=True)
assert popup == prior_popup.replace('title: "Forget Local Pairing?"', 'title: "Forget Local Pairing"').replace('destructiveTitle: "Forget Local Pairing"', 'destructiveTitle: "Forget"')
assert library == subprocess.check_output(['git', 'show', 'fe05fb61:Feather/Views/Library/LibraryView.swift'], cwd=root, text=True)
# Restore every native Control label modifier against the actual pre-regression source.
baseline = subprocess.check_output(['git', 'show', '57664bf4:Feather/Views/Settings/Installation/InstallationView.swift'], cwd=root, text=True)
start = 'Button(role: (pairingCore.pairingFileExists || pairingCore.localPairingCleanupPending)'
# Control label and native frame/contentShape before the presentation modifier.
current_control = view.split(start, 1)[1].split('.sheet(', 1)[0]
original_control = baseline.split(start, 1)[1].split('.popover(', 1)[0]
assert "".join(current_control.split()) == "".join(original_control.split())
# File and both export branches also retain the original native row tree.
current_files = view.split('Label("Pairing File"', 1)[1].split('if case .pin', 1)[0]
original_files = baseline.split('Label("Pairing File"', 1)[1].split('if case .pin', 1)[0]
assert "".join(current_files.split()) == "".join(original_files.split())

for forbidden in ['.listRowInsets', '.listRowSeparator', '.defaultMinListRowHeight']:
    assert forbidden not in view
assert 'ZagLocalPairingRemoval.systemRemovalInstructions' in view
assert 'ZagDeveloperModeIcon().frame(width: 25, height: 25)' in guide
footer = view.split('Text("Control")', 1)[1].split('\n\t\tSection {', 1)[0]
assert 'systemRemovalInstructions' not in footer
print('PASS: pairing and Apps share the extracted Remove App sheet; no arrow or automatic cleanup on cancellation')
print('PASS: Control native geometry restored; Status/guidance use native Label columns; permanent instructions deduplicated')
print('PASS: paired/unpaired control precedes file row once, without adding sections')
print('PASS: exact manual instructions and existing actions/trailing indicators retained')
print('PASS: copy is explicit, local-only and expiring; no unsupported Settings shortcut')
PY
