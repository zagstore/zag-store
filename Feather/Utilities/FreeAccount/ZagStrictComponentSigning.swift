#if ZAG_ZSIGN_STRICT
import Foundation
#if canImport(ZsignSwift)
import ZsignSwift
#endif

// Signing the app and each extension with its own profile and entitlements,
// by a key that stays in its key store (Zsign's raw-signer callback), with
// every signed binary verified by Zsign before success. Zsign f34e51a
// provides the entry point; this path is compiled only with
// ZAG_ZSIGN_STRICT (tests and the supervised experiment build, never the
// Xcode project's configurations) until the live workflow is reviewed and
// approved.

extension ZagFreeAccountSigningAdapter {
	/// Extensions in the app (PlugIns/ and Extensions/), by bundle ID.
	static func extensionPaths(in app: URL) -> [String: String] {
		var paths: [String: String] = [:]
		for folder in ["PlugIns", "Extensions"] {
			let names = (try? FileManager.default.contentsOfDirectory(atPath: app.appendingPathComponent(folder).path)) ?? []
			for name in names where name.hasSuffix(".appex") {
				let path = "\(folder)/\(name)"
				if let identifier = bundleIdentifier(of: app.appendingPathComponent(path)) { paths[identifier] = path }
			}
		}
		return paths
	}

	/// Signs with the Keychain key item of the authorised account and the
	/// result's team; the key never leaves the Keychain.
	func signWithKeychainKey(
		appAt app: URL,
		with result: ZagProvisioningResult,
		identity: ZagSigningIdentity,
		authorization: ZagSigningAuthorization,
		now: Date
	) throws -> ZagSignedAppRecord {
		guard identity.keyIsInKeychain, let keychainKeys,
			  let key = try? keychainKeys.key(account: authorization.scope.accountID, team: result.team, slot: identity.keySlot) else {
			throw ZagFreeAccountSigningError.keychainKeyMissing
		}
		var intermediates: [Data] = []
		#if DEBUG
		intermediates = testIntermediates
		#endif
		return try signComponents(appAt: app, with: result, identity: identity, signer: ZagKeychainSigningKeys.signer(key),
								  authorization: authorization, now: now, extraIntermediates: intermediates)
	}

	func signComponents(
		appAt app: URL,
		with result: ZagProvisioningResult,
		identity: ZagSigningIdentity,
		signer: @escaping (Data) -> Data?,
		authorization: ZagSigningAuthorization,
		now: Date,
		extraIntermediates: [Data] = []
	) throws -> ZagSignedAppRecord {
		guard gate.isOpen else { throw ZagFreeAccountSigningError.disabled }
		guard authorization.isValid(at: now), authorization.scope.teamID == result.team else {
			throw ZagFreeAccountSigningError.notAuthorized
		}
		guard identity.serialNumber == result.certificateSerial else { throw ZagFreeAccountSigningError.identityMismatch }
		let found = Self.bundleIdentifier(of: app)
		guard found == result.app.originalBundleIdentifier || found == result.app.bundleIdentifier else {
			throw ZagFreeAccountSigningError.bundleMismatch(expected: result.app.originalBundleIdentifier, found: found)
		}

		// Every extension in the app has a provisioned component, and the
		// reverse; Zsign refuses anything else (Watch apps, App Clips, ...).
		let paths = Self.extensionPaths(in: app)
		let provisioned = Set(result.extensions.map(\.originalBundleIdentifier))
		guard Set(paths.keys) == provisioned else {
			throw ZagFreeAccountSigningError.extensionsNeedPerBundleSigning(Set(paths.keys).symmetricDifference(provisioned).sorted())
		}
		func plist(_ entitlements: ZagEntitlementSet) throws -> Data {
			try PropertyListSerialization.data(fromPropertyList: entitlements.dictionary, format: .xml, options: 0)
		}
		var components: [String: (provision: Data, entitlements: Data)] = [:]
		do {
			components[""] = (result.app.profile.data, try plist(result.app.entitlements))
			for component in result.extensions {
				components[paths[component.originalBundleIdentifier]!] = (component.profile.data, try plist(component.entitlements))
			}
		} catch {
			throw ZagFreeAccountSigningError.staging
		}

		if let failure = Zsign.signComponents(
			appPath: app.path, certificate: identity.certificate, keyData: nil, signer: signer,
			components: components, bundleIdentifier: result.app.bundleIdentifier, extraIntermediates: extraIntermediates
		) {
			throw ZagFreeAccountSigningError.signer(failure)
		}

		// Zsign verified every binary; check what iOS will read once more.
		guard Self.bundleIdentifier(of: app) == result.app.bundleIdentifier else {
			throw ZagFreeAccountSigningError.verification("bundle identifier")
		}
		for component in result.extensions {
			guard let path = paths[component.originalBundleIdentifier],
				  Self.bundleIdentifier(of: app.appendingPathComponent(path)) == component.bundleIdentifier else {
				throw ZagFreeAccountSigningError.verification("extension bundle identifier")
			}
		}
		return ZagSignedAppRecord(
			bundleIdentifier: result.app.bundleIdentifier,
			originalBundleIdentifier: result.app.originalBundleIdentifier,
			signedAt: now,
			profileExpiresAt: result.expiresAt,
			certificateExpiresAt: identity.expiresAt,
			owner: ZagAppOwnership(
				scope: authorization.scope,
				teamKind: authorization.teamKind,
				certificateSerial: identity.serialNumber,
				profileUUID: result.app.profile.uuid
			)
		)
	}
}
#endif
