import Foundation

/// Apple's published limits for free provisioning (Personal Team), from
/// https://developer.apple.com/support/compare-memberships (checked
/// 18 November 2026). They are used only to explain capacity before Apple is
/// asked; Apple's own answer always wins, and profile and certificate expiry
/// dates are read from the files, never assumed.
enum ZagFreeAccountLimits {
	/// "The number of App IDs that can be registered to your account at one
	/// time is limited to 10 and each expires after 7 days."
	static let appIDsAtOnce = 10
	static let appIDLifetime: TimeInterval = 7 * 86_400
	/// "The number of test devices that can be registered to your account for
	/// each platform is limited to 3."
	static let devicesPerPlatform = 3
	/// "You can install up to 3 apps per device" (stated on Apple's localised
	/// versions of the page). Zag Store itself counts when it is signed with
	/// the same free account.
	static let appsPerDevice = 3
}

/// How much is known about a limited resource.
struct ZagCapacity: Equatable, Sendable {
	enum Source: String, Sendable {
		/// Counted from Apple's own list, fetched at `syncedAt`.
		case apple
		/// Never listed from Apple: the figure must not be shown as a count.
		case unknown
	}

	let source: Source
	let used: Int
	let limit: Int
	/// When the next slot frees up, if one is in use and its expiry is known.
	let nextSlotFreesAt: Date?

	var available: Int { max(0, limit - used) }

	static func unknown(limit: Int) -> ZagCapacity {
		ZagCapacity(source: .unknown, used: 0, limit: limit, nextSlotFreesAt: nil)
	}
}

// MARK: - Bundle identifiers

/// Free provisioning cannot register an App ID that another team already
/// owns, so every app gets a team-specific bundle ID. The mapping is
/// deterministic, so a refresh always reuses the App ID from the first install
/// and the app keeps its data.
enum ZagBundleIdentifierMapping {
	static func isValid(_ identifier: String) -> Bool {
		guard !identifier.isEmpty, identifier.utf8.count <= 155 else { return false }
		let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
		return components.allSatisfy { component in
			!component.isEmpty && component.unicodeScalars.allSatisfy {
				("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
			}
		}
	}

	/// "com.example.app" → "com.example.app.ABCDE12345". Idempotent.
	static func mapped(_ original: String, team: String) -> String? {
		guard isValid(original), ZagDeveloperTeam.isValidIdentifier(team) else { return nil }
		if original.hasSuffix("." + team) { return original }
		let result = original + "." + team
		return isValid(result) ? result : nil
	}

	/// An extension keeps its position under the app: with the app mapped to
	/// "com.example.app.TEAM", "com.example.app.widget" becomes
	/// "com.example.app.TEAM.widget". An extension outside the app's prefix is
	/// mapped on its own.
	static func mappedExtension(_ original: String, appOriginal: String, team: String) -> String? {
		guard isValid(original), let app = mapped(appOriginal, team: team) else { return nil }
		if original.hasPrefix(app + ".") { return original }
		guard original.hasPrefix(appOriginal + ".") else { return mapped(original, team: team) }
		let result = app + original.dropFirst(appOriginal.count)
		return isValid(result) ? result : nil
	}

	/// "group.com.example" → "group.com.example.TEAM". App group IDs must
	/// start with "group.".
	static func mappedAppGroup(_ original: String, team: String) -> String? {
		guard original.hasPrefix("group."), original.count > 6 else { return nil }
		return mapped(original, team: team)
	}
}

// MARK: - App IDs

/// An App ID registered on the team.
struct ZagRegisteredAppID: Codable, Equatable, Sendable {
	let identifier: String
	let bundleIdentifier: String
	/// From Apple when it reports one; otherwise nil.
	let expiresAt: Date?
	let appGroupsEnabled: Bool?

	init(identifier: String, bundleIdentifier: String, expiresAt: Date?, appGroupsEnabled: Bool? = nil) {
		self.identifier = identifier
		self.bundleIdentifier = bundleIdentifier
		self.expiresAt = expiresAt
		self.appGroupsEnabled = appGroupsEnabled
	}

	func isActive(at now: Date) -> Bool {
		guard let expiresAt else { return true }
		return expiresAt > now
	}
}

/// The App IDs an install or refresh needs, and whether they fit.
struct ZagAppIDPlan: Equatable, Sendable {
	enum Outcome: Equatable, Sendable {
		/// Every bundle ID already has an active App ID.
		case reuseAll
		/// These bundle IDs need new App IDs, and they fit (or capacity is unknown).
		case register([String])
		/// They do not fit until `nextSlotFreesAt`. Nothing is revoked automatically.
		case capacityExhausted(needed: Int, available: Int, nextSlotFreesAt: Date?)
	}

	let outcome: Outcome
	let capacity: ZagCapacity

