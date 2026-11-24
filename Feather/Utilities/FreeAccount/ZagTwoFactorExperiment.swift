import Foundation

// Supervised 2FA experiment — PREPARED, NOT WIRED TO ANY LIVE RUN.
//
// Scaffolding for completing a GrandSlam sign-in past the 2FA gate that E3
// Step B reached: request classification, separate per-class request ceilings,
// an explicit-consent + secure-code controller, and secure on-device session
// retention. None of this is reachable from a launch gate yet; a live 2FA run
// requires separate authorization and a gate added at that time. Nothing here
// requests, sends or submits a verification code on its own.

/// The purpose class of a GrandSlam request, so authentication, verification
/// initiation and code submission can carry separate ceilings (and so a
/// verification-delivery request can be gated on explicit consent).
enum ZagAppleAuthRequestClass: String, Sendable, Equatable {
	case authentication          // URL-bag lookup + GsService2 SRP (init/complete, incl. re-auth)
	case verificationInitiation  // secondaryAuth config, SMS delivery PUT, trusted-device push
	case codeSubmission          // verify/phone/securitycode, validateCode
	case other

	/// Classifies by URL (case-insensitive) and method. Order matters:
	/// code-submission endpoints are matched before the broader verification
	/// endpoints they are nested under.
	static func classify(url: String, method: String = "POST") -> ZagAppleAuthRequestClass {
		let u = url.lowercased()
		if u.contains("securitycode") || u.contains("validatecode") { return .codeSubmission }
		if u.contains("/verify/phone") || u.contains("secondaryauth") { return .verificationInitiation }
		if u.contains("lookup") || u.contains("gsservice2") { return .authentication }
		return .other
	}
}

/// Separate request ceilings per class, plus the explicit consent flag that
/// gates any verification-delivery request. Defaults cover the full flow:
/// authentication 5 (lookup + init + complete + the re-auth init/complete after
/// 2FA), verification initiation 2 (SMS config + delivery; 1 suffices for
/// trusted-device), code submission 1. Consent defaults to NOT granted.
struct ZagTwoFactorPolicy: Sendable, Equatable {
	var authenticationCeiling = 5
	var verificationInitiationCeiling = 2
	var codeSubmissionCeiling = 1
	var consentToDeliver = false

	func ceiling(for cls: ZagAppleAuthRequestClass) -> Int {
		switch cls {
		case .authentication: return authenticationCeiling
		case .verificationInitiation: return verificationInitiationCeiling
		case .codeSubmission: return codeSubmissionCeiling
		case .other: return 0
		}
	}

	/// Whether a request of `cls` is allowed, given how many of that class have
	/// already been accepted (0-based). A verification-delivery request also
	/// requires consent. Pure and total — the single enforcement decision.
	func allows(_ cls: ZagAppleAuthRequestClass, alreadyAccepted: Int) -> Bool {
		if cls == .verificationInitiation && !consentToDeliver { return false }
		return alreadyAccepted < ceiling(for: cls)
	}
}

/// Supplies the two human-in-the-loop decisions the 2FA flow needs: explicit
/// consent before any verification delivery, and the interactive code. A code
/// is never logged, persisted or defaulted. `nil`/false cancels cleanly.
protocol ZagTwoFactorController: AnyObject, Sendable {
	/// Must return true only after the user has explicitly consented to Apple
	/// delivering a verification code (SMS/trusted-device push).
	func consentToDeliver() -> Bool
	/// The six-digit code the user entered, or nil to cancel. Never stored.
	func provideCode() -> String?
	/// Set once the user cancels at any gate.
	var didCancel: Bool { get }
}

/// The safe default: denies consent and provides no code, so the flow cancels
/// cleanly and nothing is ever delivered or submitted without a real controller.
final class ZagDenyingTwoFactorController: ZagTwoFactorController, @unchecked Sendable {
	func consentToDeliver() -> Bool { false }
	func provideCode() -> String? { nil }
	var didCancel: Bool { true }
}

/// Secure on-device retention of a *successful* account session. The session
/// bytes are opaque and stored only in the this-device-only Keychain, exactly
/// like the machine profile; the DSID, GrandSlam token and any session field
/// are never logged, printed, returned to callers or exposed in diagnostics.
/// Callers learn only whether a session exists. (Retention is wired at the live
/// 2FA step; this store is not invoked by any current path.)
struct ZagAppleAuthSessionStore {
	private let service = "app.zagstore.anisette.appleauth.session.v1"
	private func query(_ scope: String) -> [String: Any] {
		[kSecClass as String: kSecClassGenericPassword,
		 kSecAttrService as String: service,
		 kSecAttrAccount as String: scope]
	}

	/// Whether a retained session exists for `scope` (no bytes returned).
	func hasSession(scope: String) -> Bool {
		var q = query(scope); q[kSecReturnData as String] = false
		return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
	}

	/// Store opaque session bytes (overwrites). The bytes are never logged.
	func save(_ data: Data, scope: String) throws {
		var add = query(scope)
		add[kSecValueData as String] = data
		add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		let status = SecItemAdd(add as CFDictionary, nil)
		if status == errSecSuccess { return }
		guard status == errSecDuplicateItem else { throw ZagAppleAuthError.keychain(status) }
		let update = [kSecValueData as String: data,
					  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as [String: Any]
		let s = SecItemUpdate(query(scope) as CFDictionary, update as CFDictionary)
		guard s == errSecSuccess else { throw ZagAppleAuthError.keychain(s) }
	}

	func delete(scope: String) throws {
		let s = SecItemDelete(query(scope) as CFDictionary)
		guard s == errSecSuccess || s == errSecItemNotFound else { throw ZagAppleAuthError.keychain(s) }
	}
}
