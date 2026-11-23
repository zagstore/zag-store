import Foundation

// Unpacking, inspecting and repacking IPAs. An IPA is a zip whose Payload/
// holds one .app; the companion signs that .app in place and repacks.

public enum ZagIPA {
	/// Unzips the IPA into `workDir` and returns the Payload/*.app it contains.
	/// `workDir` ends up holding the `Payload` folder, ready to repack.
	@discardableResult
	public static func unpack(_ ipa: URL, into workDir: URL) throws -> URL {
		try? FileManager.default.removeItem(at: workDir)
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
		let result = ZagProcess.run("/usr/bin/unzip", ["-q", ipa.path, "-d", workDir.path])
		guard result.succeeded else { throw ZagCompanionError.ipaUnreadable(result.combined) }
		return try appInPayload(workDir)
	}

	/// The .app under `<dir>/Payload`.
	public static func appInPayload(_ dir: URL) throws -> URL {
		let payload = dir.appendingPathComponent("Payload")
		let contents = (try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? []
		guard let app = contents.first(where: { $0.hasSuffix(".app") }) else { throw ZagCompanionError.ipaHasNoApp }
		return payload.appendingPathComponent(app)
	}

	/// Reads an IPA's bundle ID, name, version and extension bundle IDs without
	/// keeping the unpacked copy.
	public static func info(_ ipa: URL) throws -> ZagCompanionIPAInfo {
		let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zag-ipa-info-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: tmp) }
		let app = try unpack(ipa, into: tmp)
		let (bundleID, name, version) = try readInfoPlist(app)
		let extIDs = extensionBundleIDs(in: app)
		return ZagCompanionIPAInfo(url: ipa, bundleIdentifier: bundleID, displayName: name,
								   version: version, extensionBundleIdentifiers: extIDs)
	}

	/// Reads CFBundleIdentifier / display name / version from an .app's Info.plist.
	public static func readInfoPlist(_ app: URL) throws -> (bundleID: String, name: String, version: String) {
		let plistURL = app.appendingPathComponent("Info.plist")
		guard let data = try? Data(contentsOf: plistURL),
			  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
			  let bundleID = plist["CFBundleIdentifier"] as? String else {
			throw ZagCompanionError.ipaUnreadable("missing or unreadable Info.plist")
		}
		let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
		let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? ""
		return (bundleID, name, version)
	}

	/// Extension bundle IDs in PlugIns/ and Extensions/.
	public static func extensionBundleIDs(in app: URL) -> [String] {
		var ids: [String] = []
		for folder in ["PlugIns", "Extensions"] {
			let dir = app.appendingPathComponent(folder)
			let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
			for name in names where name.hasSuffix(".appex") {
				if let (id, _, _) = try? readInfoPlist(dir.appendingPathComponent(name)) { ids.append(id) }
			}
		}
		return ids
	}

	/// Repacks `<workDir>/Payload` into an IPA at `output`.
	public static func repack(workDir: URL, to output: URL) throws {
		try? FileManager.default.removeItem(at: output)
		let result = ZagProcess.run("/usr/bin/zip", ["-qry", output.path, "Payload"], currentDirectory: workDir)
		guard result.succeeded else { throw ZagCompanionError.ipaUnreadable("repack failed: \(result.combined)") }
	}
}
