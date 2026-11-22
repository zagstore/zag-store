import Foundation
import Zip

/// Installs free-account apps through the existing RPPairing installer
/// (`installGate4IPA`), called exactly as the Library and Settings installs
/// call it; RPPairing itself is unchanged. Closed in this version: it refuses
/// while the free-account signing gate is closed.
///
/// Verification first checks the installed-app inventory, then reads the
/// device's provisioning profiles via the existing misagent reader. The
/// profile UUID, team, bundle identifier and expiry must match the expected
/// signed app before installation can be reported as verified.
/// The G5 experiment also records its separate four-way read-back result.
struct ZagRPPairingFreeAccountInstaller: ZagFreeAccountInstaller {
	enum Failure: Error, Equatable {
		case disabled
		case packaging
		case install(String)
	}

	var gate = ZagFreeAccountSigningGate.production
	var workRoot = FileManager.default.temporaryDirectory
	/// The paired device's profiles are read through misagent by default.
	/// Tests can replace the callback; nil intentionally disables read-back.
	var installedProfiles: (@Sendable () async -> Result<[Data], Error>)? = {
		await ZagRPPairingFreeAccountInstaller.readProfiles()
	}

	func install(signedApp: URL, bundleIdentifier: String) async throws {
		guard gate.isOpen else { throw Failure.disabled }
		#if ZAG_LIVE_EXPERIMENT
		try ZagLiveExperiment.campaign.authorize(.install)
		ZagLiveExperiment.logger?.record("install.start", outcome: "started", fields: ["transport": .string("rppairing"), "network": .string("other")])
		do {
			try await installThroughRPPairing(signedApp)
		} catch {
			// The device's own message is never recorded (logging spec §4.9).
			ZagLiveExperiment.logger?.record("install.result", outcome: "failed", failure: "install.refused",
											 fields: ["result": .string("refused"), "deviceErrorClass": .string("other")])
			ZagLiveExperiment.campaign.halt(.installRefused)
			throw error
		}
		ZagLiveExperiment.logger?.record("install.result", fields: ["result": .string("installed")])
		#else
		try await installThroughRPPairing(signedApp)
		#endif
	}

	private func installThroughRPPairing(_ signedApp: URL) async throws {
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
			// Presence alone is insufficient: use the device's actual installed
			// profile to verify the UUID, identity and expiry.
			guard let installedProfiles else { return .unverifiable("installed; profile expiry cannot be read back") }
			switch await installedProfiles() {
			case .success(let profiles): return ZagInstalledProfileCheck.verify(expectation, installedProfiles: profiles)
			case .failure: return .unverifiable("installed; the device's profiles could not be read")
			}
		}
	}

	/// Fetch the actual installed profiles through the existing, read-only
	/// RPPairing misagent transport. Never turn a failed read into success.
	static func readProfiles(deviceIP: String = ZagDeviceLink.peerAddress) async -> Result<[Data], Error> {
		await withCheckedContinuation { continuation in
			Task { @MainActor in
				ZagRPPairingCore.shared.readInstalledProfiles(deviceIP: deviceIP) { continuation.resume(returning: $0) }
			}
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

#if ZAG_LIVE_EXPERIMENT
extension ZagRPPairingFreeAccountInstaller {
	/// G5 (build plan P3): reads the device's installed profiles once and
	/// keeps the four results distinct. `unavailable` (nothing could be read)
	/// is never a success.
	static func experimentReadback(_ expectation: ZagInstallExpectation, deviceIP: String = ZagDeviceLink.peerAddress) async -> ZagExperimentReadback {
		ZagExperimentReadback.classify(read: await readProfiles(deviceIP: deviceIP), expectation: expectation)
	}

	/// §6: RPPairing's failure kinds in the closed failure enum (total).
	static func experimentFailure(_ kind: ZagRPPairingFailureKind) -> String {
		switch kind {
		case .pairingFile, .pairingRejected: "install.transport"
		case .deviceUnreachable, .connectionInterrupted, .sessionSetup: "install.transport"
		case .installation: "install.refused"
		case .other: "install.unknown"
		}
	}
}

/// G5 step 9: the experiment's installer. Installs through RPPairing and
/// verifies from the device's installed profiles (misagent), recording the
/// four read-back results; only `verified` is reported as verified.
struct ZagExperimentInstaller: ZagFreeAccountInstaller {
	private let read = ZagExperimentReadResult()

	func install(signedApp: URL, bundleIdentifier: String) async throws {
		try await installer.install(signedApp: signedApp, bundleIdentifier: bundleIdentifier)
	}

	func verify(_ expectation: ZagInstallExpectation) async -> ZagInstallVerification {
		let verification = await installer.verify(expectation)
		let result = ZagExperimentReadback.classify(verification, readSucceeded: read.succeeded)
		ZagLiveExperiment.logger?.record("install.verify", fields: ["result": .string(result.rawValue), "attempt": .int(1)])
		if result == .mismatch { ZagLiveExperiment.campaign.halt(.readbackMismatch) }
		if result == .notVerified { ZagLiveExperiment.campaign.halt(.readbackNotVerified) }
		return result == .verified ? verification : .unverifiable("experiment read-back: \(result.rawValue)")
	}

	private var installer: ZagRPPairingFreeAccountInstaller {
		var installer = ZagRPPairingFreeAccountInstaller()
		let read = read
		installer.installedProfiles = {
			let result = await ZagRPPairingFreeAccountInstaller.readProfiles()
			read.succeeded = (try? result.get()) != nil
			return result
		}
		return installer
	}
}

private final class ZagExperimentReadResult: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	var succeeded: Bool {
		get { lock.withLock { value } }
		set { lock.withLock { value = newValue } }
	}
}
#endif
