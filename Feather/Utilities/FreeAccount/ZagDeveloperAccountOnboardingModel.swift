import Combine
import Foundation

/// Presentation state for connecting a user-owned App Store Connect API key.
///
/// The user imports their `.p8` file and types the Key ID, Issuer ID and Team
/// ID; the model validates the shape, mints a token and makes one read-only
/// check that Apple accepts the key, then stores the credential in the
/// Keychain. A read cannot prove the key may create anything, so the state is
/// "credentials validated — provisioning unverified" until a write succeeds. The `.p8` text is held in a private field, never published to
/// the view and never logged; it is cleared as soon as it is stored or the
/// screen is dismissed.
///
/// When the feature gate is closed (every release build), `connect()` does
/// nothing but report that the feature is unavailable: no key is read, no
/// request is made and nothing is stored.
@MainActor
final class ZagDeveloperAccountOnboardingModel: ObservableObject {
	enum Phase: Equatable {
		case idle
		case validating
		/// The read-only check passed; provisioning rights are not proven.
		case credentialsValidated(keyID: String, sampleTotal: Int)
		/// A write with this key has succeeded.
		case provisioningVerified(keyID: String)
		/// Connected input but an unusable key (e.g. no provisioning access).
		case needsAttention(String)
		case failed(String)
	}

	@Published var keyID = ""
	@Published var issuerID = ""
	@Published var teamID = ""
	@Published private(set) var importedKeyFileName: String?
	@Published private(set) var phase: Phase = .idle
	@Published private(set) var isBusy = false

	/// The imported `.p8` contents. Private on purpose: never a `@Published`
	/// property, never shown, never logged.
	private var privateKeyPEM: String?

	let account: UUID
	let store: ZagDeveloperAccountStore
	let gate: ZagDeveloperAccountGate
	/// Builds a client for a credential (captures the transport). Tests inject
	/// a client backed by a mock transport.
	private let makeClient: @Sendable (ZagDeveloperAccountCredential) -> ZagASCClient
	/// Removes the whole account from this device (key, signing identity and
	/// its Keychain keys). Without one, removal deletes the key only.
	private let removeAll: (@Sendable () throws -> Void)?

	init(
		account: UUID,
		store: ZagDeveloperAccountStore,
		gate: ZagDeveloperAccountGate = .production,
		makeClient: @escaping @Sendable (ZagDeveloperAccountCredential) -> ZagASCClient,
		removeAll: (@Sendable () throws -> Void)? = nil
	) {
		self.account = account
		self.store = store
		self.gate = gate
		self.makeClient = makeClient
		self.removeAll = removeAll
	}

	var hasImportedKey: Bool { privateKeyPEM != nil }

	/// A credential is stored (validated, verified or not).
	var isConnected: Bool {
		switch phase {
		case .credentialsValidated, .provisioningVerified: return true
		default: return false
		}
	}

