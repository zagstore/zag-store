#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-account-activity.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import subprocess, sys
root, work = map(Path, sys.argv[1:])
view = (root / 'Feather/Views/TabView/VariedTabbarView.swift').read_text()
profile = view.split('struct ZagProfileToolbarButton:', 1)[1].split('struct ZagGlobalProfileAvatar:', 1)[0]
assert '.sheet(isPresented: $isAccountPresenting, onDismiss:' in profile
assert profile.index('activityHandoff.takeAfterDismissal()') < profile.index('ZagStoreRouter.open(route.url)') < profile.index('onOpenActivity:')
assert 'activityHandoff.request()\n                isAccountPresenting = false' in profile
assert not any(x in profile for x in ['asyncAfter', 'Task.sleep', 'Timer.', 'DispatchQueue'])
account = view.split('struct ZagAccountPopup:', 1)[1]
assert 'Button(action: onOpenActivity)' in account
assert 'AccountDestination.activity' not in account and 'case .activity:' not in account
assert 'TabEnum.view(for: .activity)' not in account
certificates = (root / 'Feather/Views/Settings/Certificates/CertificatesView.swift').read_text()
toolbar = certificates.split('.toolbar {', 1)[1].split('.task {', 1)[0]
assert toolbar.count('.accessibilityLabel("Close")') == 1
assert toolbar.index('Image(systemName: "plus")') < toolbar.index('Image(systemName: "xmark")')
assert 'closeAccount()' in toolbar and 'dismiss()' in toolbar
assert 'destination != .settings && destination != .certificates' in account
settings = (root / 'Feather/Views/Settings/SettingsView.swift').read_text()
assert 'CertificatesView(openedFromSettings: true)' in settings
about = settings.split('private var _aboutRows:', 1)[1].split('private func _directories', 1)[0]
assert 'Text("GitHub")' not in about and '_showFeedback = true' in about
feedback = settings.split('.alert("Send Feedback"', 1)[1].split('Delete Certificate?', 1)[0]
actions = [feedback.index(f'Button("{name}"') for name in ('GitHub', 'Discord', 'Send Email', 'Cancel')]
assert actions == sorted(actions) and 'Choose a method to send feedback:' in feedback
assert settings.index('_socialLinks') < settings.index('ZagInstalledRelease.settingsVersion')
footer = settings.split('private enum SocialLink:', 1)[1].split('private struct ZagLoggingSettingsView', 1)[0]
assert footer.index('case github') < footer.index('case discord')
assert '.foregroundStyle(.primary)' in footer and '.frame(width: 44, height: 44)' in footer
assert 'ZagContinuousSettingsCard(verticalPadding: 8) { _featureRows }' in settings
old = subprocess.check_output(['git', 'show', '0ff5181d:Feather/Views/TabView/VariedTabbarView.swift'], cwd=root, text=True).split('struct ZagAccountPopup:', 1)[1]
normalized = account.replace('    let onOpenActivity: () -> Void\n', '').replace('devices, selfUpdate, settings', 'devices, activity, selfUpdate, settings', 1)
normalized = normalized.replace('Button(action: onOpenActivity) {\n                        Text("Activity").foregroundStyle(.primary)\n                    }', 'NavigationLink(value: AccountDestination.activity) {\n                        Text("Activity")\n                    }', 1)
normalized = normalized.replace('                    case .selfUpdate: ZagSelfUpdateStatusView()', '                    case .activity: TabEnum.view(for: .activity).tint(themeTint)\n                    case .selfUpdate: ZagSelfUpdateStatusView()', 1)
assert account.count('Text("Guest User")') == 1
old = old.replace('Text("Petar Zagorski")', 'Text("Guest User")', 1)
normalized = normalized.replace('destination != .settings && destination != .certificates', 'destination != .settings', 1)
assert normalized == old, 'other Account destinations must be unchanged'
tabs = (root / 'Feather/Views/TabView/TabEnum.swift').read_text()
assert 'case .activity: ZagActivityPage()' in tabs and 'NBNavigationView("Activity")' in tabs
assert 'Activity appeared; probing dictation' in tabs and 'Activity ready' in tabs
old_tabs = subprocess.check_output(['git', 'show', '0ff5181d:Feather/Views/TabView/TabEnum.swift'], cwd=root, text=True)
old_appearance = '.onAppear(perform: probeSystemDictation)'
new_appearance = tabs.split('            .onAppear {\n                #if DEBUG\n                ZagLogger.shared.info("Navigation", "Activity appeared; probing dictation")', 1)
assert len(new_appearance) == 2
# Activity dependencies, initialization, data access and dock view stay untouched.
marker_end = '                ZagLogger.shared.info("Navigation", "Activity ready")\n                #endif\n            }'
remainder = new_appearance[1].split(marker_end, 1)[1]
assert new_appearance[0] + '            ' + old_appearance + remainder == old_tabs
for bar in ['TabbarView', 'ExtendedTabbarView']:
    name = 'Feather/Views/TabView/Bars/' + bar + '.swift'
    assert (root / name).read_text() == subprocess.check_output(['git', 'show', '0ff5181d:' + name], cwd=root, text=True)

hidden = view.split('    private func openHiddenDestination(', 1)[1].split('\n\tprivate func updateDockTint', 1)[0]
standard = (root / 'Feather/Views/TabView/Bars/TabbarView.swift').read_text()
receive = standard.split('.onReceive(NotificationCenter.default.publisher(for: .zagStoreRouteRequested)) { note in', 1)[1].split('\n\t\t}', 1)[0]
extended = (root / 'Feather/Views/TabView/Bars/ExtendedTabbarView.swift').read_text()
assert 'ZagDockConfiguration.tabs.contains(tab)' in extended and 'selectedTab.wrappedValue = route.tab' in extended
# Compile the actual root hidden-route handler and legacy dock notification handler.
(work / 'Host.swift').write_text('''import Foundation
enum TabEnum: String { case discover, sources, library, games, activity, settings }
enum ZagDockConfiguration { static var tabs: [TabEnum] = [.discover, .sources, .library, .games, .activity] }
struct Selection { var wrappedValue: TabEnum = .library }
struct ActivityHost {
    var selectedTab = Selection()
    var creations = 0
    var linkedTab: TabEnum? { didSet { if linkedTab != nil && linkedTab != oldValue { creations += 1 } } }
    mutating func openHiddenDestination(''' + hidden + '''
    mutating func receiveDock(_ note: Notification) {''' + receive + '''
    }
    mutating func route(_ route: ZagStoreRoute) {
        receiveDock(Notification(name: .zagStoreRouteRequested, object: route))
        openHiddenDestination(route)
    }
}
''')
print('PASS: Activity leaves Account navigation; only sheet dismissal routes; other popup destinations and dock factories retained')
PY
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" -parse-as-library "$ROOT/Feather/Utils/ZagStoreRouter.swift" \
    "$ROOT/Feather/Utilities/ZagAccountActivityHandoff.swift" "$WORK/Host.swift" \
    "$ROOT/scripts/ZagAccountActivityNavigationTests.swift" -o "$WORK/tests"
"$WORK/tests"
