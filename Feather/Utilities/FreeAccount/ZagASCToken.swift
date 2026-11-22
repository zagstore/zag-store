import CryptoKit
import Foundation

// A signed JSON Web Token for the App Store Connect API, minted on the device
// from a user-owned API key (a `.p8` PKCS #8 EC P-256 private key). It is the
// only authorisation the ASC provisioning path uses: no Apple-Account
// password and no anisette.
//
// Zag Store provisions through ASC *team* keys, whose JWT carries the team's
// issuer ID in `iss`. User-based ("individual") keys carry `sub` and no issuer
// ID, and Apple does not allow them on the Provisioning endpoints, so this
// minter requires an issuer ID and never produces a `sub` token.
//
// The token lives for at most 20 minutes (Apple's cap). The private key and
// the finished token are sensitive: nothing here logs, prints or stores
// either, and the token is held only by the caller for the life of one
// request.

enum ZagASCTokenError: Error, Equatable, Sendable {
	/// The `.p8` text is not a PKCS #8 EC P-256 private key.
	case invalidPrivateKey
	/// The key ID or issuer ID is not the shape Apple issues.
	case invalidKeyIdentifier
	/// The requested lifetime is not positive.
	case invalidLifetime
	/// The token could not be signed.
	case signingFailed
}

enum ZagASCToken {
	/// Apple rejects a token whose lifetime exceeds 20 minutes.
	static let maximumLifetime: TimeInterval = 20 * 60
	/// The fixed audience of every App Store Connect API token.
	static let audience = "appstoreconnect-v1"

	/// Mints a signed ES256 token for a team key.
	///
	/// - Parameters:
	///   - keyID: the key's ID (Apple issues ten upper-case letters/digits).
	///   - issuerID: the team's issuer ID (a UUID).
	///   - privateKeyPEM: the `.p8` file's contents (PKCS #8 PEM).
	///   - issuedAt: the `iat` instant; `exp` is `issuedAt + lifetime`.
	///   - lifetime: seconds of validity, clamped to `maximumLifetime`.
	static func mint(
		keyID: String,
		issuerID: String,
		privateKeyPEM: String,
		issuedAt: Date = Date(),
		lifetime: TimeInterval = 10 * 60
	) throws -> String {
		guard ZagDeveloperAccountCredential.isValidKeyID(keyID),
			  ZagDeveloperAccountCredential.isValidIssuerID(issuerID) else {
			throw ZagASCTokenError.invalidKeyIdentifier
		}
		guard lifetime > 0 else { throw ZagASCTokenError.invalidLifetime }
		let key: P256.Signing.PrivateKey
		do {
			key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
		} catch {
			throw ZagASCTokenError.invalidPrivateKey
		}

		let issued = Int(issuedAt.timeIntervalSince1970)
		let expires = issued + Int(min(lifetime, maximumLifetime))
		// Hand-built compact JSON with a fixed field order: no encoder whose
		// ordering could vary, and nothing that could carry the key.
		let header = "{\"alg\":\"ES256\",\"kid\":\"\(keyID)\",\"typ\":\"JWT\"}"
		let payload = "{\"iss\":\"\(issuerID)\",\"iat\":\(issued),\"exp\":\(expires),\"aud\":\"\(audience)\"}"
		let signingInput = base64URL(Data(header.utf8)) + "." + base64URL(Data(payload.utf8))

		let signature: P256.Signing.ECDSASignature
		do {
			signature = try key.signature(for: Data(signingInput.utf8))
		} catch {
			throw ZagASCTokenError.signingFailed
		}
		// JOSE wants the raw r‖s pair, which is exactly `rawRepresentation`.
		return signingInput + "." + base64URL(signature.rawRepresentation)
	}

	/// Base64url without padding (RFC 7515).
	static func base64URL(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}
