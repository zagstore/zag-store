#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-update-presentation.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" -parse-as-library \
    "$ROOT/Feather/Utilities/ZagUpdateReleaseNotes.swift" "$ROOT/scripts/ZagUpdatePresentationTests.swift" -o "$WORK/tests"
"$WORK/tests"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import subprocess, sys
root = Path(sys.argv[1])
path = 'Feather/Views/Settings/ZagSelfUpdateStatusView.swift'
view = (root / path).read_text()
old = subprocess.check_output(['git', 'show', 'ea0b5dbe:' + path], cwd=root, text=True)
assert 'Zag Store Beta' not in view and 'Zag Store Nightly' not in view
assert 'ForEach(["off", "beta", "nightly"]' in view
# Discovery and the explicit diagnostic-only install dialog retain their handlers.
for begin, end in [('guard !releaseCheckBusy else { return }', '} label: {'), ('Button("Attempt In-Place Replacement"', '} message: {')]:
    assert view.split(begin, 1)[1].split(end, 1)[0] == old.split(begin, 1)[1].split(end, 1)[0]
normal = view.split('private func beginUpdate(', 1)[1].split('    var body: some View {', 1)[0]
assert 'showInstallConfirmation = true' not in normal
assert normal.index('chooseForSigning()') < normal.index('prepareSignedUpdate(') < normal.index('installVerifiedSignedUpdate(')
assert 'userConfirmedSelfReplacement: true' in normal
assert 'coordinator.beginUserUpdateOperation()' in normal and 'coordinator.finishUserUpdateOperation()' in normal
assert 'guard channel == ZagSelfUpdateCoordinator.UpdateChannel.selected' in normal
assert view.count('Link("Learn More"') == 1 and 'Learn more about this update' not in view
card = view.split('if let release = coordinator.availableRelease {', 1)[1].split('.task(id: release.ipaURL)', 1)[0]
assert card.index('ZagUpdateReleaseNotesView(') < card.index('Divider()') < card.index('ZagUpdateTransferActionControl(') < card.index('Link("Learn More"')
assert 'https://github.com/zagorskey/zag-store-releases/releases' in card
assert '.frame(maxWidth: .infinity, minHeight: 44)' in card
assert 'content.listSectionSpacing(.custom(16))' in view
reference = (root / 'docs/validation/software-update-spacing.md').read_text()
assert '| Background gap | 48 px | 24 px |' in reference
assert '| Effective visible gap | **16 pt** | **8 pt** |' in reference
assert '| Dimensions | 1290 × 2796 px | 1290 × 2796 px |' in reference
assert '16 × 3 = 48 target pixels' in reference
assert 765 - 717 == 48 and (765 - 717) / 3 == 16
assert 852 - 828 == 24 and (852 - 828) / 3 == 8
notes = (root / 'Feather/Views/Settings/ZagUpdateReleaseNotesView.swift').read_text()
assert 'blockContent(first, lineLimit: showsFullContent ? nil : 4)' in notes and 'Text("Line\\nLine\\nLine\\nLine")' in notes
assert '@State private var expanded = false' in notes and '.onAppear { expanded = false }' in notes
assert 'if canExpand {' in notes and 'return full > fourLines + 0.5' in notes
assert 'ScrollView' not in notes and '.accessibilityValue(expanded ? "Expanded" : "Collapsed")' in notes
assert '.accessibilityHidden(true)' in notes and '.systemAction : .discarded' in notes
assert 'Text(expanded ? "less" : "more")' in notes
assert '.frame(maxWidth: .infinity, alignment: .trailing)' in notes
assert '.frame(minWidth: 44, minHeight: 44, alignment: .trailing)' in notes
assert '.foregroundStyle(ZagWideGamutTint.color(hex: themeColorHex))' in notes
assert '@AppStorage("Feather.userTintColor")' in notes and '@AppStorage("Feather.userTintColor")' in view
assert '.foregroundStyle(ZagWideGamutTint.color(hex: themeColorHex))' in card
assert '.tint(ZagWideGamutTint.color(hex: themeColorHex))' in card
assert 'withAnimation' not in notes and '.transition(' not in notes
assert 'Text(document.preview)' not in notes
assert 'if let first = blocks.first {' in notes and 'ForEach(Array(blocks.dropFirst()))' in notes
assert notes.index('blockContent(first, lineLimit:') < notes.index('if showsFullContent {')
assert 'transaction.disablesAnimations = true' in notes
assert 'guard value != measurements else { return }' in notes
assert '.lineLimit(lineLimit)' in notes
header = card.split('HStack(alignment: .center, spacing: 14)', 1)[1].split('ZagUpdateReleaseNotesView', 1)[0]
assert header.count('.frame(width: 60, height: 60)') == 2
assert 'Text(releaseDownloadSize ?? "Checking download size…")\n                                    .font(.caption)' in header
assert 'if zagBetaChannel == "beta" || zagBetaChannel == "nightly" {' in header
assert 'ZagUpdateChannelPresentation.title(for: zagBetaChannel)' in header
assert '.font(.caption2)' in header and '.foregroundStyle(.secondary)' in header
assert 'Text("Build \\(release.build)")\n                                        .font(.subheadline)' in header
# The local header/notes/layout behavior is preserved by the assertions above.
# Automatic-download and channel controls remain byte-identical to the approved UI.
approved = subprocess.check_output(['git', 'show', '30741eaf:' + path], cwd=root, text=True)
assert view.split('private struct ZagStoreUpdateAutomaticPreferencesView:', 1)[1] == approved.split('private struct ZagStoreUpdateAutomaticPreferencesView:', 1)[1]
control = (root / 'Feather/Views/Settings/ZagSelfUpdateActionControl.swift').read_text()
assert control.count('            Button {') == 1
assert control.count('ZagUpdateSpectrumSurface(') == 1
assert '.frame(maxWidth: .infinity, minHeight: 54)' in control
assert 'ProgressView(' not in control
assert 'morph: state.showsProgress ? 1 : 0' in control
assert 'reduceMotion ? nil' in control and 'ZagUpdateMorphSpecification.duration' in control
assert 'value: state.fraction' not in control
assert 'Shows short manual steps below' in control and 'Cannot close or restart the app' in control
celebration = view.split('private var verifiedUpdateCelebration:', 1)[1].split('private var gate4ProgressTitle:', 1)[0]
assert 'Update successful. Reopen Zag Store to complete.' in (root / 'Feather/Utilities/ZagUpdateProgressPresentation.swift').read_text()
assert 'ZagSelfUpdateActionControl(state: .confirmed)' in celebration
assert 'presentUpdateGuidance' not in view
assert 'coordinator.installedIdentityVerified' in view.split('private var verifiedReplacementKey:', 1)[1].split('private var shouldCelebrateVerifiedReplacement:', 1)[0]
assert 'IPA verified - waiting for iOS handoff' in view
assert 'IPA verified — waiting for iOS handoff' not in view
print('PASS: unchanged channel IDs, handler bodies, progress, recovery and URL; compact card ordering and local spacing')
print('PASS: measured four-line collapse, short-note fitting, native Markdown, accessibility and safe URL action wiring')
PY

# Optional original screenshot arguments reproduce the pixel geometry and visibility bound.
if [ "$#" -eq 2 ]; then
    swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" \
        "$ROOT/scripts/measure-zag-update-spacing.swift" -o "$WORK/measure"
    "$WORK/measure" "$1" "$2"
fi
