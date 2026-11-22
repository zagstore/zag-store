import SwiftUI

/// The Signing screen's Signing Methods section: today only the paid
/// Developer Account method has a screen of its own. The Signing screen shows
/// this section only while `developerAccountEnabled` is set (never in a
/// release build).
struct ZagSigningMethodsSection: View {
	@State private var status = ZagDeveloperAccountStatus.notConnected

	var body: some View {
		Section {
			NavigationLink(destination: ZagDeveloperAccountScreen()) {
				VStack(alignment: .leading, spacing: 2) {
					Label(ZagSigningMethod.developerAccount.title, systemImage: "person.badge.key")
					Text(detail).font(.footnote).foregroundStyle(.secondary)
				}
			}
			.accessibilityIdentifier("settings.signing.developerAccount")
		} header: {
			Text("Signing Methods")
		} footer: {
			Text(ZagSigningMethod.developerAccount.summary)
		}
		.onAppear { status = Self.currentStatus() }
	}

	private var detail: String {
		let none = ZagSigningMethodAvailability.ImportedCertificates(total: 0, usable: 0, nearestExpiry: nil)
		switch ZagSigningMethodAvailability.status(of: .developerAccount, imported: none, freeAccount: .signedOut, developerAccount: status) {
		case .ready(let detail), .actionRequired(let detail), .external(let detail): return detail
		}
	}

	static func currentStatus() -> ZagDeveloperAccountStatus {
		guard let credential = try? ZagDeveloperAccountLive.store.load(account: ZagDeveloperAccountLive.account) else { return .notConnected }
		return credential.provisioningVerifiedAt == nil
			? .credentialsValidated(keyID: credential.keyID)
			: .provisioningVerified(keyID: credential.keyID)
	}
}

/// The Developer Account screen with the real dependencies.
private struct ZagDeveloperAccountScreen: View {
	@StateObject private var model = ZagDeveloperAccountLive.onboardingModel()
	@StateObject private var installer = ZagDeveloperAccountInstallModel(service: ZagDeveloperAccountLive.service())

	var body: some View {
		ZagDeveloperAccountOnboardingView(
			model: model, installer: installer,
			apps: { ZagDeveloperAccountLive.libraryApps() },
			device: { ZagDeveloperAccountLive.pairedDevice }
		)
	}
}
