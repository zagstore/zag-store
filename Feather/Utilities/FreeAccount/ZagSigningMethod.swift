import Foundation

/// The ways Zag Store can sign an app.
///
/// Imported certificates are signed on this device with Zsign. BYOC signs on
/// the Zag Store website with the user's own certificate, so the app only
/// links to it. Free Apple Account signing will create a development
/// certificate and profiles for the user's Personal Team and then sign with
/// the same Zsign path as imported certificates; it stays hidden until it can
/// sign and install end to end (`ZagSigningMethodAvailability.freeAccountEnabled`).
enum ZagSigningMethod: String, CaseIterable, Codable, Sendable {
	case freeAppleAccount
	case importedCertificate
	case byoc

	var title: String {
		switch self {
		case .freeAppleAccount: return "Free Apple Account"
		case .importedCertificate: return "Imported Certificate"
		case .byoc: return "BYOC"
		}
	}

	var summary: String {
		switch self {
		case .freeAppleAccount:
			return "Sign with your own Apple Account. Apps last 7 days and need refreshing."
		case .importedCertificate:
			return "Sign with a .p12 certificate and provisioning profile you already have."
		case .byoc:
			return "Bring your own certificate to the Zag Store website and install from there."
		}
	}

	/// Where signing happens. Apple Account credentials and signing keys for
	/// the free-account method never leave the device.
	var signsOnDevice: Bool { self != .byoc }
}

/// What the Signing Methods list shows for a method: whether it can sign now
/// and, if not, the one thing the user has to do. Only implemented methods
/// are ever listed.
enum ZagSigningMethodStatus: Equatable, Sendable {
	case ready(detail: String)
	case actionRequired(String)
	/// Signing happens elsewhere (BYOC on the website).
	case external(String)
}

enum ZagSigningMethodAvailability {
	/// Free Apple Account signing is not listed until authentication,
	/// provisioning, signing and installation all work against Apple's real
	/// services and a device (phases 2-4 of docs/free-developer-accounts).
	static let freeAccountEnabled = false

	/// Methods to list, in display order.
	static func listedMethods(freeAccountEnabled: Bool = freeAccountEnabled) -> [ZagSigningMethod] {
		ZagSigningMethod.allCases.filter { $0 != .freeAppleAccount || freeAccountEnabled }
	}

	/// Summary of the imported certificates, read from storage by the caller.
	struct ImportedCertificates: Equatable, Sendable {
		var total: Int
		var usable: Int
		var nearestExpiry: Date?
	}

	static func status(
		of method: ZagSigningMethod,
		imported: ImportedCertificates,
		freeAccount: ZagFreeAccountState,
		now: Date = Date()
	) -> ZagSigningMethodStatus {
		switch method {
		case .importedCertificate:
			guard imported.total > 0 else { return .actionRequired("Import a certificate") }
			guard imported.usable > 0 else {
				return .actionRequired("All certificates have expired or been revoked")
			}
			return .ready(detail: imported.usable == 1 ? "1 certificate" : "\(imported.usable) certificates")
		case .byoc:
			return .external("Signed on zagstore.app")
		case .freeAppleAccount:
			switch freeAccount {
			case .signedOut: return .actionRequired("Sign in with your Apple Account")
			case .authenticating: return .actionRequired("Signing in…")
			case .awaitingTwoFactor: return .actionRequired("Enter your verification code")
			case .sessionExpired: return .actionRequired("Sign in again")
			case .failed(let failure): return .actionRequired(failure.recovery)
			case .signedIn(let session): return .ready(detail: session.team.name)
			}
		}
	}
}
