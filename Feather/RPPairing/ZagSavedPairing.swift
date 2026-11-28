import Foundation

struct ZagPairedDeviceIdentity: Codable, Equatable, Sendable {
	let name: String
	let model: String
	let udid: String

	init?(name: String, model: String, udid: String) {
		let normalized = udid.uppercased()
		let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
		let validShape = parts.map(\.count) == [8, 16] || parts.map(\.count) == [40]
		guard validShape, parts.joined().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
		self.name = name.isEmpty ? "This iPhone" : name
		self.model = model
		self.udid = normalized
	}
}

/// The existing Rust plist stores the host credentials. The companion record
/// binds the provisioning UDID to that exact host key without storing the
/// private key a second time or changing the plist used by existing installers.
struct ZagSavedPairing {
	private struct HostRecord: Decodable, Equatable {
		let identifier: String
		let publicKey: Data
		let privateKey: Data

		enum CodingKeys: String, CodingKey {
			case identifier
			case publicKey = "public_key"
			case privateKey = "private_key"
		}
	}

	private struct DeviceRecord: Codable {
		let hostIdentifier: String
		let hostPublicKey: Data
		let device: ZagPairedDeviceIdentity
	}

	let credentials: URL
	let metadata: URL

	private func host() -> HostRecord? {
		guard let data = try? Data(contentsOf: credentials), data.count <= 64 * 1024,
			  let record = try? PropertyListDecoder().decode(HostRecord.self, from: data),
			  !record.identifier.isEmpty, record.publicKey.count == 32, record.privateKey.count == 32 else { return nil }
		return record
	}

	var hasCredentials: Bool { host() != nil }

	func restore(cleanupPending: Bool) -> ZagPairedDeviceIdentity? {
		guard !cleanupPending, let host = host(), let data = try? Data(contentsOf: metadata),
			  let record = try? PropertyListDecoder().decode(DeviceRecord.self, from: data),
			  record.hostIdentifier == host.identifier, record.hostPublicKey == host.publicKey else { return nil }
		return ZagPairedDeviceIdentity(name: record.device.name, model: record.device.model, udid: record.device.udid)
	}

	func save(_ device: ZagPairedDeviceIdentity) throws {
		guard let host = host() else { throw CocoaError(.fileReadCorruptFile) }
		let record = DeviceRecord(hostIdentifier: host.identifier, hostPublicKey: host.publicKey, device: device)
		try PropertyListEncoder().encode(record).write(to: metadata, options: .atomic)
	}
}