	var canConnect: Bool {
		!isBusy
			&& privateKeyPEM != nil
			&& ZagDeveloperAccountCredential.isValidKeyID(keyID.trimmingCharacters(in: .whitespacesAndNewlines))
			&& ZagDeveloperAccountCredential.isValidIssuerID(issuerID.trimmingCharacters(in: .whitespacesAndNewlines))
			&& ZagDeveloperTeam.isValidIdentifier(teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
	}

	/// What the Signing Methods list should show for this method.
	var methodStatus: ZagDeveloperAccountStatus {
		switch phase {
		case .idle: return store.isConnected(account: account) ? .credentialsValidated(keyID: keyID) : .notConnected
		case .validating: return .connecting
		case .credentialsValidated(let keyID, _): return .credentialsValidated(keyID: keyID)
		case .provisioningVerified(let keyID): return .provisioningVerified(keyID: keyID)
		case .needsAttention(let message): return .needsAttention(message)
		case .failed(let message): return .needsAttention(message)
		}
	}

	// MARK: Actions

	/// Loads a previously stored credential (not its key) so the screen opens
	/// in the connected state.
	func restore() {
		guard let credential = try? store.load(account: account) else { return }
		keyID = credential.keyID
		issuerID = credential.issuerID
		teamID = credential.teamID
		phase = credential.provisioningVerifiedAt == nil
			? .credentialsValidated(keyID: credential.keyID, sampleTotal: 0)
			: .provisioningVerified(keyID: credential.keyID)
	}

	/// Accepts the imported `.p8` file. Validates the envelope only; the key is
	/// parsed when a token is minted.
	func importKey(contents: String, fileName: String) {
		guard ZagDeveloperAccountCredential.looksLikePrivateKeyPEM(contents) else {
			privateKeyPEM = nil
			importedKeyFileName = nil
			phase = .failed("That file is not an App Store Connect API private key (.p8).")
			return
		}
		privateKeyPEM = contents.trimmingCharacters(in: .whitespacesAndNewlines)
		importedKeyFileName = fileName
		if case .failed = phase { phase = .idle }
	}

	/// Validates input and confirms the key can reach the Provisioning
	/// endpoints, then stores it. No certificate, device or profile is created.
	func connect() async {
		guard gate.isOpen else {
			phase = .failed("Developer Account signing is not available in this version of Zag Store.")
			return
		}
		guard !isBusy else { return }
		guard let pem = privateKeyPEM else {
			phase = .failed("Import your App Store Connect API key (.p8) first.")
			return
		}
		let credential: ZagDeveloperAccountCredential
		do {
			credential = try ZagDeveloperAccountCredential(issuerID: issuerID, keyID: keyID, teamID: teamID, privateKeyPEM: pem)
		} catch ZagDeveloperAccountCredential.Problem.invalidKeyID {
			phase = .failed("The Key ID should be ten letters or digits, from App Store Connect.")
			return
		} catch ZagDeveloperAccountCredential.Problem.invalidIssuerID {
			phase = .failed("The Issuer ID should be the UUID shown above your keys in App Store Connect.")
			return
		} catch ZagDeveloperAccountCredential.Problem.invalidTeamID {
			phase = .failed("The Team ID should be the ten-character ID from your Apple Developer membership page.")
			return
		} catch {
			phase = .failed("That file is not an App Store Connect API private key (.p8).")
			return
		}

		isBusy = true
		phase = .validating
		defer { isBusy = false }
		do {
			let connection = try await makeClient(credential).connectionCheck()
			try store.save(credential, account: account)
			privateKeyPEM = nil
			phase = .credentialsValidated(keyID: credential.keyID, sampleTotal: connection.sampleTotal)
		} catch let error as ZagASCError {
			phase = Self.phase(for: error)
		} catch {
			phase = .failed("Zag Store could not reach App Store Connect. Check your connection and try again.")
		}
	}

	/// Disconnects: removes the stored API key and clears the screen. The
	/// signing certificate stays, so reconnecting the same team reuses it.
	func disconnect() {
		try? store.remove(account: account)
		clear()
	}

	/// Removes the developer account from this device: the API key, the
	/// signing identity and its keys. Nothing is changed at Apple.
	func removeAccount() {
		do {
			if let removeAll { try removeAll() } else { try store.remove(account: account) }
		} catch {
			phase = .failed("Some of this account's data could not be removed from the Keychain. Try again.")
			return
		}
		clear()
	}

	/// Reloads the status after an install may have verified provisioning.
	func refreshStatus() {
		guard isConnected else { return }
		restore()
	}

	private func clear() {
		privateKeyPEM = nil
		importedKeyFileName = nil
		keyID = ""
		issuerID = ""
		teamID = ""
		phase = .idle
	}

	static func phase(for error: ZagASCError) -> Phase {
		switch error {
		case .forbidden:
			return .needsAttention("This key can't manage Certificates, Identifiers & Profiles. Create a team key with the Admin role in App Store Connect.")
		case .unauthorized:
			return .failed("App Store Connect did not accept this key. Check the Key ID, Issuer ID and that the .p8 matches.")
		case .rateLimited:
			return .failed("App Store Connect is rate-limiting this key. Try again in a little while.")
		case .tokenUnavailable:
			return .failed("That .p8 could not be used to sign a request. Re-download the key from App Store Connect.")
		case .server:
			return .failed("App Store Connect is having trouble right now. Try again later.")
		case .transport(let reason):
			return reason == .offline
				? .failed("You appear to be offline. Check your connection and try again.")
				: .failed("Zag Store could not reach App Store Connect. Try again.")
		case .notFound, .malformedRequest, .malformedResponse, .unexpected, .conflict, .invalidRequest:
			return .failed("App Store Connect returned something Zag Store does not understand.")
		}
	}
}
