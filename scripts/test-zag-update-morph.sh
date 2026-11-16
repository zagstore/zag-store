#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-update-morph.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# Extract the shared production palette, avoiding unrelated dock dependencies.
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:])
s=(root/'Feather/Views/TabView/Bars/ZagAppsTabIcon.swift').read_text()
palette=s.split('enum ZagSelfUpdateSpectrum {',1)[1].split('/// A single lightweight animated gradient',1)[0]
(work/'Spectrum.swift').write_text('import SwiftUI\nenum ZagSelfUpdateSpectrum {'+palette)
# Only the platform-specific UIKit tint conversion is adapted for host layout tests.
# The actual control and Canvas compile unchanged; spectrum tests use production colours.
(work/'HostTint.swift').write_text('import SwiftUI\nenum ZagWideGamutTint { static func color(hex: String) -> Color { .blue } }')
PY
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" -parse-as-library \
 "$ROOT/Feather/Utilities/ZagUpdateProgressPresentation.swift" \
 "$ROOT/Feather/Views/Settings/ZagUpdateSpectrumSurface.swift" \
 "$ROOT/Feather/Views/Settings/ZagSelfUpdateActionControl.swift" \
 "$WORK/Spectrum.swift" "$WORK/HostTint.swift" "$ROOT/scripts/ZagUpdateMorphRenderingTests.swift" -o "$WORK/tests"
"$WORK/tests"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import subprocess,sys,plistlib
root=Path(sys.argv[1])
def read(p): return (root/p).read_text()
control=read('Feather/Views/Settings/ZagSelfUpdateActionControl.swift')
surface=read('Feather/Views/Settings/ZagUpdateSpectrumSurface.swift')
policy=read('Feather/Utilities/ZagUpdateProgressPresentation.swift')
view=read('Feather/Views/Settings/ZagSelfUpdateStatusView.swift')
coord=read('Feather/Utilities/ZagSelfUpdateCoordinator.swift')
assert control.count('            Button {') == 1
assert control.count('ZagUpdateSpectrumSurface(') == 1
assert control.count('.animation(morphAnimation, value: state.showsProgress)') == 2
assert 'ZagUpdateMorphSpecification.duration' in control and '.timingCurve(' in control
assert 'value: state.fraction' not in control
assert '.id(' not in surface and 'AnimatablePair' not in surface
assert '.onChange(of: progress)' in surface and 'visualProgress.update' in surface
assert '@ObservedObject private var gate4' not in view
assert '@StateObject private var installerPresentation' in view
assert 'ZagUpdateTransferActionControl(' in view
assert 'if case .upgradeSubmitted = gate4.gate4State { return .awaitingHandoff }' in view
assert 'ProgressView(' not in control and '.transition(' not in control
assert '.frame(maxWidth: .infinity, minHeight: 54)' in control
assert '\n        .opacity(' not in surface and 'var animatableData: Double' in surface
assert 'Path(roundedRect: rect, cornerRadius: height / 2)' in surface
assert 'rect.width * fillFraction' in surface
assert 'ZagUpdateControlGeometry.height(slotHeight: size.height' in surface
assert 'TimelineView(.animation(paused: !animates))' in surface
assert 'rendersAsynchronously: false' in surface
assert 'dividingBy: 5' in surface and 'lineWidth: 1.5' in surface
assert 'conicGradient(Self.spectrum' in surface
assert 'private static let flowingSpectrum' in surface
assert 'ZagSelfUpdateSpectrum.colors' in surface
assert '.blur(' not in surface and '.shadow(' not in surface
assert 'ObservableObject' not in surface and '@ObservedObject' not in surface
assert 'ZagUpdateDecorationPolicy.animates' in surface
assert 'minimumInterval: 1' not in surface
assert 'state.offersGuidance' in control and 'state.fraction ?? 1' in control
assert 'View Installation Steps' not in view and 'presentUpdateGuidance' not in view
assert 'Installation and Reopening' not in view and 'showRestartGuidance' not in view
assert 'if showsReopenInstructions && state.offersGuidance' in control
assert 'Text(state.reopenInstruction)' in control
diagnostics=view.split('private var zagDeveloperDiagnostics:',1)[1].split('private var gate4ProgressDisplay:',1)[0]
assert 'Text(updateActionState.guidance)' in diagnostics
assert 'Text(updateActionState.guidance)' not in view.split('    var body: some View {',1)[1]
assert '.alert(' not in control
assert '.hidden()' not in control and 'if let status = state.status' in control
assert '.disabled(' not in control and 'guard !state.showsProgress' in control
assert 'rect.width * (phase - 1)' in surface and 'rect.width * (phase + 1)' in surface
assert 'if amount < 1 { context.fill(fill, with: .color(theme)) }' in surface
pending=view.split('private var updateActionState:',1)[1].split('private func beginUpdate',1)[0]
assert pending.index('handoffState == .reportedComplete') < pending.index('gate4.isGate4Running')
assert pending.count('return .handedOff') == 1
assert 'pendingInstallation != nil && coordinator.handoffState != .reportedComplete && !gate4.isGate4Running && !installBusy' in view
assert 'if case .staged = gate4.gate4State { return .awaitingHandoff }' in pending
assert 'handoffState == .uncertain' in pending
handoff=coord.split('private func performPreparedHandoff(',1)[1].split('/// Explicitly confirmed upgrade-only',1)[0]
assert handoff.index('try await submitStagedUpdateToGate4(') < handoff.index('handoffState = .reportedComplete') < handoff.index('} catch {')
assert 'handoffState = pendingInstallation == nil ? .none : .uncertain' in handoff
assert 'mayReleasePendingRecord(after: progress)' in handoff
assert 'if pendingInstallation != nil { handoffState = .uncertain }' in coord
prepare=coord.split('func prepareSignedUpdate(',1)[1].split('/// Explicit, test-only authenticated',1)[0]
assert prepare.index('preparationState = .signing') < prepare.index('try await signImportedRelease(') < prepare.index('preparationState = .readyForHandoff')
signing=coord.split('func signImportedRelease(',1)[1].split('func validateSignedApp(',1)[0]
assert signing.index('FR.signPackageFile(') < signing.index('try validateSignedApp(signed, release: release)')
assert 'case .uploading(let value), .progress(let value):' in view

