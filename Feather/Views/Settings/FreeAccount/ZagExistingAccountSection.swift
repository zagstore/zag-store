#if ZAG_EXISTING_ACCOUNT_EXPERIMENT
import SwiftUI

// G5 existing-account path (issue #37): the Live Test screen's inventory
// section. Only an existing-account experiment build compiles it.

/// The read-only inventory and the owner's approval of each change.
struct ZagExistingAccountSection: View {
	@ObservedObject var model: ZagLiveExperimentModel

	var body: some View {
		Section {
			Button("Read Account Inventory (read-only)") { Task { await model.readInventory() } }
				.disabled(!model.canRun || model.signIn?.phase != .signedIn)
			if let assessment = model.assessment {
				ForEach(assessment.report.lines, id: \.self) { Text($0).font(.caption) }
				Text("Decision: \(Self.describe(assessment.decision))").font(.footnote.bold())
				ForEach(assessment.required.sorted(), id: \.self) { mutation in
					Toggle(isOn: Binding(get: { model.approved.contains(mutation) }, set: { if $0 { model.approve(mutation) } })) {
						Text(Self.title(mutation)).font(.footnote)
					}
					.disabled(model.approved.contains(mutation))
				}
			}
		} header: {
			Text("Existing Account")
		} footer: {
			Text("Each approval allows that one change, once. Nothing is revoked or deleted, and a failed change is not retried.")
		}
	}

	static func title(_ mutation: ZagExistingAccountMutation) -> String {
		switch mutation {
		case .certificate: "Approve: request one new development certificate"
		case .device: "Approve: register this iPhone"
		case .appID: "Approve: register the test app's App ID"
		case .profile: "Approve: request the test app's provisioning profile"
		}
	}

	static func describe(_ decision: ZagExistingAccountPreflight.Decision) -> String {
		switch decision {
		case .reusePossible: "reuse possible (a profile is still needed)"
		case .needsNewAssets: "needs new assets (approve each below)"
		case .blocked(let blocker): "blocked (\(blocker.rawValue))"
		case .unknown(let what): "unknown (\(what.rawValue)); nothing can be changed"
		}
	}
}
#endif
