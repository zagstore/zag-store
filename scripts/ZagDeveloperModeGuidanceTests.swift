import Foundation

@main struct Tests {
    static func main() {
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        check(ZagDeveloperModeGuidance.status == "Check" && ZagDeveloperModeGuidance.accessibilityStatus.contains("Not verified"), "unverified Developer Mode is presented as unknown, not enabled or disabled")
        check(ZagDeveloperModeGuidance.steps.count == 5, "five manual steps provided")
        check(ZagDeveloperModeGuidance.steps[1].contains("Privacy & Security → Developer Mode"), "correct manual Settings path")
        check(ZagDeveloperModeGuidance.steps[2] == "Turn on Developer Mode.", "user controls enabling Developer Mode")
        check(ZagDeveloperModeGuidance.steps[3].contains("Restart"), "restart requirement explained")
        check(ZagDeveloperModeGuidance.steps[4].contains("Turn On") && ZagDeveloperModeGuidance.steps[4].contains("passcode"), "post-restart confirmation and passcode explained")
        check(ZagDeveloperModeGuidance.availability.contains("development pairing"), "missing option guidance provided")
        check(ZagDeveloperModeGuidance.distinction.contains("does not pair"), "Developer Mode is distinct from Zag Store pairing")
        print("SUCCESS: 8 Developer Mode guidance checks passed")
    }
}
