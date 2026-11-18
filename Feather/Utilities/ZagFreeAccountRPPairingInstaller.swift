import Foundation
import Zip

/// Installs free-account apps through the existing RPPairing installer
/// (`installGate4IPA`), called exactly as the Library and Settings installs
/// call it; RPPairing itself is unchanged. Closed in this version: it refuses
/// while the free-account signing gate is closed.
///
/// Verification: the current RPPairing core lists installed apps (bundle ID,
/// version, signer) but cannot read installed provisioning profiles, so an
/// install is at best `.unverifiable` and a refresh is never reported as
/// successful from it. Reading the device's profiles needs the idevice
/// `misagent` service, which RPPairing does not build; see PHASE5.md.
struct ZagRPPairingFreeAccountInstaller: ZagFreeAccountInstaller {
	enum Failure: Error, Equatable {
		case disabled
		case packaging
		case install(String)
	}

	var gate = ZagFreeAccountSigningGate.production
	var workRoot = FileManager.default.temporaryDirectory

	func install(signedApp: URL, bundleIdentifier: String) async throws {
		guard gate.isOpen else { throw Failure.disabled }
		let staging = workRoot.appendingPathComponent("zag-free-account-install-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: staging) }
		let ipa = try Self.package(signedApp, in: staging)
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Task { @MainActor in
				do {
					try ZagRPPairingCore.shared.installGate4IPA(at: ipa) { result in
						continuation.resume(with: result.mapError { Failure.install($0.localizedDescription) })
					}
				} catch {
					continuation.resume(throwing: Failure.install(error.localizedDescription))
				}
			}
		}
	}

	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification {
		guard gate.isOpen else { return .unverifiable("free-account signing is disabled") }
		let listed: Result<ZagRPPairingCore.InstalledAppInfo?, Error> = await withCheckedContinuation { continuation in
			Task { @MainActor in
				do {
					try ZagRPPairingCore.shared.refreshInstalledApps { result in
						continuation.resume(returning: result.map { _ in ZagRPPairingCore.shared.installedApps[expectation.bundleIdentifier] })
					}
				} catch {
					continuation.resume(returning: .failure(error))
				}
			}
		}
		switch listed {
		case .failure:
			return .unverifiable("the device's app list could not be read")
		case .success(nil):
			return .notInstalled
		case .success(let app?):
			if let expected = expectation.signerCommonName, !app.signerIdentity.isEmpty, app.signerIdentity != expected {
				return .mismatch("signer")
			}
			// Present and signed by this certificate; the profile's expiry on
			// the device cannot be read with the current RPPairing core.
			return .unverifiable("installed; profile expiry cannot be read back")
		}
	}

	/// Payload/<App>.app, zipped, as `ArchiveHandler` packages an IPA.
	static func package(_ app: URL, in staging: URL) throws -> URL {
		let payload = staging.appendingPathComponent("Payload", isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
			try FileManager.default.copyItem(at: app, to: payload.appendingPathComponent(app.lastPathComponent))
			let zip = staging.appendingPathComponent("Archive.zip"), ipa = staging.appendingPathComponent("Archive.ipa")
			try Zip.zipFiles(paths: [payload], zipFilePath: zip, password: nil, compression: .DefaultCompression, progress: nil)
			try FileManager.default.moveItem(at: zip, to: ipa)
			return ipa
		} catch {
			throw Failure.packaging
		}
	}
}
