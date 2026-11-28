import Foundation

// The on-device signing model types, extracted from ZagDeveloperPortal.swift so
// the signing stack (ZagSigningKey / ZagKeychainSigningKey) compiles and links
// without the provisioning-profile parser (Certificate.decode). Behaviour is
// unchanged — these are the same declarations, in a lighter file.

/// A certificate signing request, generated on the device. Opaque here; only
/// the public request is ever sent — the private key never leaves the device.
struct ZagCertificateRequest: Sendable, Equatable {
	let data: Data
}

/// Creates the development signing key and its certificate signing request
/// on the device. Only a simulation implements it in this phase.
protocol ZagSigningKeyFactory: Sendable {
	func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest)
	/// Whether an issued certificate is for `privateKey`, with its serial and expiry.
	func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck
	// A new key is made beside the one in use. The stored identity names the
	// key it uses (`ZagSigningIdentity.keySlot`), so the key in use stays in use
	// until the new certificate is issued, verified and stored, and switching is
	// that one write (`ZagPendingSigningKey`).
	func makePendingKey(commonName: String, account: UUID, team: String) throws -> (privateKey: Data, request: ZagCertificateRequest, keySlot: String?)
	/// Whether an issued certificate is for this account and team's key in
	/// `keySlot` (or for `privateKey`, for a factory that returns key bytes).
	func check(certificate: Data, privateKey: Data, account: UUID, team: String, keySlot: String?) -> ZagIssuedCertificateCheck
	func hasKey(account: UUID, team: String, keySlot: String?) -> Bool
	func discardKey(account: UUID, team: String, keySlot: String?) throws
	/// Removes the team's keys other than those in `keeping`: keys of abandoned
	/// attempts that no identity or request in progress names.
	func discardKeys(account: UUID, team: String, except keeping: Set<String?>) throws
}

extension ZagSigningKeyFactory {
	/// For a factory whose key bytes are returned (and kept, while a request is
	/// in progress, in `ZagPendingSigningKey`). A factory whose keys stay in the
	/// Keychain implements these with key items and returns an empty `privateKey`.
	func makePendingKey(commonName: String, account: UUID, team: String) throws -> (privateKey: Data, request: ZagCertificateRequest, keySlot: String?) {
		let made = try makeKey(commonName: commonName)
		return (made.privateKey, made.request, nil)
	}
	func check(certificate: Data, privateKey: Data, account: UUID, team: String, keySlot: String?) -> ZagIssuedCertificateCheck {
		check(certificate: certificate, privateKey: privateKey)
	}
	func hasKey(account: UUID, team: String, keySlot: String?) -> Bool { true }
	func discardKey(account: UUID, team: String, keySlot: String?) throws {}
	func discardKeys(account: UUID, team: String, except keeping: Set<String?>) throws {}
}

struct ZagDisabledSigningKeyFactory: ZagSigningKeyFactory {
	enum Failure: Error { case unavailable }
	func makeKey(commonName: String) throws -> (privateKey: Data, request: ZagCertificateRequest) { throw Failure.unavailable }
	func check(certificate: Data, privateKey: Data) -> ZagIssuedCertificateCheck { .mismatch }
}

/// The development signing identity kept in the Keychain
/// (`ZagFreeAccountSecretKind.signingPrivateKey`) for the signed-in account:
/// the private key and the certificate Apple issued for it.
struct ZagSigningIdentity: Codable, Equatable, Sendable, CustomStringConvertible {
	let serialNumber: String
	let certificate: Data
	/// Empty when the key is a Keychain key item (`ZagKeychainSigningKeys`),
	/// which is never exported.
	let privateKey: Data
	let expiresAt: Date
	/// The slot of the Keychain key item (`ZagKeychainSigningKeys`); nil for
	/// key bytes, or a key made before slots existed.
	var keySlot: String? = nil

	var keyIsInKeychain: Bool { privateKey.isEmpty }

	var description: String { "[signing identity \(serialNumber)]" }
}
