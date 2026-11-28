#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

// User-initiated import of a password-protected PKCS#12 development identity.
// The passphrase and the .p12 bytes live only in memory and are cleared after
// use; nothing is written to a plaintext file and no password is logged. The
// user previews the certificate/team/expiry and confirms explicitly before the
// identity is stored (ThisDeviceOnly). The screen states plainly that an
// imported key is NOT a device-generated non-extractable key.

@MainActor
final class ZagImportedIdentityImportModel: ObservableObject {
	enum Phase: Equatable {
		case chooseFile
		case enterPassphrase(fileName: String)
		case previewed(ZagImportedIdentityInfo)
		case stored(ZagImportedIdentityInfo)
		case failed(String)
	}

	@Published private(set) var phase: Phase = .chooseFile
	@Published var passphrase: String = ""

	let expectedTeam: String?
	let label: String
	private var pkcs12: Data?            // in memory only; cleared after use

	init(expectedTeam: String?, label: String = "primary") {
		self.expectedTeam = expectedTeam
		self.label = label
	}

	/// Reads the chosen file into memory (security-scoped), never copying it to disk.
	func chose(_ url: URL) {
		let scoped = url.startAccessingSecurityScopedResource()
		defer { if scoped { url.stopAccessingSecurityScopedResource() } }
		guard let data = try? Data(contentsOf: url) else {
			phase = .failed("The file could not be read."); return
		}
		pkcs12 = data
		phase = .enterPassphrase(fileName: url.lastPathComponent)
	}

	/// Imports + validates WITHOUT storing, so the user can review before confirming.
	func preview() {
		guard let data = pkcs12 else { phase = .failed("No file selected."); return }
		switch ZagImportedSigningIdentity.importIdentity(pkcs12: data, password: passphrase) {
		case .failure:
			// A failed import is almost always a wrong passphrase; never echo it.
			phase = .failed("The password was incorrect or the file is not a valid identity.")
		case .success(let identity):
			switch ZagImportedSigningIdentity.validate(identity, expectedTeam: expectedTeam) {
			case .failure(let e): phase = .failed(Self.describe(e))
			case .success(let info): phase = .previewed(info)
			}
		}
	}

	/// Stores the previewed identity (ThisDeviceOnly) and clears all secrets.
	func confirmImport() {
		guard let data = pkcs12 else { phase = .failed("No file selected."); return }
		defer { passphrase = ""; pkcs12 = nil }   // clear secrets regardless of outcome
		guard case .success(let identity) = ZagImportedSigningIdentity.importIdentity(pkcs12: data, password: passphrase),
			  case .success(let info) = ZagImportedSigningIdentity.validate(identity, expectedTeam: expectedTeam) else {
			phase = .failed("The identity could not be re-validated for import."); return
		}
		let status = ZagImportedSigningIdentity.store(identity, label: label)
		phase = status == errSecSuccess ? .stored(info) : .failed("The identity could not be stored (\(status)).")
	}

	func cancel() {
		passphrase = ""; pkcs12 = nil; phase = .chooseFile
	}

	func removeStored() {
		ZagImportedSigningIdentity.delete(label: label)
		passphrase = ""; pkcs12 = nil; phase = .chooseFile
	}

	static func describe(_ e: ZagImportedIdentityError) -> String {
		switch e {
		case .wrongPasswordOrCorrupt: return "The password was incorrect or the file is not a valid identity."
		case .noIdentity: return "The file does not contain a usable signing identity."
		case .keyCertMismatch: return "The private key does not match its certificate."
		case .certExpired: return "This certificate has expired."
		case .notDevelopmentCertificate: return "This is not an Apple Development signing certificate."
		case .teamMismatch: return "This certificate belongs to a different team than this account."
		case .signFailed: return "The imported key could not produce a signature."
		case .keychainStoreFailed(let s): return "The identity could not be stored (\(s))."
		}
	}
}

struct ZagImportedIdentityImportView: View {
	@StateObject var model: ZagImportedIdentityImportModel
	@State private var picking = false

	private static let pkcs12Types: [UTType] = {
		[UTType(filenameExtension: "p12"), UTType(filenameExtension: "pfx"), UTType("com.rsa.pkcs-12")]
			.compactMap { $0 } + [.data]
	}()

	var body: some View {
		Form {
			Section {
				Label("An imported identity uses a key copied from another device. It is not a device-generated, non-extractable key, and has a different security posture. Prefer the on-device key where possible.",
					  systemImage: "exclamationmark.shield")
					.font(.footnote)
			}

			switch model.phase {
			case .chooseFile:
				Section("Import a signing identity") {
					Button { picking = true } label: { Label("Choose a .p12 / .pfx file…", systemImage: "doc.badge.plus") }
				}
			case .enterPassphrase(let fileName):
				Section("Passphrase for \(fileName)") {
					SecureField("PKCS#12 password", text: $model.passphrase)
						.textContentType(.password)
					Button("Preview identity") { model.preview() }
						.disabled(model.passphrase.isEmpty)
					Button("Cancel", role: .cancel) { model.cancel() }
				}
			case .previewed(let info):
				Section("Confirm this identity") {
					LabeledContent("Certificate", value: info.commonName)
					LabeledContent("Team", value: info.team ?? "—")
					LabeledContent("Serial", value: info.serialNumber)
					LabeledContent("Expires", value: info.notAfter.formatted(date: .abbreviated, time: .omitted))
					LabeledContent("Key") { Text(info.isNonExtractable ? "Non-extractable" : "Imported (extractable)").foregroundStyle(.secondary) }
				}
				Section {
					Button("Import this identity") { model.confirmImport() }
					Button("Cancel", role: .cancel) { model.cancel() }
				}
			case .stored(let info):
				Section {
					Label("Imported \(info.commonName)", systemImage: "checkmark.seal")
					Button("Remove imported identity", role: .destructive) { model.removeStored() }
				}
			case .failed(let message):
				Section {
					Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
					Button("Try again") { model.cancel() }
				}
			}
		}
		.fileImporter(isPresented: $picking, allowedContentTypes: Self.pkcs12Types, allowsMultipleSelection: false) { result in
			if case .success(let urls) = result, let url = urls.first { model.chose(url) }
		}
	}
}
#endif