assert 'isReleaseAdvance(version: candidate.version' in coord
assert 'isReleaseAdvance(version: release.version' in coord
# The prompt is an explicit test-candidate safeguard, never normal Update Now.
assert view.count('showInstallConfirmation = true') == 1
assert 'Review Beta v2 In-Place Update' in view.split('showInstallConfirmation = true')[0]
assert 'No automatic uninstall or fresh-install fallback will be attempted' in view
assert 'userConfirmedSelfReplacement: true' in view
native=read('RPPairingCore/rust-core/src/lib.rs')
assert 'Do not emit 210 here: transmission is not separately observable.' in native
# No edits to native transport, cryptographic admission, rollback, splash or metadata.
changed=subprocess.check_output(['git','diff','ea191fff','--name-only'],cwd=root,text=True).splitlines()
assert not any(p.startswith(('RPPairingCore/','Feather/RPPairing/')) for p in changed)
assert not any('ManifestVerifier' in p or 'RollbackStore' in p for p in changed)
plistPath='Feather/Resources/Info.plist'
oldPlist=plistlib.loads(subprocess.check_output(['git','show','ea191fff:'+plistPath],cwd=root))
newPlist=plistlib.loads((root/plistPath).read_bytes())
assert newPlist.pop('CADisableMinimumFrameDurationOnPhone') is True
assert newPlist == oldPlist, 'only documented ProMotion opt-in may change in Info.plist'
for p in ['Feather/FeatherApp.swift','Feather/Views/TabView/Bars/ZagCinematicSplashView.swift','Feather/Views/TabView/Bars/ZagSplashAnimationStage.swift']:
 assert p not in changed, p
print('PASS: persistent Canvas morph, original spectrum/rim timing, independent cadence, terminal guidance, callback truth, prompt and security boundaries')
PY
