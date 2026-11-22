import Foundation

// A user-owned paid Apple Developer account connected to Zag Store through an
// App Store Connect API key (Model 2 of ASC_API_ARCHITECTURE.md). The key and
// its `.p8` private material stay on this device, in the Keychain, and are
// never uploaded to any Zag Store server.
//
// Provisioning (certificates, identifiers, devices, profiles) over the API
// needs a *team* key with the Admin role. Both an individual membership (whose
// sole member is the Account Holder) and an organization (whose Admin creates
// the key) produce such a key; user-based "individual" keys cannot provision
// and carry no issuer ID, so requiring an issuer ID keeps them out.

// MARK: - Credential

/// Everything Zag Store needs to authenticate to the ASC API as one user's
/// team. Stored as one Keychain item per account (`.developerAPIKey`).
struct ZagDeveloperAccountCredential: Codable, Equatable, Sendable {
	/// The team's issuer ID (a UUID), the `iss` of every token.
	let issuerID: String
	/// The API key's ID (ten upper-case letters/digits), the token's `kid`.
	let keyID: String
	/// The ten-character Apple Developer Team ID. ASC key auth does not return
	/// it, and provisioning needs it up front (bundle-ID mapping, profile
	/// checks), so it is collected during onboarding from the membership page.
	let teamID: String
	/// The `.p8` file's contents (PKCS #8 PEM). Sensitive: never logged or sent.
	let privateKeyPEM: String
	let addedAt: Date

	/// The development team this credential signs for. Treated as an individual
	/// paid membership (its provisioning limits match an organization's for the
	/// operations Zag Store uses), never a free team.
	var team: ZagDeveloperTeam {
		ZagDeveloperTeam(identifier: teamID, name: "Developer Team \(teamID)", kind: .individualPaid)
	}

	/// Apple key IDs are ten upper-case letters or digits.
	static func isValidKeyID(_ value: String) -> Bool {
		value.count == 10 && value.unicodeScalars.allSatisfy {
			("A"..."Z").contains($0) || ("0"..."9").contains($0)
		}
	}

	/// Issuer IDs are UUIDs.
	static func isValidIssuerID(_ value: String) -> Bool {
		UUID(uuidString: value) != nil
	}

	/// A `.p8` must be a single unencrypted PKCS #8 private-key PEM block. This
	/// checks the envelope and that the Base64 body decodes; it does not parse
	/// the key (minting does that, through CryptoKit).
	static func looksLikePrivateKeyPEM(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let begin = "-----BEGIN PRIVATE KEY-----"
		let end = "-----END PRIVATE KEY-----"
		guard trimmed.hasPrefix(begin), trimmed.hasSuffix(end) else { return false }
		let body = trimmed
			.replacingOccurrences(of: begin, with: "")
			.replacingOccurrences(of: end, with: "")
			.components(separatedBy: .whitespacesAndNewlines)
			.joined()
		guard !body.isEmpty, let decoded = Data(base64Encoded: body), !decoded.isEmpty else { return false }
		return true
	}

	/// Why a typed credential could not be made from onboarding input.
	enum Problem: Error, Equatable, Sendable {
		case invalidKeyID
		case invalidIssuerID
		case invalidTeamID
		case invalidPrivateKey
	}

	init(issuerID: String, keyID: String, teamID: String, privateKeyPEM: String, addedAt: Date = Date()) throws {
		let key = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
		let issuer = issuerID.trimmingCharacters(in: .whitespacesAndNewlines)
		let team = teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		guard Self.isValidKeyID(key) else { throw Problem.invalidKeyID }
		guard Self.isValidIssuerID(issuer) else { throw Problem.invalidIssuerID }
		guard ZagDeveloperTeam.isValidIdentifier(team) else { throw Problem.invalidTeamID }
		guard Self.looksLikePrivateKeyPEM(privateKeyPEM) else { throw Problem.invalidPrivateKey }
		self.issuerID = issuer
		self.keyID = key
		self.teamID = team
		self.privateKeyPEM = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
		self.addedAt = addedAt
	}
}

// MARK: - Storage

/// Reads and writes one account's ASC credential through the shared
/// free-account secret store, which keeps items in the Keychain,
/// `ThisDeviceOnly`, after first unlock, never synchronised.
struct ZagDeveloperAccountStore: Sendable {
	let secrets: ZagFreeAccountSecretStore

	init(secrets: ZagFreeAccountSecretStore) { self.secrets = secrets }

	func save(_ credential: ZagDeveloperAccountCredential, account: UUID) throws {
		let data = try JSONEncoder().encode(credential)
		try secrets.save(data, kind: .developerAPIKey, account: account)
	}

	func load(account: UUID) throws -> ZagDeveloperAccountCredential? {
		guard let data = try secrets.load(.developerAPIKey, account: account) else { return nil }
		return try JSONDecoder().decode(ZagDeveloperAccountCredential.self, from: data)
	}

	/// Removes the credential (the user disconnected, or the key was revoked).
	/// Removing the whole account uses the store's `deleteAll`, which also
	/// clears this item.
	func remove(account: UUID) throws {
		try secrets.delete(.developerAPIKey, account: account)
	}

	func isConnected(account: UUID) -> Bool {
		((try? secrets.load(.developerAPIKey, account: account)) ?? nil) != nil
	}
}

// MARK: - Status

/// What the Signing Methods list shows for the developer-account method, and
/// the onboarding screen's connection state.
enum ZagDeveloperAccountStatus: Equatable, Sendable {
	case notConnected
	case connecting
	case connected(keyID: String)
	/// Connected input, but the key cannot be used as is (e.g. it lacks
	/// Certificates, Identifiers & Profiles access). The string is shown to
	/// the user.
	case needsAttention(String)
}

// MARK: - Gate

/// Whether the developer-account method may run. Closed in release builds
/// (`ZagSigningMethodAvailability.developerAccountEnabled` is false); the open
/// gate exists only in Debug, for offline tests against a mock transport.
struct ZagDeveloperAccountGate: Equatable, Sendable {
	let isOpen: Bool

	private init(isOpen: Bool) { self.isOpen = isOpen }

	static let production = ZagDeveloperAccountGate(isOpen: ZagSigningMethodAvailability.developerAccountEnabled)
	#if DEBUG
	static let testingOpen = ZagDeveloperAccountGate(isOpen: true)
	#endif
}
