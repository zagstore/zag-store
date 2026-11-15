import Foundation

/// Installation-local state, independent of app version and privacy preferences.
enum ZagOnboardingPolicy {
    static let stateKey = "ZagStore.onboardingState"

    static func begin(defaults: UserDefaults, hasExistingData: Bool, domain: [String: Any]) -> Bool {
        if let state = defaults.string(forKey: stateKey) { return state == "pending" }
        // Older builds have no onboarding marker. Preserve their existing experience.
        let existing = hasExistingData || !domain.isEmpty
        defaults.set(existing ? "existing" : "pending", forKey: stateKey)
        return !existing
    }

    static func complete(defaults: UserDefaults = .standard) {
        defaults.set("completed", forKey: stateKey)
    }

    /// Capture before the app's managers create stores or write defaults.
    static func beginInstallation() -> Bool {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let manager = FileManager.default
        let hasData = [FileManager.SearchPathDirectory.applicationSupportDirectory, .documentDirectory].contains { kind in
            guard let directory = manager.urls(for: kind, in: .userDomainMask).first,
                  let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
            return contents.contains { $0.lastPathComponent != "Inbox" && $0.lastPathComponent != ".DS_Store" }
        }
        return begin(defaults: defaults, hasExistingData: hasData, domain: domain)
    }
}
