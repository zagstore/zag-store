#if canImport(SwiftUI)
import SwiftUI

// Explicit, consent-gated entry to the one-time native ADI device provisioning.
// Registering this device's anisette machine with Apple is the single step here
// that contacts Apple, so it never happens on navigation or as a side effect:
// the user must read what will be sent, flip an explicit confirmation, and tap
// the action. Until both are true the action is disabled.
//
// This screen reaches the EXISTING provisioning mechanism (ZagAppleAuthMachine's
// on-device anisette/ADI path); it introduces no second mechanism. It performs no
// provisioning on its own and nothing is sent to Apple without the deliberate
// confirm-and-tap below.

@MainActor
final class ZagADIProvisioningConfirmModel: ObservableObject {
	@Published var confirmed = false
	@Published private(set) var isWorking = false
	@Published private(set) var status: String?
	@Published private(set) var alreadyProvisioned = false

	/// The native ADI machine. Reads its provisioning state from the Keychain
	/// locally (no network); provisioning itself is only triggered by `provision()`.
	private let machine = ZagAppleAuthMachine()

	func refresh() async {
		guard ZagAppleAuthMachine.isLinked else { return }
		alreadyProvisioned = await machine.isProvisioned()
		if alreadyProvisioned { status = "This device is already provisioned." }
	}

	/// Performs the one-time device provisioning. Reaches the existing machine's
	/// provisioning path; the caller guarantees the user explicitly confirmed.
	/// This contacts Apple, so it is invoked only from the gated button.
	func provision() async {
		guard confirmed, !isWorking, ZagAppleAuthMachine.isLinked else { return }
		isWorking = true
		defer { isWorking = false }
		do {
			// Reaches the existing on-device anisette/ADI path; allowProvisioning
			// lets it register this device if it is not provisioned yet. This is
			// the one call that contacts Apple, and only the gated button reaches it.
			_ = try await machine.anisetteHeaders(allowProvisioning: true)
			alreadyProvisioned = await machine.isProvisioned()
			status = alreadyProvisioned ? "Device provisioned." : "Provisioning did not complete; try again."
		} catch {
			status = "Provisioning could not be completed. Nothing was changed; you can retry."
		}
	}
}

struct ZagADIProvisioningConfirmView: View {
	@StateObject private var model = ZagADIProvisioningConfirmModel()
	@AppStorage("Feather.userTintColor") private var tintHex = "#0090FF"
	private var tint: Color { Color(hex: tintHex) }

	var body: some View {
		Form {
			Section {
				Label {
					VStack(alignment: .leading, spacing: 3) {
						Text("Register this device with Apple").font(.subheadline.weight(.medium))
						Text("Native signing needs a one-time anisette/ADI provisioning for this iPhone. It identifies this device to Apple so a development profile can later be issued.")
							.font(.caption).foregroundStyle(.secondary)
					}
				} icon: { Image(systemName: "cpu").foregroundStyle(tint) }
			} header: {
				Text("Device provisioning")
			}

			if model.alreadyProvisioned {
				Section {
					Label("This device is already provisioned.", systemImage: "checkmark.seal.fill")
						.font(.footnote).foregroundStyle(.green)
				}
			} else {
				Section {
					Toggle(isOn: $model.confirmed) {
						Text("I understand this contacts Apple to register this device.")
							.font(.footnote)
					}
					Button {
						Task { await model.provision() }
					} label: {
						HStack {
							Spacer()
							if model.isWorking { ProgressView() } else { Text("Provision This Device").fontWeight(.semibold) }
							Spacer()
						}
					}
					.disabled(!model.confirmed || model.isWorking)
				} footer: {
					Text("Nothing is sent until you confirm above and tap Provision. No certificate is created or revoked, no CSR is submitted and no app is signed by this step — it only registers the device. You can stop at any time.")
				}
			}

			if let status = model.status {
				Section { Label(status, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
			}
		}
		.navigationTitle("Set Up Device")
		.navigationBarTitleDisplayMode(.inline)
		.task { await model.refresh() }
	}
}
#endif