	/// `bundleIdentifiers` are the mapped IDs of the app and each extension.
	/// `registered` is Apple's list, or nil when it has not been fetched.
	static func make(
		bundleIdentifiers: [String],
		registered: [ZagRegisteredAppID]?,
		limit: Int = ZagFreeAccountLimits.appIDsAtOnce,
		now: Date
	) -> ZagAppIDPlan {
		let active = registered?.filter { $0.isActive(at: now) } ?? []
		let existing = Set(active.map(\.bundleIdentifier))
		var missing: [String] = []
		for identifier in bundleIdentifiers where !existing.contains(identifier) && !missing.contains(identifier) {
			missing.append(identifier)
		}
		// The listing is an inventory, not a quota response. Preserve undated
		// rows for reuse, but don't count them as active quota usage. Apple
		// decides whether a new ID fits when the list cannot establish capacity.
		let capacity: ZagCapacity
		if registered == nil || active.contains(where: { $0.expiresAt == nil }) {
			capacity = .unknown(limit: limit)
		} else {
			let expiries = Dictionary(grouping: active, by: \.bundleIdentifier).values.compactMap {
				$0.compactMap(\.expiresAt).max()
			}
			capacity = ZagCapacity(source: .apple, used: existing.count, limit: limit, nextSlotFreesAt: expiries.min())
		}
		if missing.isEmpty { return ZagAppIDPlan(outcome: .reuseAll, capacity: capacity) }
		guard missing.count <= capacity.available else {
			return ZagAppIDPlan(
				outcome: .capacityExhausted(
					needed: missing.count,
					available: capacity.available,
					nextSlotFreesAt: capacity.nextSlotFreesAt
				),
				capacity: capacity
			)
		}
		return ZagAppIDPlan(outcome: .register(missing), capacity: capacity)
	}
}

// MARK: - Certificates

/// A development certificate on the team, as Apple lists it.
struct ZagDevelopmentCertificate: Codable, Equatable, Sendable {
	let serialNumber: String
	let name: String
	let machineName: String?
	let expiresAt: Date
	/// The certificate (DER), when the portal's listing includes it. Only then
	/// can a certificate whose issue response was lost be recognised by its key.
	var data: Data? = nil
}

/// Whether to reuse a certificate or create one. Creating a certificate is
/// avoided whenever a valid one exists whose private key is on this device,
/// and a certificate is never revoked without the user choosing it.
enum ZagCertificatePlan: Equatable, Sendable {
	case reuse(serialNumber: String)
	case create
	/// Apple's certificate limit is reached; the user picks one to revoke.
	case userMustRevoke(candidates: [ZagDevelopmentCertificate])

	/// - Parameters:
	///   - localKeySerials: certificates whose private key is in this device's Keychain.
	///   - limit: Apple's development-certificate limit, if Apple has reported
	///     it (it is not published). With nil, Zag Store asks Apple to create
	///     one and reports Apple's refusal.
	///   - minimumRemaining: a certificate that expires sooner than this is not
	///     reused, so a new profile is not cut short by it.
	static func make(
		remote: [ZagDevelopmentCertificate],
		localKeySerials: Set<String>,
		limit: Int?,
		minimumRemaining: TimeInterval = 7 * 86_400,
		now: Date
	) -> ZagCertificatePlan {
		let valid = remote.filter { $0.expiresAt > now }
		if let reusable = valid
			.filter({ localKeySerials.contains($0.serialNumber) && $0.expiresAt.timeIntervalSince(now) >= minimumRemaining })
			.max(by: { $0.expiresAt < $1.expiresAt }) {
			return .reuse(serialNumber: reusable.serialNumber)
		}
		if let limit, valid.count >= limit {
			return .userMustRevoke(candidates: valid.sorted { $0.expiresAt < $1.expiresAt })
		}
		return .create
	}
}

// MARK: - Devices and installed apps

enum ZagDeviceRegistrationPlan: Equatable, Sendable {
	case alreadyRegistered
	case register
	case limitReached(registered: Int)

	/// UDIDs are compared without case: Apple and lockdown differ in case.
	static func make(
		udid: String,
		registeredUDIDs: [String],
		limit: Int = ZagFreeAccountLimits.devicesPerPlatform
	) -> ZagDeviceRegistrationPlan {
		let target = udid.lowercased()
		let registered = Set(registeredUDIDs.map { $0.lowercased() })
		if registered.contains(target) { return .alreadyRegistered }
		return registered.count >= limit ? .limitReached(registered: registered.count) : .register
	}
}

enum ZagInstallSlotPlan: Equatable, Sendable {
	/// Refreshing or reinstalling an app that is already installed needs no new slot.
	case replacesInstalledApp
	case fits(remainingAfterInstall: Int)
	case full(installed: [String])

	/// `installedFreeAccountApps` are the bundle IDs on the device signed by
	/// this free team (from the device's installed-app list).
	static func make(
		installing bundleIdentifier: String,
		installedFreeAccountApps: Set<String>,
		limit: Int = ZagFreeAccountLimits.appsPerDevice
	) -> ZagInstallSlotPlan {
		if installedFreeAccountApps.contains(bundleIdentifier) { return .replacesInstalledApp }
		let used = installedFreeAccountApps.count
		guard used < limit else { return .full(installed: installedFreeAccountApps.sorted()) }
		return .fits(remainingAfterInstall: limit - used - 1)
	}
}
