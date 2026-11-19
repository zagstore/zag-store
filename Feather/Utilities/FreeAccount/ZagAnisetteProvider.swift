import Foundation

/// Anisette data: device-attestation headers that Apple's sign-in services
/// expect alongside each request. Zag Store treats them as opaque, short-lived
/// values: never persisted, never logged, and rejected when malformed.
struct ZagAnisetteData: Sendable, CustomStringConvertible {
	enum ValidationError: Error, Equatable {
		case empty
		case tooMany
		case badName
		case badValue
	}

	let headers: [String: String]
	let obtainedAt: Date

	/// At most 32 headers, each named `X-Apple-…` or `X-Mme-…` (any case), with
	/// a non-empty value of at most 4096 characters and no control characters.
	init(validating headers: [String: String], obtainedAt: Date) throws {
		guard !headers.isEmpty else { throw ValidationError.empty }
		guard headers.count <= 32 else { throw ValidationError.tooMany }
		for (name, value) in headers {
			let lower = name.lowercased()
			guard (lower.hasPrefix("x-apple-") || lower.hasPrefix("x-mme-")), name.count <= 64,
				  name.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != ":" }) else {
				throw ValidationError.badName
			}
			guard !value.isEmpty, value.count <= 4096,
				  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
				throw ValidationError.badValue
			}
		}
		self.headers = headers
		self.obtainedAt = obtainedAt
	}

	/// One-time values expire quickly; data older than this is not used.
	func isFresh(at now: Date, maximumAge: TimeInterval = 60) -> Bool {
		let age = now.timeIntervalSince(obtainedAt)
		return age >= -5 && age <= maximumAge
	}

	var description: String { "[anisette: \(headers.count) headers]" }
}

enum ZagAnisetteError: Error, Equatable, Sendable {
	case providerUnavailable
	case invalidResponse
	case timedOut
	case cancelled
	/// Live providers are not enabled in this build.
	case liveProvidersDisabled
}

/// Where anisette data comes from. Today: a remote server chosen by the user.
/// The other kinds keep the door open for a first-party service or a viable
/// on-device implementation without changing callers.
struct ZagAnisetteProviderConfiguration: Codable, Equatable, Sendable {
	enum Kind: String, Codable, Sendable {
		case remote
		case firstParty
		case onDevice
	}

	/// Whether Zag Store has reviewed the provider (security, availability,
	/// privacy, compatibility). Custom providers are the user's own choice.
	enum Evaluation: String, Codable, Sendable {
		case pending
		case approved
		case rejected
		case userSupplied
	}

	enum URLError: Error, Equatable {
		case notHTTPS
		case missingHost
		case containsCredentials
		case containsQueryOrFragment
	}

	let identifier: String
	let name: String
	let endpoint: URL?
	let kind: Kind
	let evaluation: Evaluation

	var host: String? { endpoint?.host?.lowercased() }

	/// A provider the user typed under Advanced. HTTPS only; no credentials,
	/// query or fragment; a trailing slash is removed.
	static func custom(_ text: String) throws -> ZagAnisetteProviderConfiguration {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https" else {
			throw URLError.notHTTPS
		}
		guard let host = components.host, !host.isEmpty else { throw URLError.missingHost }
		guard components.user == nil, components.password == nil else { throw URLError.containsCredentials }
		guard components.query == nil, components.fragment == nil else { throw URLError.containsQueryOrFragment }
		var normalised = components
		normalised.scheme = "https"
		normalised.host = host.lowercased()
		while normalised.path.hasSuffix("/") { normalised.path.removeLast() }
		guard let url = normalised.url else { throw URLError.missingHost }
		return ZagAnisetteProviderConfiguration(
			identifier: "custom:\(url.absoluteString)",
			name: host.lowercased(),
			endpoint: url,
			kind: .remote,
			evaluation: .userSupplied
		)
	}
}

enum ZagAnisetteProviderCatalogue {
	/// The candidate default for ordinary users: SideStore's public server
	/// (listed at servers.sidestore.io). Its evaluation is pending (see
	/// docs/free-developer-accounts/PHASE2.md); it is not used while live
	/// providers are disabled.
	static let recommended = ZagAnisetteProviderConfiguration(
		identifier: "sidestore-public",
		name: "SideStore public anisette server",
		endpoint: URL(string: "https://ani.sidestore.io"),
		kind: .remote,
		evaluation: .pending
	)
}

/// The user's provider choice. Not secret; stored in preferences.
struct ZagAnisetteProviderSettings: Codable, Equatable, Sendable {
	enum Choice: Codable, Equatable, Sendable {
		case recommended
		case custom(ZagAnisetteProviderConfiguration)
	}

	var choice: Choice = .recommended
	/// Whether a failing custom provider may fall back to the recommended one.
	/// Off by default: a different provider sees the device's anisette identity.
	var allowFallbackToRecommended = false

	var active: ZagAnisetteProviderConfiguration {
		switch choice {
		case .recommended: return ZagAnisetteProviderCatalogue.recommended
		case .custom(let configuration): return configuration
		}
	}

