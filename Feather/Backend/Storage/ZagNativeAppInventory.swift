#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
import CoreData
import Combine
import Foundation
import UIKit
import Zip

/// Metadata and an unmodified renewal IPA for apps signed with a Personal Team.
/// The library row uses the existing Signed store. Files live outside Documents.
@MainActor
enum ZagNativeAppInventory {
	static let changes = PassthroughSubject<String, Never>()
	struct Entry: Codable, Sendable {
		let uuid: String
		let name: String
		let version: String?
		var installation: ZagNativeInstalledProfiles
		var signingMethod: ZagSigningMethod = .freeAppleAccount
		var pendingInstall: ZagInstallExpectation? = nil
	}

	enum Failure: LocalizedError {
		case missingSource, wrongAccount, unverified

		var errorDescription: String? {
			switch self {
			case .missingSource: "Import the original IPA, then choose it from the Resign screen. The installed app and its data can stay on this iPhone."
			case .wrongAccount: "Connect the Apple Account that originally signed this app."
			case .unverified: "The new installation could not be verified. The saved expiration has not changed."
			}
		}
	}

	nonisolated private static var root: URL {
		URL.applicationSupportDirectory.appendingPathComponent("ZagStore/NativeApps", isDirectory: true)
	}

	nonisolated private static func folder(_ id: String) -> URL {
		root.appendingPathComponent(id, isDirectory: true)
	}

	static func entry(_ app: AppInfoPresentable) -> Entry? {
		guard app.isSigned, let id = app.uuid, UUID(uuidString: id) != nil else { return nil }
		return entry(id)
	}

