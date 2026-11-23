import Foundation

/// Build gate for the on-device apple-auth anisette/ADI provider. Off in
/// production: the provider is available only in an explicit experiment build
/// (`ZAG_APPLE_AUTH_ADI`), and even then the broker uses it only when
/// `ZagAnisetteLive` is enabled. Production free-account authentication stays
/// disabled until the remaining live gates (GrandSlam sign-in) pass.
enum ZagAppleAuthADI {
	#if ZAG_APPLE_AUTH_ADI
	static let isEnabled = true
	#else
	static let isEnabled = false
	#endif
}

extension ZagAnisetteProviderCatalogue {
	/// The on-device provider: apple-auth's Mac-algorithm ADI, provisioned and
	/// kept on this device. No remote anisette server, no Android library, no
	/// Unicorn, no desktop companion. Evaluation is pending the sign-in gate.
	static let onDevice = ZagAnisetteProviderConfiguration(
		identifier: "apple-auth-on-device",
		name: "On-device (apple-auth)",
		endpoint: nil,
		kind: .onDevice,
		evaluation: .pending
	)
}

/// A `ZagAnisetteProvider` backed by the on-device apple-auth machine. Each
/// call derives fresh `X-Apple-*` / `X-Mme-*` anisette headers from the
/// provisioned profile and wraps them in a validated, short-lived
/// `ZagAnisetteData`. Deriving headers never contacts Apple; `allowProvisioning`
/// (an authorised live step only) permits a one-time provisioning exchange when
/// no profile exists yet.
struct ZagOnDeviceAnisetteProvider: ZagAnisetteProvider {
	let configuration: ZagAnisetteProviderConfiguration
	private let machine: ZagAppleAuthMachine
	private let allowProvisioning: Bool
	private let now: @Sendable () -> Date

	init(configuration: ZagAnisetteProviderConfiguration = ZagAnisetteProviderCatalogue.onDevice,
		 machine: ZagAppleAuthMachine = ZagAppleAuthMachine(),
		 allowProvisioning: Bool = false,
		 now: @escaping @Sendable () -> Date = { Date() }) {
		self.configuration = configuration
		self.machine = machine
		self.allowProvisioning = allowProvisioning
		self.now = now
	}

	func anisetteData() async throws -> ZagAnisetteData {
		guard ZagAppleAuthMachine.isLinked else { throw ZagAnisetteError.liveProvidersDisabled }
		do {
			let headers = try await machine.anisetteHeaders(allowProvisioning: allowProvisioning)
			return try ZagAnisetteData(validating: headers, obtainedAt: now())
		} catch let error as ZagAppleAuthError {
			switch error {
			case .unavailable: throw ZagAnisetteError.liveProvidersDisabled
			case .notProvisioned, .transportBlocked: throw ZagAnisetteError.providerUnavailable
			case .malformedHeaders: throw ZagAnisetteError.invalidResponse
			case .provisioningFailed, .keychain: throw ZagAnisetteError.providerUnavailable
			}
		} catch let error as ZagAnisetteData.ValidationError {
			_ = error
			throw ZagAnisetteError.invalidResponse
		}
	}
}

/// Builds the live anisette provider for a configuration. For the on-device
/// kind it returns the apple-auth provider only when the module is linked and
/// the ADI experiment is enabled; otherwise nil, so the broker falls back to
/// the disabled provider. Pass this as the broker's `make` closure.
enum ZagAnisetteProviderFactory {
	static func make(_ configuration: ZagAnisetteProviderConfiguration,
					 allowProvisioning: Bool = false) -> ZagAnisetteProvider? {
		switch configuration.kind {
		case .onDevice:
			guard ZagAppleAuthADI.isEnabled, ZagAppleAuthMachine.isLinked else { return nil }
			return ZagOnDeviceAnisetteProvider(configuration: configuration, allowProvisioning: allowProvisioning)
		case .remote, .firstParty:
			return nil   // remote/first-party providers are wired elsewhere
		}
	}
}
