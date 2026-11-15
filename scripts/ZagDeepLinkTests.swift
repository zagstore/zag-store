import Foundation

@main struct Tests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            count += 1
            print("PASS: \(label)")
        }
        func parse(_ text: String) -> ZagDeepLink.Action? { URL(string: text).flatMap(ZagDeepLink.parse) }
        for route in ZagStoreRoute.allCases {
            check(parse(route.url.absoluteString) == .navigate(route), "route round trip: \(route.rawValue)")
        }
        check(parse("zagstore://discover") == .navigate(.home), "generated Discover alias")
        check(parse("zagstore://library") == .navigate(.apps), "legacy library alias")
        check(ZagStoreRoute.home.tab == "discover", "home targets an actual tab")
        for bad in ["zagstore://settings/unknown", "zagstore://settings?install=yes", "zagstore://user@settings", "zagstore://settings:42", "zagstore://apps#install", "https://example.com/app.ipa", "evil://example.com/app.ipa", "feather://evil/source/https://example.com/repo.json", "feather://source/file:///private/data", "feather://install/http://example.com/app.ipa", "feather://source/https://user:password@example.com/repo.json", "feather://install/", "feather://install/https%253A%252F%252Fexample.com/a.ipa", "file://remote/private/app.ipa", "file:///private/a.txt", "feather://unknown", "feather://source?x=/https://example.com/repo.json"] {
            check(parse(bad) == nil, "reject \(bad)")
        }
        check(ZagDeepLink.isWebLink(URL(string: "https://example.com/news#story")!), "web news anchors supported")
        for bad in ["file:///private/app.ipa", "feather://import-certificate", "shortcuts://run-shortcut", "javascript:alert(1)"] {
            check(!ZagDeepLink.isWebLink(URL(string: bad)!), "repository website cannot launch \(bad)")
        }
        let raw = "https://example.com/a%20b.ipa?token=a%2Bb%26c&name=x+y"
        check(parse("feather://install/" + raw) == .download(URL(string: raw)!), "raw nested escapes and query preserved")
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        check(parse("FEATHER://install/" + encoded) == .download(URL(string: raw)!), "fully encoded nested URL decoded once")
        check(parse("feather://source/https://example.com/repo.json?a=1&b=2") == .source(URL(string: "https://example.com/repo.json?a=1&b=2")!), "legacy source query preserved")
        check(parse("feather://") == .returnFromVPN, "LocalDevVPN return performs no action")
        check(parse("feather://export-certificate") == .disabledExport, "legacy export stays disabled")
        check(parse("file:///tmp/app.tipa") == .package(URL(string: "file:///tmp/app.tipa")!), "document URL parsed for later scope validation")
        var cert = URLComponents(string: "feather://import-certificate")!
        let p12 = Data([251, 255]), profile = Data("profile".utf8), password = "p+%&雪"
        cert.queryItems = [URLQueryItem(name: "p12", value: p12.base64EncodedString()), URLQueryItem(name: "mobileprovision", value: profile.base64EncodedString()), URLQueryItem(name: "password", value: Data(password.utf8).base64EncodedString())]
        check(ZagDeepLink.parse(cert.url!) == .certificate(.init(p12: p12, provision: profile, password: password)), "certificate base64 plus and Unicode round trip")
        cert.queryItems!.append(URLQueryItem(name: "p12", value: "eA=="))
        check(ZagDeepLink.parse(cert.url!) == nil, "duplicate certificate parameters rejected")
        check(parse("feather://import-certificate?p12=eA==&mobileprovision=eA==") == nil, "missing certificate password rejected")
        check(parse("feather://import-certificate?p12=!&mobileprovision=eA==&password=") == nil, "malformed certificate bytes rejected")
        let op = ZagMobileDataToggle.Operation.new(.status)
        let callback = ZagMobileDataToggle.callbackURL(op, .success) + "&result=zag-mobile-data-toggle%3Av1%3Aready"
        check(ZagMobileDataToggle.parse(URL(string: callback)!)?.id == op.id, "generated shortcut callback round trip")
        for bad in [callback + "&id=other", callback + "&result=other", callback + "#extra", callback.replacingOccurrences(of: "://", with: "://user@") ] {
            check(ZagMobileDataToggle.parse(URL(string: bad)!) == nil, "ambiguous shortcut callback rejected")
        }
        _ = ZagStoreRouter.open(ZagStoreRoute.installation.url)
        check(!ZagStoreRouter.open(URL(string: "unknown://route")!) && ZagStoreRouter.pendingRoute == .installation, "unsupported link cannot erase pending navigation")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = directory.appendingPathComponent("Inbox", isDirectory: true)
        try! FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("private.ipa")
        let inside = inbox.appendingPathComponent("shared.ipa")
        try! Data([1]).write(to: outside)
        try! Data([1]).write(to: inside)
        check(ZagDeepLink.importLocation(inside, grantedScope: false, inbox: inbox) != nil, "Inbox delivery accepted")
        check(ZagDeepLink.importLocation(outside, grantedScope: false, inbox: inbox) == nil, "ungranted sandbox path rejected")
        check(ZagDeepLink.importLocation(outside, grantedScope: true, inbox: inbox) != nil, "document-provider grant accepted")
        let symlink = inbox.appendingPathComponent("escape.ipa")
        try! FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        check(ZagDeepLink.importLocation(symlink, grantedScope: false, inbox: inbox) == nil, "Inbox symlink cannot escape its directory")
        check(ZagDeepLink.importLocation(inbox, grantedScope: true, inbox: inbox) == nil, "directories cannot be imported as packages")
        print("SUCCESS: \(count) deep-link checks passed")
    }
}