	private static func entry(_ id: String) -> Entry? {
		guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("installation.json")),
			  let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.uuid == id,
			  entry.signingMethod == .freeAppleAccount else { return nil }
		return entry
	}

	static func entry(bundleIdentifier: String) -> Entry? {
		let request = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "identifier == %@", bundleIdentifier)
		let entries = (try? Storage.shared.context.fetch(request))?.compactMap { Self.entry($0) } ?? []
		return entries.first(where: { $0.pendingInstall == nil }) ?? entries.first
	}

	static func pendingEntry(bundleIdentifier: String) -> Entry? {
		let request = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "identifier == %@", bundleIdentifier)
		return (try? Storage.shared.context.fetch(request))?.lazy.compactMap { Self.entry($0) }
			.first { $0.pendingInstall != nil }
	}

	static func entry(originalIdentifier: String, pending: Bool = false) -> Entry? {
		guard let rows = try? Storage.shared.context.fetch(Signed.fetchRequest()) else { return nil }
		let matches = rows.compactMap { Self.entry($0) }.filter {
			($0.pendingInstall != nil) == pending && $0.installation.record.originalBundleIdentifier == originalIdentifier

		}
		return matches.count == 1 ? matches.first : nil
	}

	static func iconURL(_ app: AppInfoPresentable) -> URL? {
		guard app.isSigned, let id = app.uuid, UUID(uuidString: id) != nil else { return nil }
		let url = folder(id).appendingPathComponent("icon.png")
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	static func forget(_ app: AppInfoPresentable) {
		guard app.isSigned, let id = app.uuid, UUID(uuidString: id) != nil else { return }
		try? FileManager.default.removeItem(at: folder(id))
	}

	static func save(
		_ verified: ZagNativeInstalledProfiles, source: URL, name: String, renewing: Entry?,
		signedOnly: (ZagInstallExpectation, URL)? = nil
	) async throws {
		let storage = Storage.shared
		let request = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "identifier == %@", verified.record.bundleIdentifier)
		let existing = try storage.context.fetch(request).first {
			guard let entry = Self.entry($0) else { return false }
			if let renewing { return entry.uuid == renewing.uuid }
			return signedOnly == nil ? entry.pendingInstall == nil : entry.pendingInstall != nil
		}
		let id = renewing?.uuid ?? existing?.uuid ?? UUID().uuidString
		let destination = folder(id)
		let archive = destination.appendingPathComponent("Archive.ipa")
		let replacements = destination.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let manager = FileManager.default
		try manager.createDirectory(at: destination, withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
		var excluded = destination
		var values = URLResourceValues()
		values.isExcludedFromBackup = true
		try excluded.setResourceValues(values)

		if !manager.fileExists(atPath: archive.path) || renewing == nil {
			defer { try? manager.removeItem(at: replacements) }
			let newArchive = try await Task.detached(priority: .utility) {
				try ZagRPPairingFreeAccountInstaller.package(source, in: replacements)
			}.value
			try manager.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
				ofItemAtPath: newArchive.path)
			if manager.fileExists(atPath: archive.path) {
				_ = try manager.replaceItemAt(archive, withItemAt: newArchive)
			} else {
				try manager.moveItem(at: newArchive, to: archive)
			}
		}

		let icon = destination.appendingPathComponent("icon.png")
		if renewing == nil || !manager.fileExists(atPath: icon.path),
		   let image = await Task.detached(priority: .utility, operation: { iconTest(source)?.pngData() }).value {
			try? image.write(to: icon, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		}
		let version = Bundle(url: source)?.version ?? renewing?.version
		if let (_, signedApp) = signedOnly {
			let staged = folder(id)
			let destination = staged.appendingPathComponent("Signed.app")
			let temporary = staged.appendingPathComponent(UUID().uuidString)
			defer { try? manager.removeItem(at: temporary) }
			try await Task.detached(priority: .utility) { try manager.copyItem(at: signedApp, to: temporary) }.value
			if manager.fileExists(atPath: destination.path) {
				_ = try manager.replaceItemAt(destination, withItemAt: temporary)
			} else { try manager.moveItem(at: temporary, to: destination) }
		}
		let entry = Entry(uuid: id, name: name, version: version, installation: verified, pendingInstall: signedOnly?.0)
		let row = existing ?? Signed(context: storage.context)
		row.uuid = id
		row.identifier = verified.record.bundleIdentifier
		row.name = name
		row.version = version
		row.date = verified.record.signedAt
		row.certificate = nil
		try JSONEncoder().encode(entry).write(to: destination.appendingPathComponent("installation.json"),
			options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		do {
			try storage.context.save()
		} catch {
			if existing == nil { storage.context.delete(row) }
			throw error
		}

		if signedOnly == nil {
			try markInstalled(verified.record.bundleIdentifier)
			if renewing?.pendingInstall != nil {
				if let staged = signedApp(entry) { try? manager.removeItem(at: staged) }
				try removeSuperseded(by: entry)
			}
		}
		changes.send(id)
	}

	static func confirmProfileRefresh(_ original: Entry, profiles: [ZagIssuedProfile]) throws {
		guard var current = entry(original.uuid), current.pendingInstall == nil,
			  current.installation == original.installation,
			  let main = profiles.first(where: { $0.bundleIdentifier == current.installation.record.bundleIdentifier }),
			  profiles.count == current.installation.profiles.count,
			  let earliest = profiles.map(\.expiresAt).min() else { throw Failure.unverified }
		let updated = current.installation.profiles.compactMap { component -> ZagNativeInstalledProfiles.Component? in
			guard let profile = profiles.first(where: { $0.bundleIdentifier == component.bundleIdentifier }) else { return nil }
			var next = component
			next.uuid = profile.uuid
			next.expiresAt = profile.expiresAt
			return next
		}
		guard updated.count == profiles.count else { throw Failure.unverified }
		current.installation.record.owner?.profileUUID = main.uuid
		current.installation.record.profileExpiresAt = earliest
		current.installation.record.lastSuccessfulRefresh = Date()
		current.installation.record.expiryVerified = true
		current.installation = .init(record: current.installation.record, profiles: updated,
			executableIdentity: current.installation.executableIdentity)
		try JSONEncoder().encode(current).write(to: folder(current.uuid).appendingPathComponent("installation.json"),
			options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		changes.send(current.uuid)
	}

	static func signedApp(_ entry: Entry) -> URL? {
		let url = folder(entry.uuid).appendingPathComponent("Signed.app")
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	static func confirm(_ entry: Entry, expiry: Date, certificateExpiry: Date) throws {
		var updated = entry
		updated.pendingInstall = nil
		updated.installation.record.profileExpiresAt = expiry
		updated.installation.record.certificateExpiresAt = certificateExpiry
		updated.installation.record.expiryVerified = true
		try JSONEncoder().encode(updated).write(to: folder(entry.uuid).appendingPathComponent("installation.json"),
			options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		try markInstalled(updated.installation.record.bundleIdentifier)
		if let staged = signedApp(entry) { try? FileManager.default.removeItem(at: staged) }
		try removeSuperseded(by: updated)
		changes.send(entry.uuid)
	}

	private static func removeSuperseded(by entry: Entry) throws {
		let request = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "identifier == %@", entry.installation.record.bundleIdentifier)
		for row in try Storage.shared.context.fetch(request) where row.uuid != entry.uuid {
			guard let old = Self.entry(row), old.pendingInstall == nil,
				  old.installation.record.owner?.scope == entry.installation.record.owner?.scope else { continue }
			Storage.shared.deleteApp(for: row)
		}
	}

	private static func markInstalled(_ identifier: String) throws {
		let key = "zagStore.managedInstalledBundleIDs"
		let defaults = UserDefaults.standard
		var installed = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
		installed.insert(identifier)
		defaults.set(try JSONEncoder().encode(installed), forKey: key)
	}

	static func hasSource(_ entry: Entry) -> Bool {
		FileManager.default.fileExists(atPath: folder(entry.uuid).appendingPathComponent("Archive.ipa").path)
	}

	static func withSource<T>(_ entry: Entry, body: (URL) async throws -> T) async throws -> T {
		guard hasSource(entry) else { throw Failure.missingSource }
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: directory) }
		try await Task.detached(priority: .utility) {
			Zip.addCustomFileExtension("ipa")
			try Zip.unzipFile(folder(entry.uuid).appendingPathComponent("Archive.ipa"), destination: directory,
				overwrite: false, password: nil)
		}.value
		guard let app = FileManager.default.getPath(in: directory.appendingPathComponent("Payload"), for: "app") else {
			throw Failure.missingSource
		}
		return try await body(app)
	}
}
#endif
