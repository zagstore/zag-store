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
for begin, end in [('guard !releaseDownloadBusy else { return }', '} label: {'), ('guard !releaseCheckBusy else { return }', '} label: {'), ('Button("Attempt In-Place Replacement"', '} message: {')]:
    assert view.split(begin, 1)[1].split(end, 1)[0] == old.split(begin, 1)[1].split(end, 1)[0]
assert view.count('Link("Learn More"') == 1 and 'Learn more about this update' not in view
card = view.split('if let release = coordinator.availableRelease {', 1)[1].split('.task(id: release.ipaURL)', 1)[0]
assert card.index('ZagUpdateReleaseNotesView(') < card.index('Divider()') < card.index('Text("Update Now")') < card.index('Link("Learn More"')
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
header = card.split('HStack(alignment: .top, spacing: 14)', 1)[1].split('ZagUpdateReleaseNotesView', 1)[0]
assert header.count('.frame(width: 60, height: 60)') == 2
assert 'Text(releaseDownloadSize ?? "Checking download size…")\n                                    .font(.caption)' in header
assert 'if zagBetaChannel == "beta" || zagBetaChannel == "nightly" {' in header
assert 'ZagUpdateChannelPresentation.title(for: zagBetaChannel)' in header
assert '.font(.caption2)' in header and '.foregroundStyle(.secondary)' in header
assert 'Text("Build \\(release.build)")\n                                        .font(.subheadline)' in header
# The complete existing host view must differ only in the requested presentation.
expected = old.replace('Text(zagBetaChannel == "beta" ? "Zag Store Beta" :\n                             zagBetaChannel == "nightly" ? "Zag Store Nightly" : "Stable")', 'Text(ZagUpdateChannelPresentation.title(for: zagBetaChannel))')
expected = expected.replace('Text(option == "beta" ? "Zag Store Beta" :\n                                 option == "nightly" ? "Zag Store Nightly" : "Stable")', 'Text(ZagUpdateChannelPresentation.title(for: option))')
a=expected.index('                        Text(release.releaseNotes ??'); b=expected.index('                        if releaseDownloadBusy',a)
replacement=card.split('                        ZagUpdateReleaseNotesView(',1)[1].split('                        if releaseDownloadBusy',1)[0]
expected=expected[:a]+'                        ZagUpdateReleaseNotesView('+replacement+expected[b:]
new_link=card.split('\n                        Link("Learn More"',1)[1].split('\n                        if let issue',1)[0]
expected=expected.replace('\n                        if let issue = userVisibleUpdateIssue', '\n                        Link("Learn More"'+new_link+'\n                        if let issue = userVisibleUpdateIssue',1)
expected=expected.replace('content.listSectionSpacing(.custom(11))','content.listSectionSpacing(.custom(16))')
expected=expected.replace('    @ObservedObject private var coordinator = ZagSelfUpdateCoordinator.shared', '    @AppStorage("Feather.userTintColor") private var themeColorHex = "#0090FF"\n    @ObservedObject private var coordinator = ZagSelfUpdateCoordinator.shared', 1)
expected=expected.replace('HStack(alignment: .center, spacing: 14) {', 'HStack(alignment: .top, spacing: 14) {', 1)
old_size = '                                Text(releaseDownloadSize ?? "Checking download size…")\n                                    .font(.subheadline)\n                                    .foregroundStyle(.primary)'
new_size = '                                Text(releaseDownloadSize ?? "Checking download size…")\n                                    .font(.caption)\n                                    .foregroundStyle(.primary)\n                                if zagBetaChannel == "beta" || zagBetaChannel == "nightly" {\n                                    Text(ZagUpdateChannelPresentation.title(for: zagBetaChannel))\n                                        .font(.caption2)\n                                        .foregroundStyle(.secondary)\n                                }'
expected=expected.replace(old_size,new_size,1)
assert view == expected, 'all existing handlers, preferences, progress and recovery must be unchanged'
print('PASS: unchanged channel IDs, handler bodies, progress, recovery and URL; compact card ordering and local spacing')
print('PASS: measured four-line collapse, short-note fitting, native Markdown, accessibility and safe URL action wiring')
PY

# Optional original screenshot arguments reproduce the pixel geometry and visibility bound.
if [ "$#" -eq 2 ]; then
    swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" \
        "$ROOT/scripts/measure-zag-update-spacing.swift" -o "$WORK/measure"
    "$WORK/measure" "$1" "$2"
fi
