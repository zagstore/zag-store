import Combine
import Foundation

/// Presentation state for the Apple Account sign-in screen. Every action goes
/// through `ZagFreeAccountAuthenticator`; this type only mirrors its state.
///
/// The typed password and verification code live in the text fields only
/// until they are submitted: the password moves into a `ZagEphemeralSecret`
/// and both fields are cleared at once. Neither is written anywhere.
@MainActor
final class ZagFreeAccountSignInModel: ObservableObject {
	enum Phase: Equatable {
		case signedOut
		case working
		case awaitingCode
		case signedIn
		case expired
		case failed
	}

	@Published var appleID = ""
	@Published var password = ""
	@Published var code = ""
	@Published private(set) var state: ZagFreeAccountState = .signedOut
	@Published private(set) var prompt: ZagTwoFactorPrompt?
	@Published private(set) var isBusy = false
	/// A short message about the last action (a malformed code, a failed sign-out).
	@Published private(set) var notice: String?
	@Published private(set) var diagnosticEntries: [ZagFreeAccountDiagnostics.Entry] = []

	let authenticator: ZagFreeAccountAuthenticator
	private let diagnostics: ZagFreeAccountDiagnostics

	init(authenticator: ZagFreeAccountAuthenticator, diagnostics: ZagFreeAccountDiagnostics) {
		self.authenticator = authenticator
		self.diagnostics = diagnostics
	}

	var phase: Phase {
		switch state {
		case .signedOut: return .signedOut
		case .authenticating: return .working
		case .awaitingTwoFactor: return .awaitingCode
		case .signedIn: return .signedIn
		case .sessionExpired: return .expired
		case .failed: return .failed
		}
	}

	var failure: ZagFreeAccountFailure? {
		if case .failed(let failure) = state { return failure }
		return nil
	}

	var canSubmitCredentials: Bool {
		!isBusy && !appleID.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
			&& [.signedOut, .failed, .expired].contains(phase)
	}

	var canSubmitCode: Bool {
		guard let prompt, !isBusy else { return false }
		return ZagTwoFactorPrompt.normalisedCode(code, length: prompt.codeLength) != nil
	}

	// MARK: Actions

	func restore() async {
		_ = await authenticator.restore()
		await refresh()
	}

	func signIn() async {
		guard canSubmitCredentials else { return }
		let secret = ZagEphemeralSecret(password)
		password = ""
		notice = nil
		await perform { await $0.signIn(appleID: self.appleID.trimmingCharacters(in: .whitespaces), password: secret) }
	}

	func submitCode() async {
		guard let prompt, !isBusy else { return }
		let typed = code
		code = ""
		guard ZagTwoFactorPrompt.normalisedCode(typed, length: prompt.codeLength) != nil else {
			notice = "Enter the \(prompt.codeLength)-digit code."
			return
		}
		notice = nil
		await perform { await $0.submitCode(typed) }
	}

	func requestCodeBySMS() async {
		notice = nil
		await perform { await $0.requestCodeBySMS() }
	}

	/// Stops the running sign-in or the wait for a code. Runs alongside the
	/// action it cancels, so it does not wait for `isBusy`.
	func cancel() async {
		code = ""
		password = ""
		await authenticator.cancel()
		await refresh()
	}

	func checkSession() async {
		await perform { await $0.validateStoredSession() }
	}

	func signOut() async {
		code = ""
		password = ""
		do {
			try await authenticator.signOut()
			notice = nil
		} catch {
			notice = "Sign-out could not remove the stored session. Try again."
		}
		await refresh()
	}

	// MARK: Internals

	private func perform(_ action: @escaping (ZagFreeAccountAuthenticator) async -> ZagFreeAccountState) async {
		isBusy = true
		state = await authenticator.state
		_ = await action(authenticator)
		isBusy = false
		await refresh()
	}

	func refresh() async {
		state = await authenticator.state
		prompt = await authenticator.twoFactorPrompt
		diagnosticEntries = diagnostics.entries
	}
}
