import Foundation
import CryptoKit

/// Account-scoped persistence after the caller has verified the live Personal
/// Team, running signer, device, and authenticated handoff.
enum ZagSigningIdentityHandoffImport {
    enum Failure: Error { case conflict }

    static func commit(certificate: Data, serial: String, expires: Date, scope: ZagSigningScope,
                       store: any ZagFreeAccountSecretStore, installKey: (String?) throws -> Void) throws {
        let account = scope.accountID
        let team = scope.teamID
        let current = try store.load(.signingPrivateKey, account: account, team: team)
            .map { try JSONDecoder().decode(ZagSigningIdentity.self, from: $0) }
        if let current, current.certificate != certificate || !current.keyIsInKeychain { throw Failure.conflict }
        if let data = try store.load(.pendingSigningKey, account: account, team: team) {
            let pending = try JSONDecoder().decode(ZagPendingSigningKey.self, from: data)
            // A known 7460 refusal leaves a retryable journal. Preserve it.
            guard pending.certificate == nil, pending.submissionUnconfirmed != true else { throw Failure.conflict }
        }
        // A stable slot permits retry after key import but before metadata
        // commit. The Keychain helper checks possession even for duplicates.
        let fingerprint = SHA256.hash(data: certificate).prefix(8).map { String(format: "%02x", $0) }.joined()
        let slot = current == nil ? fingerprint : current?.keySlot
        try installKey(slot)
        let identity = ZagSigningIdentity(serialNumber: serial, certificate: certificate, privateKey: Data(),
                                          expiresAt: expires, keySlot: slot)
        if current != identity {
            try store.save(JSONEncoder().encode(identity), kind: .signingPrivateKey, account: account, team: team)
        }
    }
}
