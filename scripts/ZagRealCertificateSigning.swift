import Foundation
import Security

// Signs a copy of a built Zag Store with a real certificate, for
// scripts/test-zag-zsign-real-certificate.sh. The PKCS #12 password is read
// from standard input and never printed. Modes:
//   ordinary <app> <profile> <p12>        the app's existing AppTesters path (Zsign.sign)
//   strict <app> <profile> <p12> <keychain> Security framework key, Zsign.signComponents
//   check <profile> <p12>                 certificate import's revocation check
// Built twice: against the pinned Zsign (ordinary, check) and against the
// branch with ZAG_STRICT (all three).

@main
struct ZagRealCertificateSigning {
	/// Runs before exiting on failure (exit skips `defer`).
	nonisolated(unsafe) static var cleanup: () -> Void = {}

	static func fail(_ message: String) -> Never {
		print("FAIL: \(message)")
		cleanup()
		exit(1)
	}

	static func readPassword() -> String {
		guard let line = readLine(strippingNewline: true), !line.isEmpty else { fail("no password on standard input") }
		return line
	}

	static func profileEntitlements(_ profile: Data) -> Data {
		guard let start = profile.range(of: Data("<?xml".utf8)),
			  let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
			  let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
			  let entitlements = plist["Entitlements"],
			  let data = try? PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
		else { fail("the profile has no readable entitlements") }
		return data
	}

	static func main() {
		let args = CommandLine.arguments
		guard args.count >= 2 else { fail("usage: ordinary|strict|check …") }
		switch args[1] {
		case "ordinary" where args.count == 5:
			let password = readPassword()
			var reported: (Bool, String?) = (false, nil)
			// As ZsignHandler calls it with default options: Zsign's
			// `removeProvision: true` means the profile is embedded.
			let ok = Zsign.sign(appPath: args[2], provisionPath: args[3], p12Path: args[4], p12Password: password, removeProvision: true) { success, error in
				reported = (success, error?.localizedDescription)
			}
			guard ok, reported.0 else { fail("ordinary signing: \(reported.1 ?? "failed")") }
			print("PASS: ordinary signing (p12 and password, as certificate import uses them)")

		case "check" where args.count == 4:
			let password = readPassword()
			let done = DispatchSemaphore(value: 0)
			Zsign.checkRevokage(provisionPath: args[2], p12Path: args[3], p12Password: password) { status, expiry, error in
				// Status and the error text only; the expiry is reported as present or not.
				print("RESULT: status \(status), expiry \(expiry == nil ? "absent" : "present"), error \(error ?? "none")")
				done.signal()
			}
			if done.wait(timeout: .now() + 60) == .timedOut { fail("the revocation check did not finish") }

		#if ZAG_STRICT
		case "strict" where args.count == 6:
			strict(app: args[2], profilePath: args[3], p12Path: args[4], keychainPath: args[5], password: readPassword())
		#endif

		default:
			fail("unknown mode or wrong arguments")
		}
	}

	#if ZAG_STRICT
	/// Imports the identity into a throwaway keychain as a non-extractable key,
	/// signs through SecKeyCreateSignature only, and deletes the keychain.
	static func strict(app: String, profilePath: String, p12Path: String, keychainPath: String, password: String) {
		guard let profile = FileManager.default.contents(atPath: profilePath),
			  let p12 = FileManager.default.contents(atPath: p12Path) else { fail("inputs unreadable") }

		var keychain: SecKeychain?
		let keychainPassword = UUID().uuidString
		guard SecKeychainCreate(keychainPath, UInt32(keychainPassword.utf8.count), keychainPassword, false, nil, &keychain) == errSecSuccess,
			  let keychain else { fail("throwaway keychain not created") }
		cleanup = { SecKeychainDelete(keychain) }
		defer { cleanup() }

		// Present attributes are set; kSecAttrIsExtractable is left out, so the
		// imported private key cannot be exported.
		let passphrase = password as CFString
		let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
		var parameters = SecItemImportExportKeyParameters()
		parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
		parameters.passphrase = Unmanaged.passUnretained(passphrase)
		parameters.keyAttributes = Unmanaged.passUnretained(attributes)
		var format = SecExternalFormat.formatPKCS12
		var type = SecExternalItemType.itemTypeAggregate
		var items: CFArray?
		let status = withExtendedLifetime((passphrase, attributes)) {
			SecItemImport(p12 as CFData, "identity.p12" as CFString, &format, &type, [], &parameters, keychain, &items)
		}
		guard status == errSecSuccess else { fail("the identity was not imported (\(status))") }

		let query: [CFString: Any] = [
			kSecClass: kSecClassIdentity,
			kSecMatchSearchList: [keychain],
			kSecReturnRef: true,
			kSecMatchLimit: kSecMatchLimitOne,
		]
		var found: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let found,
			  CFGetTypeID(found) == SecIdentityGetTypeID() else { fail("no identity in the throwaway keychain") }
		let identity = found as! SecIdentity
		var certificate: SecCertificate?
		var key: SecKey?
		guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
			  SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else { fail("identity incomplete") }

		var exportError: Unmanaged<CFError>?
		if SecKeyCopyExternalRepresentation(key, &exportError) != nil { fail("the imported private key could be exported") }
		print("PASS: the private key is a non-extractable keychain key (export refused)")

		var signatures = 0
		let signer: (Data) -> Data? = { digestInfo in
			signatures += 1
			return SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15Raw, digestInfo as CFData, nil) as Data?
		}
		let components = ["": (provision: profile, entitlements: profileEntitlements(profile))]
		if let error = Zsign.signComponents(
			appPath: app, certificate: SecCertificateCopyData(certificate) as Data,
			signer: signer, components: components, bundleIdentifier: nil
		) {
			fail("strict signing: \(error)")
		}
		print("PASS: strict signing through SecKeyCreateSignature (\(signatures) signatures, no private key bytes in this process)")
		if let error = Zsign.verifyComponents(appPath: app, certificate: SecCertificateCopyData(certificate) as Data, components: components) {
			fail("strict verification: \(error)")
		}
		print("PASS: Zsign verifies the signed app against the profile and entitlements")
	}
	#endif
}
