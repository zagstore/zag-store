#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import subprocess, sys
root=Path(sys.argv[1])
def read(p): return (root/p).read_text()
coord=read('Feather/Utilities/ZagSelfUpdateCoordinator.swift')
proof=coord.split('func reconcileOnLaunch()',1)[1].split('func acknowledgePostUpdateMessageDisplayed',1)[0]
for clause in ['candidate.version == currentVersion','candidate.build == currentBuild','sha256InBackground','caseInsensitiveCompare(expectedHash) == .orderedSame','caseInsensitiveCompare(originalHash) != .orderedSame','pendingInstallation?.startedAt == pending.startedAt']:
    assert clause in proof, clause
assert proof.index('caseInsensitiveCompare(originalHash) != .orderedSame') < proof.index('postUpdateMessageStore.record(')
assert 'var releaseChannel: String? = nil' in coord
assert 'activeDownloadToken == token' in coord
package=read('Feather/Utilities/ZagPackageIntegrity.swift')
assert 'Task.detached(priority: .utility)' in package and 'Task.checkCancellation()' in package
assert 'expectedContentLength' in package and 'ZagUpdateProgressSampler' in package
view=read('Feather/Views/Settings/ZagSelfUpdateStatusView.swift')
assert 'IPA verified - waiting for iOS handoff' in view
assert 'IPA verified — waiting for iOS handoff' not in view
assert read('Feather/Utilities/ZagUpdateProgressPresentation.swift').count('Update successful. Reopen Zag Store to complete.') == 1
assert 'coordinator.installedIdentityVerified' in view
assert 'presentUpdateGuidance' not in view and 'showRestartGuidance' not in view
assert 'reopenInstruction' not in read('Feather/Views/Settings/ZagSelfUpdateActionControl.swift')
for p in ['Feather/Views/TabView/Bars/ZagCinematicSplashView.swift','Feather/Views/TabView/Bars/ZagSplashAnimationStage.swift']:
    s=read(p)
    assert 'signatureMessage?.tokens ?? ["Sideloading", "and", "beyond."]' in s
    assert 'signatureCompletion' in s and 'window != nil' in s
    assert 'UIApplication.shared.applicationState == .active' in s
    assert 'onPostUpdateMessageDisplayed?(message)' in s
    old=subprocess.check_output(['git','show','30741eaf:'+p],cwd=root,text=True)
    # Original timings, artwork identifiers, sound resources and animation values
    # must remain verbatim; caption geometry can adapt to the new text.
    for line in old.splitlines():
        t=line.strip()
        if any(key in t for key in ['duration =','beginTime =','AVAudioPlayer(', 'Bundle.main.url(', 'UIImage(named:']):
            assert line in s, (p,t)
delegate=read('Feather/Views/TabView/Bars/ZagSplashSignatureCompletion.swift')
assert 'guard finished else { return }' in delegate
host=read('Feather/FeatherApp.swift')
assert 'guard opacity > 0.5, !dismissed, !exitRequested, !videoFadeStarted' in host
for p in ['Feather/Views/Settings/ZagSelfUpdateActionControl.swift','Feather/Views/Settings/ZagSelfUpdateStatusView.swift']:
    s=read(p)
    assert 'exit(0)' not in s and 'abort()' not in s and 'suspend)' not in s
# Cryptographic admission and rollback policy implementations are not edited.
changed=subprocess.check_output(['git','diff','30741eaf','--name-only'],cwd=root,text=True).splitlines()
assert not any('ManifestVerifier' in p or 'RollbackStore' in p or 'RetryPolicy' in p for p in changed)
print('PASS: installed-executable proof, phase truth, safe restart, completed reveal acknowledgement, unchanged splash timing and security policies')
PY
