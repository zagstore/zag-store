import Foundation
import CryptoKit

enum ZagIdentityHandoffEnvelope {
    static let maxSize = 16 * 1024
    static let lifetime: TimeInterval = 600
    static let requestPath = "Documents/ZagIdentityHandoffRequest.json"
    static let responsePath = "Documents/ZagIdentityHandoffResponse.json"

    enum Failure: LocalizedError {
        case invalid, expired, binding
        var errorDescription: String? {
            switch self {
            case .invalid: "The signing identity transfer is invalid."
            case .expired: "The signing identity request expired. Start a new transfer."
            case .binding: "The transfer does not match this device, account, app or certificate."
            }
        }
    }

    struct Request: Codable, Equatable {
        let protocolVersion: Int
        let nonce: UUID
        let expires: TimeInterval
        let recipient: Data
        let udid: String
        let bundle: String
        let team: String
        let keyScope: String
        let certificate: Data

        func validate(now: Date = .now) throws {
            guard protocolVersion == 1,
                  udid.range(of: "^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})$", options: .regularExpression) != nil,
                  team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
                  bundle == "app.zagstore.ios." + team,
                  keyScope.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  recipient.count == 32, !certificate.isEmpty, certificate.count <= 8192 else { throw Failure.invalid }
            let remaining = expires - now.timeIntervalSince1970
            guard remaining > 0, remaining <= ZagIdentityHandoffEnvelope.lifetime else { throw Failure.expired }
        }

        func checkBinding(device: String, bundle: String, team: String, scope: String, certificate: Data) throws {
            guard udid.caseInsensitiveCompare(device) == .orderedSame, self.bundle == bundle,
                  self.team == team, keyScope == scope, self.certificate == certificate else { throw Failure.binding }
        }
    }

    struct Response: Codable {
        let sender: Data
        let box: Data
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func code(_ request: Data) -> String { String(hex(SHA256.hash(data: request)).prefix(24)) }

    static func scope(account: String, team: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let bytes = try encoder.encode(["signing-key", account, team])
        return hex(SHA256.hash(data: bytes))
    }

    static func decodeRequest(_ bytes: Data, now: Date = .now) throws -> Request {
        guard bytes.count <= maxSize else { throw Failure.invalid }
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        try request.validate(now: now)
        return request
    }

    private static func derive(privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data, request: Data) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peer))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: request)),
            sharedInfo: Data("Zag Store signing identity handoff v1".utf8), outputByteCount: 32)
    }

    static func seal(_ identity: Data, for requestBytes: Data, now: Date = .now) throws -> Data {
        let request = try decodeRequest(requestBytes, now: now)
        guard !identity.isEmpty, identity.count <= 4096 else { throw Failure.invalid }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let key = try derive(privateKey: ephemeral, peer: request.recipient, request: requestBytes)
        guard let box = try AES.GCM.seal(identity, using: key, authenticating: requestBytes).combined else { throw Failure.invalid }
        return try JSONEncoder().encode(Response(sender: ephemeral.publicKey.rawRepresentation, box: box))
    }

    static func open(_ bytes: Data, request: Data, recipient: Curve25519.KeyAgreement.PrivateKey, now: Date = .now) throws -> Data {
        let parsed = try decodeRequest(request, now: now)
        guard bytes.count <= maxSize, parsed.recipient == recipient.publicKey.rawRepresentation else { throw Failure.binding }
        let response = try JSONDecoder().decode(Response.self, from: bytes)
        let key = try derive(privateKey: recipient, peer: response.sender, request: request)
        let identity = try AES.GCM.open(AES.GCM.SealedBox(combined: response.box), using: key, authenticating: request)
        guard !identity.isEmpty, identity.count <= 4096 else { throw Failure.invalid }
        return identity
    }
}
