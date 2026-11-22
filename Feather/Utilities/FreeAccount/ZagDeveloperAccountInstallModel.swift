import Combine
import Foundation

/// Presentation state for installing one Library app with the connected
/// developer account: start, cancel, and a plain-language result. The work is
/// `ZagDeveloperAccountService.install`; this model only runs it in a task the
/// user can cancel and describes the outcome.
@MainActor
final class ZagDeveloperAccountInstallModel: ObservableObject {
	enum Phase: Equatable {
		case idle
		case running(appName: String)
		case finished(String, succeeded: Bool)
	}

	@Published private(set) var phase: Phase = .idle

	private let service: ZagDeveloperAccountService
	private var task: Task<Void, Never>?

	init(service: ZagDeveloperAccountService) {
		self.service = service
	}

	var isRunning: Bool {
		if case .running = phase { return true }
		return false
	}

	func start(_ app: ZagDeveloperAccountApp, on device: ZagTargetDevice?) {
		guard !isRunning else { return }
		guard let device else {
			phase = .finished("Pair this iPhone first (Settings › Pairing).", succeeded: false)
			return
		}
		phase = .running(appName: app.name)
		let service = service
		task = Task { [weak self] in
			let outcome = await service.install(app, on: device)
			self?.finish(outcome)
		}
	}

	/// Cancels the running install. Whatever Apple already created is reused
	/// by the next attempt; nothing is installed after a cancel.
	func cancel() {
		task?.cancel()
	}

	/// Waits for the running install (tests).
	func wait() async {
		await task?.value
	}

	private func finish(_ outcome: ZagDeveloperAccountService.Outcome) {
		task = nil
		phase = .finished(Self.message(for: outcome), succeeded: {
			if case .installed = outcome { return true }
			return false
		}())
	}

	nonisolated static func message(for outcome: ZagDeveloperAccountService.Outcome) -> String {
		switch outcome {
		case .installed(let record):
			return "Installed and verified on the device. It is signed until \(record.profileExpiresAt.formatted(date: .abbreviated, time: .omitted))."
		case .installedUnverified:
			return "Installed, but the device's profile could not be read back to confirm it."
		case .notConnected:
			return "Connect your App Store Connect API key first."
		case .unsupportedApp:
			return "This app has extensions or app groups, which Developer Account signing does not support yet."
		case .failed(let error):
			return message(for: error)
		}
	}

	nonisolated static func message(for error: ZagASCSigningError) -> String {
		switch error {
		case .disabled: return "Developer Account signing is not available in this version of Zag Store."
		case .cancelled: return "Cancelled. Nothing was installed; the next attempt continues where this one stopped."
		case .noIdentity: return "The signing certificate could not be read from this device's Keychain."
		case .signing: return "The app could not be signed."
		case .install: return "The device did not accept the app. Check that it is paired, unlocked and in Developer Mode."
		case .notVerified: return "The app was installed, but the device reports a different profile. Try again."
		case .profileReplacementBlocked(let names):
			return "Apple would not create a new profile while both of Zag Store's profiles for this app still exist. Nothing was deleted. "
				+ "Remove one of them (\(names.joined(separator: " or "))) under Profiles in the Apple Developer website, then try again."
		case .provisioning(let kind):
			switch kind {
			case .sessionRejected:
				return "App Store Connect refused this key. It may have been revoked, or it lacks the Admin role (Certificates, Identifiers & Profiles)."
			case .network, .timedOut: return "Zag Store could not reach App Store Connect. Check your connection and try again."
			case .rateLimited: return "App Store Connect is rate-limiting this key. Try again in a little while."
			case .cancelled: return "Cancelled. Nothing was installed; the next attempt continues where this one stopped."
			case .deviceLimitReached: return "Your team has reached its device limit for this membership year."
			case .certificateMustBeRevoked:
				return "Your team has reached its development certificate limit. Revoke one in the Apple Developer website, then try again."
			case .identifierUnavailable(let identifier): return "The bundle ID \(identifier) belongs to another team."
			case .keyStorage: return "The signing key could not be stored in this device's Keychain."
			case .invalidProfile: return "Apple issued a profile that does not match this app, device or certificate."
			default: return "App Store Connect returned something Zag Store does not understand."
			}
		}
	}
}
