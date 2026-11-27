import Foundation

@main
struct DesktopRelease {
    static func main() async {
        let store = ZagUpdateRollbackStore(service: "app.zagstore.desktop-installer.release-v2")
        do {
            let endpoint = URL(string: "https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/beta.json")!
            let payload = try await ZagUpdateV2Discovery.fetchVerified(from: endpoint, channel: "beta", store: store)
            let result = [
                "version": payload.version, "build": payload.build, "minimum_os": payload.minimumIOSVersion,
                "url": payload.ipaURL, "sha256": payload.sha256, "expires": payload.expiresAt,
                "sequence": String(payload.sequence),
            ]
            FileHandle.standardOutput.write(try JSONEncoder().encode(result))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
