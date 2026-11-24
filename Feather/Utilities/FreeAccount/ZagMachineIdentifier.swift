import Foundation
import Security

// A stable, securely persisted machine identifier for the developer-services
// `machineId` field of `submitDevelopmentCSR` (and any other machine-scoped
// operation). The established free-account protocol (AltSign/SideStore) labels
// a certificate request with a machine identity that is STABLE for the install,
// not a fresh value per request — a random-per-call id (what we sent before)
// both misrepresents the machine and makes an account accrue certificates that
// look like they came from many machines.
//
// It is an opaque per-install UUID, created once and kept in the Keychain with
// ThisDeviceOnly protection (never synced, never restored to another device).
// It is NOT a signing key and carries no cryptographic material; it is only a
// label. It is independent of any Apple Account (the machine is the machine).

/// Backing store seam so the identifier is host-testable without the Keychain.
protocol ZagMachineIdentifierStore: Sendable {
	func load() -> String?
	func save(_ value: String) -> Bool
}

enum ZagMachineIdentifier {
	/// Returns the stable identifier, creating and persisting it once. A single
	/// uppercased UUID string, the shape the portal expects for `machineId`.
	static func current(store: ZagMachineIdentifierStore = ZagKeychainMachineIdentifierStore()) -> String {
		if let existing = store.load(), isValid(existing) { return existing }
		let created = UUID().uuidString.uppercased()
		_ = store.save(created)
		// Re-read: if the save raced or failed, prefer whatever is now persisted,
		// so two callers converge on one value rather than each inventing its own.
		if let persisted = store.load(), isValid(persisted) { return persisted }
		return created
	}

	static func isValid(_ value: String) -> Bool {
		UUID(uuidString: value) != nil
	}
}

/// Keychain-backed store: a generic-password item, readable after first unlock,
/// ThisDeviceOnly, never synchronised.
struct ZagKeychainMachineIdentifierStore: ZagMachineIdentifierStore {
	static let service = "app.zagstore.anisette.appleauth.machineid.v1"
	static let account = "machineId"

	private func baseQuery() -> [CFString: Any] {
		[kSecClass: kSecClassGenericPassword,
		 kSecAttrService: Self.service,
		 kSecAttrAccount: Self.account]
	}

	func load() -> String? {
		var query = baseQuery()
		query[kSecReturnData] = true
		query[kSecMatchLimit] = kSecMatchLimitOne
		var out: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
			  let data = out as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
		return value
	}

	func save(_ value: String) -> Bool {
		let data = Data(value.utf8)
		var add = baseQuery()
		add[kSecValueData] = data
		add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		add[kSecAttrSynchronizable] = false
		let status = SecItemAdd(add as CFDictionary, nil)
		if status == errSecDuplicateItem {
			return SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecSuccess
		}
		return status == errSecSuccess
	}
}