	/// Providers to try, in order. Rejected providers are never tried.
	var attemptOrder: [ZagAnisetteProviderConfiguration] {
		var order = [active]
		if allowFallbackToRecommended, active != ZagAnisetteProviderCatalogue.recommended {
			order.append(ZagAnisetteProviderCatalogue.recommended)
		}
		return order.filter { $0.evaluation != .rejected }
	}
}

/// Non-secret preferences, injectable for tests.
protocol ZagPreferenceStore: AnyObject {
	func data(forKey key: String) -> Data?
	func set(_ data: Data?, forKey key: String)
}

/// `UserDefaults` behind `ZagPreferenceStore` (a wrapper, so no overload is
/// added to `UserDefaults` itself).
final class ZagUserDefaultsPreferences: ZagPreferenceStore {
	private let defaults: UserDefaults

	init(_ defaults: UserDefaults = .standard) {
		self.defaults = defaults
	}

	func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

	func set(_ data: Data?, forKey key: String) {
		if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
	}
}

struct ZagAnisetteSettingsStore {
	static let key = "ZagStore.freeAccount.anisetteProvider.v1"
	let preferences: ZagPreferenceStore

	/// Unreadable settings fall back to the defaults rather than failing.
	func load() -> ZagAnisetteProviderSettings {
		guard let data = preferences.data(forKey: Self.key),
			  let settings = try? JSONDecoder().decode(ZagAnisetteProviderSettings.self, from: data) else {
			return ZagAnisetteProviderSettings()
		}
		return settings
	}

	func save(_ settings: ZagAnisetteProviderSettings) throws {
		preferences.set(try JSONEncoder().encode(settings), forKey: Self.key)
	}
}

protocol ZagAnisetteProvider: Sendable {
	var configuration: ZagAnisetteProviderConfiguration { get }
	func anisetteData() async throws -> ZagAnisetteData
}

/// Whatever supplies anisette to the authenticator (the broker, or a test double).
protocol ZagAnisetteSource: Sendable {
	func anisetteData() async throws -> ZagAnisetteData
}

enum ZagAnisetteLive {
	/// No live provider is implemented or enabled in this phase. Enabling one
	/// needs the provider evaluation and the supervised test plan.
	static let isEnabled = false
}

/// Stands in for every configured provider while live providers are disabled.
struct ZagDisabledAnisetteProvider: ZagAnisetteProvider {
	let configuration: ZagAnisetteProviderConfiguration
	func anisetteData() async throws -> ZagAnisetteData { throw ZagAnisetteError.liveProvidersDisabled }
}

/// Asks providers in the settings' order, each with a deadline, and keeps a
/// health record for diagnostics. Stale or malformed data is never returned.
actor ZagAnisetteBroker: ZagAnisetteSource {
	struct Health: Equatable, Sendable {
		var lastSuccess: Date?
		var lastFailure: Date?
		var lastError: ZagAnisetteError?
		var consecutiveFailures = 0
	}

	private let providers: [ZagAnisetteProvider]
	private let timeout: TimeInterval
	private let now: @Sendable () -> Date
	private(set) var health: [String: Health] = [:]

	init(providers: [ZagAnisetteProvider], timeout: TimeInterval = 15, now: @escaping @Sendable () -> Date = { Date() }) {
		self.providers = providers
		self.timeout = timeout
		self.now = now
	}

	/// Builds the providers for `settings`; `make` returns the live provider
	/// for a configuration, or nil when there is none.
	init(
		settings: ZagAnisetteProviderSettings,
		timeout: TimeInterval = 15,
		make: (ZagAnisetteProviderConfiguration) -> ZagAnisetteProvider? = { _ in nil }
	) {
		self.init(providers: settings.attemptOrder.map {
			(ZagAnisetteLive.isEnabled ? make($0) : nil) ?? ZagDisabledAnisetteProvider(configuration: $0)
		}, timeout: timeout)
	}

	func anisetteData() async throws -> ZagAnisetteData {
		var lastError = ZagAnisetteError.providerUnavailable
		for provider in providers {
			if Task.isCancelled { throw ZagAnisetteError.cancelled }
			let identifier = provider.configuration.identifier
			do {
				let data = try await ZagDeadline.run(seconds: timeout) { try await provider.anisetteData() }
				guard data.isFresh(at: now()) else { throw ZagAnisetteError.invalidResponse }
				health[identifier, default: Health()].lastSuccess = now()
				health[identifier]?.consecutiveFailures = 0
				health[identifier]?.lastError = nil
				return data
			} catch {
				let mapped = Self.map(error)
				if mapped == .cancelled || Task.isCancelled { throw ZagAnisetteError.cancelled }
				health[identifier, default: Health()].lastFailure = now()
				health[identifier]?.lastError = mapped
				health[identifier]?.consecutiveFailures += 1
				lastError = mapped
				// A disabled build has nothing else to try.
				if mapped == .liveProvidersDisabled { throw mapped }
			}
		}
		throw lastError
	}

	static func map(_ error: Error) -> ZagAnisetteError {
		switch error {
		case let error as ZagAnisetteError: return error
		case ZagTransportError.timedOut: return .timedOut
		case ZagTransportError.cancelled, is CancellationError: return .cancelled
		case is ZagAnisetteData.ValidationError: return .invalidResponse
		default: return .providerUnavailable
		}
	}
}
