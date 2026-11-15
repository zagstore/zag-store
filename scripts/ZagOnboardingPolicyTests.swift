import Foundation

@main struct Tests {
    static func main() {
        let name = "ZagStore.onboarding-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        check(ZagOnboardingPolicy.begin(defaults: defaults, hasExistingData: false, domain: [:]), "fresh installation welcomes")
        check(ZagOnboardingPolicy.begin(defaults: defaults, hasExistingData: true, domain: ["other": true]), "unfinished onboarding survives restart and store creation")
        ZagOnboardingPolicy.complete(defaults: defaults)
        check(!ZagOnboardingPolicy.begin(defaults: defaults, hasExistingData: false, domain: [:]), "skip or success persists across launches and updates")
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: "ZagStore.activityOptOut")
        check(!ZagOnboardingPolicy.begin(defaults: defaults, hasExistingData: false, domain: ["ZagStore.activityOptOut": true]), "existing preferences bypass migration")
        check(defaults.bool(forKey: "ZagStore.activityOptOut"), "privacy preference preserved")
        defaults.removePersistentDomain(forName: name)
        check(!ZagOnboardingPolicy.begin(defaults: defaults, hasExistingData: true, domain: [:]), "existing app data bypasses onboarding without defaults")
        print("SUCCESS: onboarding policy checks passed")
    }
}
