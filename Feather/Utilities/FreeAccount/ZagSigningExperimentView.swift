#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

// The supervised on-device driver for the first real signing experiment. The
// operator picks the encrypted .p12 and the provisioning profile, types the
// passphrase (SecureField, cleared after the run), and taps Run. Everything —
// import, CMS verification, preflight, Zsign signing and independent
// verification — happens on the device; the passphrase never leaves it. The
// result is a sanitized, screenshot-safe step list. Nothing is installed.

@MainActor
final class ZagSigningExperimentModel: ObservableObject {
	@Published var passphrase: String = ""
	@Published private(set) var report: ZagSigningExperimentReport?
	@Published private(set) var running = false
	@Published var pkcs12Name: String?
	@Published var profileName: String?
	private var pkcs12: Data?
	private var profile: Data?

	func chosePKCS12(_ url: URL) { (pkcs12, pkcs12Name) = read(url) }
	func choseProfile(_ url: URL) { (profile, profileName) = read(url) }

	/// Uses the app's own embedded profile (PTTeamProbe is provisioned with it).
	func useEmbeddedProfile() {
		if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") { choseProfile(url) }
	}

	private func read(_ url: URL) -> (Data?, String?) {
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		return ((try? Data(contentsOf: url)), url.lastPathComponent)
	}

	var canRun: Bool { pkcs12 != nil && profile != nil && !passphrase.isEmpty && !running }

	func run() {
		guard let pkcs12, let profile, let exe = Bundle.main.executableURL else { return }
		running = true
		let pass = passphrase
		let work = FileManager.default.temporaryDirectory.appendingPathComponent("zag-signing-experiment", isDirectory: true)
		try? FileManager.default.removeItem(at: work)
		try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
		DispatchQueue.global(qos: .userInitiated).async {
			let result = ZagSigningExperiment.run(pkcs12: pkcs12, passphrase: pass, profile: profile, workDir: work, sourceExecutable: exe)
			DispatchQueue.main.async {
				self.passphrase = ""          // clear the secret after the single run
				self.report = result
				self.running = false
			}
		}
	}
}

struct ZagSigningExperimentView: View {
	@StateObject var model = ZagSigningExperimentModel()
	@State private var pickingP12 = false
	@State private var pickingProfile = false

	var body: some View {
		Form {
			Section {
				Label("Supervised first real signing experiment. Signs a minimal dev.zagstore.ptteamprobe app with an imported identity. It does NOT install or launch anything.", systemImage: "flask")
					.font(.footnote)
			}
			Section("Inputs") {
				Button { pickingP12 = true } label: { Label(model.pkcs12Name ?? "Choose encrypted .p12…", systemImage: "key") }
				Button { pickingProfile = true } label: { Label(model.profileName ?? "Choose .mobileprovision…", systemImage: "doc.badge.gearshape") }
				Button("Use this app's embedded profile") { model.useEmbeddedProfile() }
				SecureField("PKCS#12 passphrase", text: $model.passphrase).textContentType(.password)
			}
			Section {
				Button(model.running ? "Running…" : "Run experiment") { model.run() }
					.disabled(!model.canRun)
			}
			if let report = model.report {
				Section("Result") {
					ForEach(Array(report.entries.enumerated()), id: \.offset) { _, e in
						Label { Text("\(e.step.rawValue): \(e.detail)").font(.footnote) }
						icon: { Image(systemName: e.ok ? "checkmark.circle" : "xmark.octagon").foregroundStyle(e.ok ? .green : .red) }
					}
					if let blocker = report.blocker {
						Label(blocker, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
					}
					if let ipa = report.signedIPAPath {
						Text("IPA: \(ipa)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
					}
					Label(report.readyForSeparatelyAuthorizedInstall ? "Signed IPA produced and independently verified — ready for a SEPARATELY AUTHORIZED install test." : "Not ready for install.",
						  systemImage: report.readyForSeparatelyAuthorizedInstall ? "checkmark.seal" : "nosign")
						.font(.footnote)
				}
			}
		}
		.fileImporter(isPresented: $pickingP12, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .data], allowsMultipleSelection: false) {
			if case .success(let urls) = $0, let u = urls.first { model.chosePKCS12(u) }
		}
		.fileImporter(isPresented: $pickingProfile, allowedContentTypes: [UTType(filenameExtension: "mobileprovision") ?? .data, .data], allowsMultipleSelection: false) {
			if case .success(let urls) = $0, let u = urls.first { model.choseProfile(u) }
		}
	}
}
#endif
