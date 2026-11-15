import Foundation

/// Parses external input without performing navigation, network or file operations.
enum ZagDeepLink {
    struct Certificate: Equatable {
        let p12: Data
        let provision: Data
        let password: String
    }

    enum Action: Equatable {
        case navigate(ZagStoreRoute)
        case source(URL)
        case download(URL)
        case certificate(Certificate)
        case package(URL)
        case returnFromVPN
        case disabledExport
    }

    static func parse(_ url: URL) -> Action? {
        // Bound external data before decoding it. Never log an incoming URL.
        guard url.absoluteString.utf8.count <= 4 * 1024 * 1024 else { return nil }
        if let route = ZagStoreRoute.parse(url) { return .navigate(route) }
        if url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil,
                  ["ipa", "tipa"].contains(url.pathExtension.lowercased()) else { return nil }
            return .package(url)
        }
        guard url.scheme?.lowercased() == "feather",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let host = (url.host ?? "").lowercased()
        // LocalDevVPN's existing `scheme=feather` callback is a return only.
        if host.isEmpty, url.path.isEmpty, parts.query == nil, parts.fragment == nil { return .returnFromVPN }
        if host == "export-certificate" { return .disabledExport }
        if host == "source" || host == "install" {
            // Match the authority, not a marker anywhere in an arbitrary URL.
            guard url.path.hasPrefix("/"),
                  let separator = url.absoluteString.range(of: "://"),
                  let slash = url.absoluteString[separator.upperBound...].firstIndex(of: "/") else { return nil }
            let raw = String(url.absoluteString[url.absoluteString.index(after: slash)...])
            // Raw HTTPS links preserve their existing escapes, queries and '+' signs.
            // Entirely escaped nested links are decoded exactly once.
            let nested = raw.lowercased().hasPrefix("https://") ? raw : (raw.removingPercentEncoding ?? "")
            guard let remote = secureRemote(nested) else { return nil }
            return host == "source" ? .source(remote) : .download(remote)
        }
        if host == "import-certificate" {
            guard url.path.isEmpty || url.path == "/", parts.fragment == nil,
                  let items = parts.queryItems, items.count == 3,
                  Set(items.map(\.name)) == Set(["p12", "mobileprovision", "password"]) else { return nil }
            func bytes(_ name: String, limit: Int) -> Data? {
                guard let value = items.first(where: { $0.name == name })?.value,
                      value.utf8.count <= limit * 2,
                      let data = Data(base64Encoded: value.replacingOccurrences(of: " ", with: "+")),
                      data.count <= limit else { return nil }
                return data
            }
            guard let p12 = bytes("p12", limit: 1024 * 1024), !p12.isEmpty,
                  let provision = bytes("mobileprovision", limit: 1024 * 1024), !provision.isEmpty,
                  let passwordData = bytes("password", limit: 4096),
                  let password = String(data: passwordData, encoding: .utf8) else { return nil }
            return .certificate(Certificate(p12: p12, provision: provision, password: password))
        }
        return nil
    }

    static func importLocation(_ file: URL, grantedScope: Bool, inbox: URL) -> URL? {
        guard file.isFileURL else { return nil }
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        let allowedInbox = inbox.resolvingSymlinksInPath().standardizedFileURL
        guard grantedScope || resolved.path.hasPrefix(allowedInbox.path + "/"),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return resolved
    }

    /// Repository-supplied website/news links must stay in the web browser.
    static func isWebLink(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return false }
        return true
    }

    static func secureRemote(_ string: String) -> URL? {
        guard let parts = URLComponents(string: string),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              !host.contains("%"), let url = parts.url else { return nil }
        return url
    }
}
