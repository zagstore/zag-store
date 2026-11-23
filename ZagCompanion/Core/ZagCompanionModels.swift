import Foundation

// Value types shared by the Zag Companion core service and its SwiftUI app.
// The core never holds Apple Account credentials, passwords, 2FA codes or
// private-key bytes: a signing identity is always a Keychain reference.

/// A paired/connected iOS device, as `devicectl` reports it.
public struct ZagCompanionDevice: Identifiable, Hashable, Sendable {
	/// CoreDevice identifier (what `devicectl --device` takes). Not the UDID.
	public let id: String
	public let name: String
	public let model: String
	/// Hardware UDID (what a provisioning profile registers). Empty if unknown.
	public let udid: String
	public let connected: Bool

	public init(id: String, name: String, model: String, udid: String, connected: Bool) {
		self.id = id; self.name = name; self.model = model; self.udid = udid; self.connected = connected
	}
}

/// A code-signing team available on this Mac. A free Personal Team has
/// `isFree == true` and the 7-day / per-device / per-App-ID limits.
public struct ZagCompanionTeam: Identifiable, Hashable, Sendable {
	public var id: String { identifier }
	public let identifier: String
	public let name: String
	public let isFree: Bool
	public init(identifier: String, name: String, isFree: Bool) {
		self.identifier = identifier; self.name = name; self.isFree = isFree
	}
}

/// What was read from a selected IPA.
public struct ZagCompanionIPAInfo: Sendable {
	public let url: URL
	public let bundleIdentifier: String
	public let displayName: String
	public let version: String
	/// Extension bundle IDs inside the app (PlugIns/Extensions). A free team
	/// needs each provisioned for its own App ID; the companion refuses apps
	/// whose extensions it cannot provision.
	public let extensionBundleIdentifiers: [String]
	public init(url: URL, bundleIdentifier: String, displayName: String, version: String, extensionBundleIdentifiers: [String]) {
		self.url = url; self.bundleIdentifier = bundleIdentifier; self.displayName = displayName
		self.version = version; self.extensionBundleIdentifiers = extensionBundleIdentifiers
	}
}

/// Where the workflow is, for the UI's progress display.
public enum ZagCompanionStage: String, Sendable {
	case idle, detectingDevice, identifyingTeam, readingIPA, resolvingProfile
	case provisioning, signing, verifying, installing, launching, done, failed
}

public struct ZagCompanionProgress: Sendable {
	public var stage: ZagCompanionStage
	public var message: String
	/// 0...1; -1 for indeterminate.
	public var fraction: Double
	public init(_ stage: ZagCompanionStage, _ message: String, _ fraction: Double = -1) {
		self.stage = stage; self.message = message; self.fraction = fraction
	}
}

/// An app Zag Companion installed and can renew. Holds only renewal metadata —
/// never key material or account secrets.
public struct ZagManagedApp: Codable, Identifiable, Hashable, Sendable {
	public var id: String { "\(bundleIdentifier)@\(deviceUDID)" }
	public let bundleIdentifier: String
	public let displayName: String
	public let deviceUDID: String
	public let deviceName: String
	public let teamIdentifier: String
	/// The IPA the app was installed from, re-signed on renewal.
	public let sourceIPAPath: String
	public var certificateSerial: String
	public var profileExpiresAt: Date
	public var installedAt: Date
	public var lastRenewedAt: Date?

	public init(bundleIdentifier: String, displayName: String, deviceUDID: String, deviceName: String,
				teamIdentifier: String, sourceIPAPath: String, certificateSerial: String,
				profileExpiresAt: Date, installedAt: Date, lastRenewedAt: Date? = nil) {
		self.bundleIdentifier = bundleIdentifier; self.displayName = displayName
		self.deviceUDID = deviceUDID; self.deviceName = deviceName; self.teamIdentifier = teamIdentifier
		self.sourceIPAPath = sourceIPAPath; self.certificateSerial = certificateSerial
		self.profileExpiresAt = profileExpiresAt; self.installedAt = installedAt; self.lastRenewedAt = lastRenewedAt
	}

	/// Days until the profile expires (negative once expired).
	public var daysUntilExpiry: Int {
		Int((profileExpiresAt.timeIntervalSinceNow / 86_400).rounded(.down))
	}
	public var isExpired: Bool { profileExpiresAt <= Date() }
	/// A free profile is short-lived; renew within this window of expiry.
	public var needsRenewalSoon: Bool { daysUntilExpiry <= 2 }
}

public enum ZagCompanionError: Error, CustomStringConvertible {
	case noDeviceConnected
	case deviceHasNoUDID(String)
	case noPersonalTeam
	case ipaUnreadable(String)
	case ipaHasNoApp
	case unprovisionableExtensions([String])
	case noUsableProfile(bundleID: String, device: String)
	case provisioningRefused(String)
	case signingFailed(String)
	case verificationFailed(String)
	case installFailed(String)
	case launchFailed(String)
	case toolFailed(tool: String, status: Int32, output: String)
	case unknownManagedApp(String)

	public var description: String {
		switch self {
		case .noDeviceConnected: return "No connected iPhone found. Connect and unlock the device, and trust this Mac."
		case let .deviceHasNoUDID(d): return "Could not read the UDID of \(d)."
		case .noPersonalTeam: return "No free Apple Account \"Personal Team\" is available in Xcode. Sign in in Xcode > Settings > Accounts."
		case let .ipaUnreadable(m): return "The IPA could not be read: \(m)"
		case .ipaHasNoApp: return "The IPA contains no Payload/*.app bundle."
		case let .unprovisionableExtensions(ids): return "This app has extensions a free team cannot provision in v0.1: \(ids.joined(separator: ", "))"
		case let .noUsableProfile(b, d): return "No valid provisioning profile covers \(b) on device \(d), and new provisioning was not authorised."
		case let .provisioningRefused(m): return "Xcode provisioning failed: \(m)"
		case let .signingFailed(m): return "Signing with Zag Store's engine failed: \(m)"
		case let .verificationFailed(m): return "Verification of the signed app failed: \(m)"
		case let .installFailed(m): return "Installation on the device failed: \(m)"
		case let .launchFailed(m): return "Launch failed: \(m)"
		case let .toolFailed(tool, status, output): return "\(tool) exited \(status): \(output.suffix(400))"
		case let .unknownManagedApp(id): return "No managed app \(id)."
		}
	}
}
