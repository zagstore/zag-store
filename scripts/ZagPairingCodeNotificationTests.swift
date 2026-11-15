import Foundation
import UserNotifications

@main struct Tests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            count += 1
            print("PASS: \(label)")
        }
        for code in ["012345", "000000", "123456", "999999"] {
            let content = ZagPairingCodeNotification.content(for: code)!
            check(content.title == "Pairing Code", "notification title is concise")
            check(content.body == code && content.body.utf8.count == 6, "body contains exactly six digits, preserving leading zeroes")
            check(content.subtitle.isEmpty && content.userInfo.isEmpty && content.attachments.isEmpty, "no extra instructions or code metadata")
            check(content.categoryIdentifier == "zag-rppairing-pin-category" && content.sound != nil, "existing notification action category and sound retained")
            if #available(macOS 12.0, *) {
                check(content.interruptionLevel == .timeSensitive, "time-sensitive presentation retained")
            }
        }
        for input in ["", "12345", "1234567", "123 456", "１２３４５６", "١٢٣٤٥٦", "prefix123456", "123456\n"] {
            check(ZagPairingCodeNotification.content(for: input) == nil, "malformed callback cannot publish arbitrary notification text")
        }
        print("SUCCESS: \(count) pairing-code notification checks passed")
    }
}
