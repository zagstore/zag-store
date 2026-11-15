import Foundation

/// No documented app-level status API or verified response is available here.
/// Pairing, reachability, a saved record and installed apps are not status evidence.
enum ZagDeveloperModeGuidance {
    static let status = "Check"
    static let accessibilityStatus = "Not verified. Check Developer Mode in Settings."
    static let steps = [
        "Open Settings.",
        "Go to Privacy & Security → Developer Mode.",
        "Turn on Developer Mode.",
        "Restart the iPhone when prompted.",
        "After restarting, confirm Turn On and enter your device passcode.",
    ]
    static let availability = "Developer Mode may not appear until development pairing has been initiated."
    static let distinction = "Developer Mode and Pair with Zag Store are separate approvals. Enabling Developer Mode does not pair this iPhone with Zag Store."
}
