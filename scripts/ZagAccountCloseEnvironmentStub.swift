import SwiftUI

// The account sheet's close action (defined in SettingsView.swift), for the
// simulator harnesses that compile Software Update's views on their own.
private struct ZagAccountCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var zagAccountClose: (() -> Void)? {
        get { self[ZagAccountCloseKey.self] }
        set { self[ZagAccountCloseKey.self] = newValue }
    }
}
