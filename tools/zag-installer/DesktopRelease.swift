import Foundation

private final class AssetTransfer: NSObject, URLSessionDataDelegate {
    static let maxBytes = 512 * 1024 * 1024
    private static let assetHosts = ["objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    private let output: FileHandle
    private var received = 0
    private var terminal: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(output: FileHandle) { self.output = output }

    static func releasePath(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "github.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
              let match = parts.percentEncodedPath.range(
                of: "^/(zagorskey|zagstore)/zag-store-releases/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\.ipa$",
                options: .regularExpression)
        else { return nil }
        return parts.percentEncodedPath[match].split(separator: "/").suffix(2).joined(separator: "/")
    }

    private static func allowsRedirect(from source: URL, to target: URL) -> Bool {
        guard let parts = URLComponents(url: target, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil, parts.user == nil, parts.password == nil,
              parts.fragment == nil else { return false }
        if let host = parts.host, assetHosts.contains(host) { return true }
        guard let path = releasePath(target) else { return false }
        return path == releasePath(source)
    }

    func start(_ request: URLRequest, session: URLSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let source = response.url, let target = request.url, Self.allowsRedirect(from: source, to: target) {
            completionHandler(request)
        } else {
            terminal = DesktopNetworkError.unsafeRedirect
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if terminal == nil {
            if let http = response as? HTTPURLResponse {
                if http.statusCode != 200 { terminal = DesktopNetworkError.http(http.statusCode) }
                else if response.expectedContentLength > Int64(Self.maxBytes) { terminal = DesktopNetworkError.tooLarge }
            } else { terminal = DesktopNetworkError.invalidResponse }
        }
        completionHandler(terminal == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard terminal == nil else { dataTask.cancel(); return }
        guard data.count <= Self.maxBytes - received else {
            terminal = DesktopNetworkError.tooLarge
            dataTask.cancel()
            return
        }
        do {
            try output.write(contentsOf: data)
            received += data.count
        } catch {
            terminal = DesktopNetworkError.filesystem
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = terminal ?? error { continuation?.resume(throwing: failure) }
        else if received == 0 { continuation?.resume(throwing: DesktopNetworkError.invalidResponse) }
        else { continuation?.resume() }
        continuation = nil
    }

    static func download(_ url: URL, to destination: URL) async throws {
        guard releasePath(url) != nil else { throw DesktopNetworkError.unsafeRedirect }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: destination) }
        catch { throw DesktopNetworkError.filesystem }
        defer { try? output.close() }
        let transfer = AssetTransfer(output: output)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await transfer.start(URLRequest(url: url), session: session)
    }
}

@main
struct DesktopRelease {
    static func main() async {
        var stage = "Signed release discovery"
        do {
            let args = CommandLine.arguments
            if args.count == 4, args[1] == "asset", let url = URL(string: args[2]) {
                stage = "Official IPA download"
                try await AssetTransfer.download(url, to: URL(fileURLWithPath: args[3]))
                return
            }
            let channel = args.count == 1 ? "beta" : (args.count == 3 && args[1] == "channel" ? args[2] : "")
            guard ["stable", "beta", "nightly"].contains(channel) else { throw DesktopNetworkError.invalidResponse }
            let store = ZagUpdateRollbackStore(service: "app.zagstore.desktop-installer.release-v2")
            let endpoint = URL(string: "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/\(channel).json")!
            let payload = try await ZagUpdateV2Discovery.fetchVerified(from: endpoint, channel: channel, store: store,
                                                                       session: URLSession(configuration: .ephemeral))
            let result = [
                "version": payload.version, "build": payload.build, "minimum_os": payload.minimumIOSVersion,
                "url": payload.ipaURL, "sha256": payload.sha256, "expires": payload.expiresAt,
                "sequence": String(payload.sequence),
            ]
            FileHandle.standardOutput.write(try JSONEncoder().encode(result))
        } catch {
            let message: String
            switch error {
            case ZagUpdateV2Discovery.DiscoveryError.httpStatus(let status):
                message = DesktopNetworkError.httpMessage(status)
            case let error as ZagUpdateV2Discovery.DiscoveryError:
                message = error.localizedDescription
            case let error as ZagUpdateMetadataV2.ValidationError:
                message = error.localizedDescription
            case let error as ZagUpdateRollbackStore.StoreError:
                message = error.localizedDescription
            case let error as DesktopNetworkError:
                message = error.localizedDescription
            default:
                message = DesktopNetworkError.transportMessage(error)
            }
            if let diagnostic = try? JSONEncoder().encode(["message": "\(stage): \(message)"]) {
                FileHandle.standardError.write(diagnostic)
            }
            exit(1)
        }
    }
}
