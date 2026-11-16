#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-transfer-presentation.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# Host tint and palette adapters, identical to the existing renderer harness.
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:])
s=(root/'Feather/Views/TabView/Bars/ZagAppsTabIcon.swift').read_text()
palette=s.split('enum ZagSelfUpdateSpectrum {',1)[1].split('/// A single lightweight animated gradient',1)[0]
(work/'Adapters.swift').write_text('import SwiftUI\nenum ZagSelfUpdateSpectrum {'+palette+'\nenum ZagWideGamutTint { static func color(hex: String) -> Color { .blue } }')
PY
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" -parse-as-library \
 "$ROOT/Feather/Utilities/ZagUpdateProgressPresentation.swift" \
 "$ROOT/Feather/Utilities/ZagUpdateTransferPresentation.swift" \
 "$ROOT/Feather/Views/Settings/ZagUpdateInstallerPresentation.swift" \
 "$ROOT/Feather/Views/Settings/ZagSelfUpdateActionControl.swift" \
 "$ROOT/Feather/Views/Settings/ZagUpdateSpectrumSurface.swift" \
 "$ROOT/scripts/ZagUpdateTransferCoreStub.swift" "$WORK/Adapters.swift" \
 "$ROOT/scripts/ZagUpdateTransferPresentationTests.swift" -o "$WORK/tests"
"$WORK/tests"

python3 - "$ROOT" <<'PYTEST'
from pathlib import Path
import sys
root=Path(sys.argv[1])
view=(root/'Feather/Views/Settings/ZagSelfUpdateStatusView.swift').read_text()
bridge=(root/'Feather/Views/Settings/ZagUpdateInstallerPresentation.swift').read_text()
surface=(root/'Feather/Views/Settings/ZagUpdateSpectrumSurface.swift').read_text()
assert '@ObservedObject private var gate4' not in view
assert '@StateObject private var installerPresentation' in view
assert '@Published private(set) var stage:' in bridge
assert 'let progress = ZagUpdateTransferPresentation()' in bridge
assert 'if stage != next { stage = next }' in bridge
assert 'progress.objectWillChange' not in bridge
assert '@ObservedObject var progress:' in bridge
assert 'ZagSelfUpdateActionControl(state: presentedState' in bridge
assert '.id(' not in bridge and '.id(' not in surface
assert 'var animatableData: Double' in surface
assert 'set { morph = newValue }' in surface
assert 'displayedProgress:' in surface and 'visualProgress.value(at:' in surface
assert 'truncatingRemainder(dividingBy: 5)' in surface
assert 'if case .upgradeSubmitted = gate4.gate4State { return .awaitingHandoff }' in view
print('PASS: stage-only screen observation, stable child/gradient identity, independent progress and no premature submission success')
PYTEST
