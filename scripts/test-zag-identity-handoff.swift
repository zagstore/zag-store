import Foundation
import CryptoKit

@main
struct HandoffTests {
    static func main() throws {
        typealias Envelope = ZagIdentityHandoffEnvelope
        let now = Date()
        let team = "FTB8PRW638"
        let bundle = "app.zagstore.ios." + team
        let identifier = "00008020-0123456789ABCDEF"
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let scope = try Envelope.scope(account: "12345", team: team)
        let certificate = Data("synthetic leaf".utf8)
        let request = Envelope.Request(protocolVersion: 1, nonce: UUID(), expires: now.timeIntervalSince1970 + 300,
            recipient: recipient.publicKey.rawRepresentation, udid: identifier, bundle: bundle,
            team: team, keyScope: scope, certificate: certificate)
        let bytes = try JSONEncoder().encode(request)
        let privateKey = Data("synthetic private key".utf8)
        let response = try Envelope.seal(privateKey, for: bytes, now: now)
        precondition(try! Envelope.open(response, request: bytes, recipient: recipient, now: now) == privateKey)
        precondition(!response.contains(privateKey))
        precondition(Envelope.code(bytes).count == 24)
        precondition(scope == "6cf2efc716a9bc3863de7f5fe2ff81cb2d8020f856a3d842c67e20514f8f7b24")

        func reject(_ name: String, _ action: () throws -> Void) {
            do { try action(); fatalError("Accepted \(name)") }
            catch { print("PASS: refused \(name)") }
        }
        for (label, device, app, expectedTeam, expectedScope, leaf) in [
            ("device", String(repeating: "0", count: 40), bundle, team, scope, certificate),
            ("bundle", identifier, "com.cwd43.gu29", team, scope, certificate),
            ("team", identifier, bundle, "OTHERTEAM1", scope, certificate),
            ("account", identifier, bundle, team, try Envelope.scope(account: "12346", team: team), certificate),
            ("certificate", identifier, bundle, team, scope, Data([0])),
        ] {
            reject(label) { try request.checkBinding(device: device, bundle: app, team: expectedTeam, scope: expectedScope, certificate: leaf) }
        }
        reject("expired request") { _ = try Envelope.open(response, request: bytes, recipient: recipient, now: now + 301) }
        let interrupted = Curve25519.KeyAgreement.PrivateKey()
        reject("replay after restart/new request") { _ = try Envelope.open(response, request: bytes, recipient: interrupted, now: now) }
        let replacement = Envelope.Request(protocolVersion: 1, nonce: UUID(), expires: request.expires,
            recipient: request.recipient, udid: identifier, bundle: bundle, team: team, keyScope: scope, certificate: certificate)
        reject("replay against different request") {
            _ = try Envelope.open(response, request: JSONEncoder().encode(replacement), recipient: recipient, now: now)
        }
        let parcel = try JSONDecoder().decode(Envelope.Response.self, from: response)
        var flipped = parcel.box
        flipped[flipped.index(before: flipped.endIndex)] ^= 1
        reject("tampered ciphertext") {
            _ = try Envelope.open(JSONEncoder().encode(Envelope.Response(sender: parcel.sender, box: flipped)),
                                  request: bytes, recipient: recipient, now: now)
        }
        reject("partial response") { _ = try Envelope.open(response.prefix(12), request: bytes, recipient: recipient, now: now) }
        print("PASS: authenticated round trip and desktop-compatible scope")
    }
}

extension Data {
    fileprivate func contains(_ data: Data) -> Bool { range(of: data) != nil }
}
