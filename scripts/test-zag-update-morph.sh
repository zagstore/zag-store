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
 "$ROOT/Feather/Views/Common/ZagNumericTextTransition.swift" \
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
# Label (carrying the arrival tracker) and surface share one transaction and curve.
assert control.count('.animation(morphAnimation, value: state.showsProgress)') == 2
assert 'disablesAnimations = true' not in control
assert 'ZagAnimationArrival(value: state.showsProgress ? 1 : 0)' in control
assert 'ZagUpdateMorphSpecification.duration' in control and '.timingCurve(' in control
assert 'value: state.fraction' not in control
assert '.id(' not in surface and 'AnimatablePair' not in surface
assert '.onChange(of: progress)' in surface and 'visualProgress.update' in surface
assert '@ObservedObject private var gate4' not in view
assert '@StateObject private var installerPresentation' in view
assert 'ZagUpdateTransferActionControl(' in view
assert '.awaitingHandoff' not in view and '.confirmed' not in view
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
assert 'state.isActionable' in control and 'state.fraction ?? 1' in control
assert 'View Installation Steps' not in view and 'presentUpdateGuidance' not in view
assert 'Installation and Reopening' not in view and 'showRestartGuidance' not in view
assert 'showsReopenInstructions' not in control and 'reopenInstruction' not in control and 'reopenInstruction' not in policy
assert 'App Switcher' not in control
assert 'App Switcher' not in policy.split('var guidance: String {',1)[0]  # diagnostics-only text stays
diagnostics=view.split('private var zagDeveloperDiagnostics:',1)[1].split('private var gate4ProgressDisplay:',1)[0]
assert 'Text(updateActionState.guidance)' in diagnostics
assert 'Text(updateActionState.guidance)' not in view.split('    var body: some View {',1)[1]
assert '.alert(' not in control
# Status line: revealed after tracked geometry arrival, never on a guessed delay.
assert 'morphArrived(' in control and 'revealIfReady(pause: ZagUpdateStatusTiming.pauseAfterMorph)' in control
assert control.count('asyncAfter') == 1 and 'deadline: .now() + pause' in control
assert 'ZagUpdateMorphSpecification.duration +' not in control and 'Task.sleep' not in control
assert 'expected == generation' in control and 'generation += 1' in control
assert 'withAnimation(.easeIn(duration: ZagUpdateStatusTiming.fadeOut))' in control
assert 'withAnimation(.easeOut(duration: ZagUpdateStatusTiming.fadeIn))' in control
assert '.offset(' not in control and '.scaleEffect(' not in control and '.move(' not in control
assert 'line.isSameStage(as: shownLine)' in control
assert '.id(shownLine.message)' in control
# Reduce Motion: no animation to observe, so arrival is reported directly; same-stage
# percentages never restart the choreography; deferred work never reads stale `state`.
assert 'if morphing && morphAnimation == nil { morphArrived(target.showsProgress) }' in control
assert '.onChange(of: ZagStatusTarget(' in control and control.count('.onChange(of:') == 1
choreo=control.split('// MARK: Choreography',1)[1].split('private struct ZagStatusTarget',1)[0]
assert 'state.' not in choreo
# Percentages: one shared digit-roll technique for Sources and the update line.
numeric=read('Feather/Views/Common/ZagNumericTextTransition.swift')
assert '.contentTransition(.numericText(value: Double(value)))' in numeric and 'reduceMotion' in numeric
assert 'ZagNumericTextTransition(value: totalApps)' in read('Feather/Views/Sources/SourcesView.swift')
assert 'ZagAppCountTransition' not in read('Feather/Views/Sources/SourcesView.swift')
assert 'ZagNumericTextTransition(value: line.percent ?? 0)' in control and '.monospacedDigit()' in control
assert 'contentTransition' not in surface
# Success green: one gate, exact website palette, no generic system green.
assert 'success: state.showsSuccess' in control and 'var showsSuccess: Bool { self == .handedOff }' in policy
import re
system_green=re.compile(r'(?<![\w$)\]])\.green\b|Color\.green|UIColor\.systemGreen')
assert not any(system_green.search(x) for x in (surface, control, policy))
assert 'ZagUpdateSuccessPalette.stops' in surface and 'Color(.sRGB' in surface
assert 'ZagUpdateSuccessWave.layerMinX' in surface and 'ZagUpdateSuccessWave.crestOpacity' in surface
# Update Now starts the update; only the success capsule completes, through the
# dedicated, owner-authorised exit path. No crash, abort or private API anywhere.
completion=read('Feather/Utilities/ZagUpdateCompletion.swift')
assert 'var isActionable: Bool { self == .idle }' in policy
for forbidden in ['exit(', 'suspend', 'perform(NSSelectorFromString', 'abort()', 'fatalError(', 'kill(']:
    assert forbidden not in control and forbidden not in policy, forbidden
for forbidden in ['suspend', 'NSSelectorFromString', 'abort()', 'fatalError(', 'kill(', 'raise(', 'preconditionFailure(']:
    assert forbidden not in completion, forbidden
