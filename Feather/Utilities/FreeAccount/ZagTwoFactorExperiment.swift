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

	/// Classifies a request robustly, without depending on the opaque URL-bag
	/// values for the verification endpoints. The only URL fact relied upon is the
	/// hardcoded `/grandslam/GsService2` path (the URL-bag lookup and every SRP
	/// request, including the post-2FA re-auth). apple-auth issues no other
	/// request during login except the 2FA steps, so every non-GsService2 request
	/// is a verification step and is consent-gated. Code submission is identified
	/// by the SMS `securitycode` path or the trusted-device `security-code`
	/// request header — the two ways apple-auth carries the entered code.
	static func classify(url: String, method: String = "POST", hasSecurityCodeHeader: Bool = false) -> ZagAppleAuthRequestClass {
		let u = url.lowercased()
		// Code submission is checked FIRST: the trusted-device `validateCode`
		// endpoint is served under /grandslam/GsService2, so the code-carrying
		// request must be recognised before the GsService2 (authentication) rule,
		// or it would be mis-counted as authentication and exhaust that ceiling.
		if u.contains("securitycode") || hasSecurityCodeHeader { return .codeSubmission }
		if u.contains("/grandslam/gsservice2") { return .authentication }
		if u.hasPrefix("https://") { return .verificationInitiation }
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

	/// Load the opaque session bytes for `scope`, or nil. Used only to
	/// reconstruct the session for a developer-session exchange; never logged.
	func load(scope: String) -> Data? {
		var q = query(scope)
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
		return data
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

#if canImport(SwiftUI)
import SwiftUI

/// Drives the interactive, human-in-the-loop 2FA flow. The sign-in runs on a
/// background thread; this object blocks that thread at each decision point and
/// publishes the current stage to the SwiftUI view, which resolves it on the
/// main thread. Every blocking gate short-circuits to a cancelled result, so a
/// denial or a cancel can never let the flow proceed. A verification code lives
/// only in `codeResult` between submit and hand-off and is never logged,
/// persisted, echoed or placed in any report.
final class ZagTwoFactorCoordinator: ObservableObject, @unchecked Sendable {
	struct PhoneChoice: Identifiable, Equatable { let id: Int64; let display: String }

	enum Stage: Equatable {
		case idle
		case authenticating               // SRP in progress (no code can be delivered)
		case awaitingConsent              // asking BEFORE any verification delivery
		case selectingPhone([PhoneChoice])// SMS: user picks a trusted number
		case awaitingCode                 // delivery done; user enters the code
		case submitting                   // code handed off; completing
		case finished
		case cancelled
	}

	@Published private(set) var stage: Stage = .idle

	private let lock = NSLock()
	private var cancelledFlag = false
	private var consentDecided = false
	private var consentGranted = false
	private var phoneResult: Int64?
	private var codeResult: String?
	private let consentSem = DispatchSemaphore(value: 0)
	private let phoneSem = DispatchSemaphore(value: 0)
	private let codeSem = DispatchSemaphore(value: 0)

	var didCancel: Bool { lock.withLock { cancelledFlag } }

	// ---- called on the background (login) thread; each blocks until resolved ----

	/// Explicit consent before ANY verification-initiation request. Asked once;
	/// the decision is cached for the delivery request that follows the config
	/// fetch. Returns false immediately if already cancelled.
	func requestConsent() -> Bool {
		lock.lock()
		if cancelledFlag { lock.unlock(); return false }
		if consentDecided { let g = consentGranted; lock.unlock(); return g }
		lock.unlock()
		setStage(.awaitingConsent)
		consentSem.wait()
		return lock.withLock { consentGranted && !cancelledFlag }
	}

	/// Present the account's trusted numbers (item 8) and block for the choice.
	func selectPhone(_ phonesJSON: String) -> Int64? {
		if didCancel { return nil }
		let choices = Self.parseChoices(phonesJSON)
		setStage(.selectingPhone(choices))
		phoneSem.wait()
		return lock.withLock { cancelledFlag ? nil : phoneResult }
	}

	/// Block for the code the user enters in the SecureField (item 3). Cleared
	/// from the coordinator as soon as it is read.
	func provideCode() -> String? {
		if didCancel { return nil }
		setStage(.awaitingCode)
		codeSem.wait()
		return lock.withLock {
			defer { codeResult = nil }
			return cancelledFlag ? nil : codeResult
		}
	}

	// ---- called on the main thread by the view ----

	func begin() { setStage(.authenticating) }
	func markSubmitting() { setStage(.submitting) }
	func finish() { setStage(.finished) }

	func resolveConsent(_ granted: Bool) {
		lock.withLock { consentDecided = true; consentGranted = granted }
		consentSem.signal()
	}
	func resolvePhone(_ id: Int64?) {
		lock.withLock { phoneResult = id }
		phoneSem.signal()
	}
	/// Submit the entered code (a separate, explicit user action). Never logged.
	func submitCode(_ code: String) {
		lock.withLock { codeResult = code }
		codeSem.signal()
	}

	/// Cancel from any stage: all pending and future gates resolve to cancelled,
	/// so no verification can be initiated or submitted.
	func cancel() {
		lock.withLock {
			cancelledFlag = true
			consentDecided = true; consentGranted = false
			phoneResult = nil; codeResult = nil
		}
		consentSem.signal(); phoneSem.signal(); codeSem.signal()
		setStage(.cancelled)
	}

	private func setStage(_ s: Stage) { DispatchQueue.main.async { self.stage = s } }

	/// Parses apple-auth's phone-choice JSON (`[{id, display_number}]`) into
	/// view choices. Tolerant of the field spellings the C API documents.
	static func parseChoices(_ json: String) -> [PhoneChoice] {
		guard let data = json.data(using: .utf8),
			  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
		return arr.compactMap { item in
			guard let id = (item["id"] as? NSNumber)?.int64Value else { return nil }
			let display = (item["display_number"] as? String) ?? (item["numberWithDialCode"] as? String) ?? "•••"
			return PhoneChoice(id: id, display: display)
		}
	}
}
#endif
