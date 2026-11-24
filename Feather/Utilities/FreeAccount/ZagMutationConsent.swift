import Foundation

// The consent experience for account-mutating developer-services operations.
// Default-deny: nothing mutates the free Apple Account until the user authorizes
// the specific plan shown. Consent is collected UP FRONT for the whole plan (so
// the async provisioning path never blocks a cooperative thread), then each
// mutation checks the authorized set via `mayPerform(_:)`.

/// A human-readable title and consequence for each mutating operation, shown to
/// the user before authorization.
enum ZagMutationConsequence {
	static func describe(_ action: ZagDeveloperServicesAction) -> (title: String, consequence: String) {
		switch action {
		case .addDevice:
			return ("Register this device",
					"Adds this iPhone's identifier to your free Apple Account team. Free accounts allow only a limited number of devices.")
		case .addAppID:
			return ("Create an App ID",
					"Registers the app's bundle identifier with your team. Free accounts allow only a few App IDs per week.")
		case .submitCSR:
			return ("Issue a signing certificate",
					"Creates a development certificate for this device's private key. Free accounts allow a small number; an old one may need to be revoked.")
		case .downloadProfile:
			return ("Create a provisioning profile",
					"Generates a 7-day provisioning profile for this app on this device.")
		case .addAppGroup:
			return ("Create an app group", "Registers an application group with your team.")
		case .assignAppGroups:
			return ("Assign app groups", "Associates app groups with the App ID.")
		case .revokeCertificate:
			return ("Revoke a certificate",
					"Permanently revokes an existing development certificate. Apps signed with it stop working.")
		case .listTeams, .listDevices, .listCertificates, .listAppIDs, .listAppGroups, .listProfiles:
			return ("Read account state", "Reads existing account state only; changes nothing.")
		}
	}
}

/// Collects explicit, up-front authorization for a plan of mutating operations,
/// then answers `mayPerform(_:)` from the authorized set. Default-deny and
/// thread-safe: nothing is authorized until `authorize(_:)` is called for the
/// shown plan, and `cancel()` revokes everything.
final class ZagMutationConsentCoordinator: ZagAccountMutationConsent, @unchecked Sendable {
	private let lock = NSLock()
	private var authorized: Set<ZagDeveloperServicesAction> = []
	private var cancelled = false

	func mayPerform(_ action: ZagDeveloperServicesAction) -> Bool {
		lock.withLock { !cancelled && authorized.contains(action) }
	}

	/// Authorize exactly the shown plan (the mutating actions the user approved).
	func authorize(_ actions: Set<ZagDeveloperServicesAction>) {
		lock.withLock { authorized = actions.filter { $0.isMutating }; cancelled = false }
	}

	func cancel() { lock.withLock { cancelled = true; authorized = [] } }
}

#if canImport(SwiftUI)
import SwiftUI

/// Presents the planned account changes and their consequences, and collects a
/// single explicit authorization (or cancellation). Read-only steps are not
/// shown here — only the mutations that need consent.
struct ZagAccountMutationConsentView: View {
	let plan: [ZagDeveloperServicesAction]
	let onAuthorize: () -> Void
	let onCancel: () -> Void

	private var mutations: [ZagDeveloperServicesAction] { plan.filter { $0.isMutating } }

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Authorize account changes").font(.headline)
			Text("Zag Store will make these changes to your free Apple Account. Nothing happens until you authorize.")
				.font(.footnote).foregroundStyle(.secondary)
			ForEach(mutations, id: \.self) { action in
				let d = ZagMutationConsequence.describe(action)
				VStack(alignment: .leading, spacing: 2) {
					Text(d.title).font(.subheadline.weight(.semibold))
					Text(d.consequence).font(.caption).foregroundStyle(.secondary)
				}
			}
			HStack {
				Button("Cancel", role: .cancel, action: onCancel)
				Spacer()
				Button("Authorize", action: onAuthorize).buttonStyle(.borderedProminent)
			}
		}
		.padding()
	}
}
#endif