assert completion.count('\n        exit(0)\n') == 1 and completion.count('exit(') == completion.count('exit(0)') and 'UserDefaults.standard.synchronize()' in completion
assert 'actionState == .handedOff && handoff.isSuccessfulHandoff && pendingRecorded' in completion
assert 'acknowledgePostUpdateMessage' not in completion and 'postUpdateMessage' not in completion and 'ZagPostUpdateMessageStore' not in completion  # never consumes the splash
assert 'state.showsSuccess && complete != nil && settledMorph == state.showsProgress && lineVisible && !completionRequested' in control
assert 'completionRequested = true' in control
assert '.sheet(' not in control and '.popover(' not in control and '.confirmationDialog(' not in control
assert '.hidden()' not in control and 'if let shownLine' in control
assert '.disabled(' not in control and '.allowsHitTesting(actionable)' in control
assert 'rect.width * (phase - 1)' in surface and 'rect.width * (phase + 1)' in surface
assert 'if amount < 1 { context.fill(fill, with: .color(theme)) }' in surface
pending=view.split('private var updateActionState:',1)[1].split('private func beginUpdate',1)[0]
assert '.pendingAttempt(handoff: coordinator.handoffState,' in pending
derive=policy.split('static func pendingAttempt(',1)[1].split('\n    }\n',1)[0]
assert derive.index('if handoff.isSuccessfulHandoff') < derive.index('handoff == .uncertain') < derive.index('if installerRunning')
assert derive.count('return .handedOff') == 1
assert 'pendingInstallation != nil && !coordinator.handoffState.isSuccessfulHandoff && !gate4.isGate4Running && !installBusy' in view
# Busy until the coordinator records the outcome; no view-level reading of 209/210.
assert 'gate4.gate4State { return' not in pending
assert 'return .progress(message: preparingMessage, fraction: nil)' in derive
handoff=coord.split('private func performPreparedHandoff(',1)[1].split('/// Explicitly confirmed upgrade-only',1)[0]
assert handoff.index('try await submitStagedUpdateToGate4(') < handoff.index('handoffState = .reportedComplete') < handoff.index('} catch {')
# Verified staging (209) is recorded only for the attempt in flight.
assert handoff.index('handoffState = .waiting') < handoff.index('guard let self, self.handoffState == .waiting else { return }') < handoff.index('self.handoffState = .stagedOnDevice')
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
# The native exchange reports 210 (written) and 211 (installd's first reply) as
# diagnostics only; success stays verified staging (209), which needs no reply
# from iOS because a self-update replaces the process that would receive it.
upgrade=native.split('async fn run_self_upgrade<',1)[1].split('\n}\n',1)[0]
assert upgrade.index('connection.send_frame(frame).await?') < upgrade.index('event(210,') < upgrade.index('connection.read_bytes(4)') < upgrade.index('event(211,')
assert 'tokio::time' not in upgrade and 'sleep' not in upgrade
core_src=open('Feather/RPPairing/ZagRPPairingCore.swift').read()
c209=core_src.split('\t\tcase 209:',1)[1].split('\t\tcase 210:',1)[0]
assert 'gate4Staged?()' in c209 and core_src.count('gate4Staged?()') == 1
assert 'case 211' not in core_src and 'Acknowledg' not in coord
# No edits to cryptographic admission, rollback or metadata; the only native
# change is the self-update Upgrade exchange in lib.rs.
changed=subprocess.check_output(['git','diff','ea191fff','--name-only'],cwd=root,text=True).splitlines()
assert {p for p in changed if p.startswith('RPPairingCore/')} <= {'RPPairingCore/rust-core/src/lib.rs'}
# Swift core changes are limited to publication cadence and the 209 hook.
assert {p for p in changed if p.startswith('Feather/RPPairing/')} <= {
 'Feather/RPPairing/ZagRPPairingCore.swift','Feather/RPPairing/ZagGate4PublicationPolicy.swift'}
core=read('Feather/RPPairing/ZagRPPairingCore.swift')
for invariant in ['gate4Completion?(.success(()))','ZagRPPairingFailure.classify(message, installationStarted: installationStarted)',
                  'gate4AttemptEvents.append(ZagGate4Event(code: code, message: message))','gate4Progress?(percent)']:
 assert invariant in core, invariant
assert not any('ManifestVerifier' in p or 'RollbackStore' in p for p in changed)
plistPath='Feather/Resources/Info.plist'
oldPlist=plistlib.loads(subprocess.check_output(['git','show','ea191fff:'+plistPath],cwd=root))
newPlist=plistlib.loads((root/plistPath).read_bytes())
assert newPlist.pop('CADisableMinimumFrameDurationOnPhone') is True
assert newPlist == oldPlist, 'only documented ProMotion opt-in may change in Info.plist'
# FeatherApp may differ only by the pairing launch fix (docs/validation/pairing-launch-offline.md).
oldApp=subprocess.check_output(['git','show','ea191fff:Feather/FeatherApp.swift'],cwd=root,text=True)
newApp=(root/'Feather/FeatherApp.swift').read_text()
for added in ['\t\t\t\t\t.zagPairingRepairPrompt()\n',
              '            // Connection status refreshes on its own; a reconnect re-checks\n',
              '            // pairing once if the last check could not reach the device.\n',
              '            .onReceive(ZagLocalVPNMonitor.shared.$model.map(\\.tunnel).removeDuplicates()) { tunnel in\n',
              '                if tunnel == .operational { launch.connectionAvailable() }\n            }\n']:
    assert newApp.count(added)==1, added
    newApp=newApp.replace(added,'',1)
assert newApp == oldApp, 'FeatherApp changed beyond the pairing launch fix'
# The splash may differ only by the post-update release group's bold weight.
for p in ['Feather/Views/TabView/Bars/ZagCinematicSplashView.swift','Feather/Views/TabView/Bars/ZagSplashAnimationStage.swift']:
 restored=(root/p).read_text().replace('        // The motto ends semibold; an update\'s release group is bold.\n','').replace('signatureMessage == nil ? .semibold : .bold]','.semibold]').replace('[.light, .ultraLight, .bold]','[.light, .ultraLight, .semibold]')
 assert restored == subprocess.check_output(['git','show','ea191fff:'+p],cwd=root,text=True), p
print('PASS: persistent Canvas morph, original spectrum/rim timing, independent cadence, terminal guidance, callback truth, prompt and security boundaries')
PY
