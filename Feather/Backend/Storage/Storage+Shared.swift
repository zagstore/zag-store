//
//  Storage+Shared.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData

// MARK: - Class extension: Apps (Shared)
extension Storage {
	func getUuidDirectory(for app: AppInfoPresentable) -> URL? {
		guard let uuid = app.uuid else { return nil }
		return app.isSigned
			? FileManager.default.signed(uuid)
			: FileManager.default.unsigned(uuid)
	}
	
	func getAppDirectory(for app: AppInfoPresentable) -> URL? {
		guard let url = getUuidDirectory(for: app) else { return nil }
		return FileManager.default.getPath(in: url, for: "app")
	}
	
	@MainActor
	func deleteApp(for app: AppInfoPresentable) {
		#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
		ZagNativeAppInventory.forget(app)
		#endif
		do {
			if let url = getUuidDirectory(for: app) {
				try? FileManager.default.removeItem(at: url)
			}
			if let object = app as? NSManagedObject {
				context.delete(object)
			}
			saveContext()
		}
	}
	
	func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
		if let signed = app as? Signed {
			return signed.certificate
		}
		return nil
	}
}

/// Durable receipt for an imported profile installed independently of its app.
struct ZagCertificateProfileReceipt: Codable {
	let profile: Data
	let effectiveExpiration: Date

	static func location(in signedDirectory: URL) -> URL {
		signedDirectory.appendingPathComponent("verified-renewal.json")
	}

	static func load(for app: AppInfoPresentable) -> Self? {
		guard app.isSigned, let uuid = app.uuid, UUID(uuidString: uuid) != nil,
			  let data = try? Data(contentsOf: location(in: FileManager.default.signed(uuid))) else { return nil }
		return try? JSONDecoder().decode(Self.self, from: data)
	}
}

// MARK: - Helpers
struct AnyApp: Identifiable {
	let base: AppInfoPresentable
	var archive: Bool = false
	
	var id: String {
		base.uuid ?? UUID().uuidString
	}
}

protocol AppInfoPresentable {
	var name: String? { get }
	var version: String? { get }
	var identifier: String? { get }
	var date: Date? { get }
	var icon: String? { get }
	var uuid: String? { get }
	var isSigned: Bool { get }
	
}

extension Signed: AppInfoPresentable {
	var isSigned: Bool { true }
}

extension Imported: AppInfoPresentable {
	var isSigned: Bool { false }
}
