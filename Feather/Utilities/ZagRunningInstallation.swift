import SwiftUI
import Security
import Combine

/// A projection of the running bundle for the existing Apps row. Renewal
/// ownership and expiry still live in the normal signing receipts.
struct ZagRunningApp: AppInfoPresentable {
	let uuid: String?
	var name: String? { "Zag Store" }
	var identifier: String? { Bundle.main.bundleIdentifier }
	var version: String? { Bundle.main.version }
	var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
	var date: Date? { nil }
	var icon: String? { nil }
	var isSigned: Bool { true }
}

@MainActor
final class ZagRunningInstallation: ObservableObject {
	static let shared = ZagRunningInstallation()

	@Published private(set) var method: ZagRunningSigningMethod = .unknown
	@Published private(set) var expiry: Date?
	@Published private(set) var recovery: String?
	@Published private(set) var nativeUUID: String?
	@Published private(set) var inspecting = false
	private(set) var importedCertificate: CertificatePair?
	private var inspection: Task<Void, Never>?
	#if canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
	private var observations: Set<AnyCancellable> = []

	private struct Evidence: Sendable {
		let signer: Data
		let team: String
		let expiration: Date
		let matchesRenewalReceipt: Bool
		let renewedCertificateExpiry: Date?
		let distribution: Bool
	}

	private var evidence: Evidence?
	private var attempted = false

	private init() {
		ZagNativeAppInventory.changes.sink { [weak self] id in
			guard let self, id == self.nativeUUID else { return }
			self.expiry = self.nativeReceipt?.installation.record.expiresAt ?? self.evidence?.expiration
		}.store(in: &observations)
	}

	func inspect(verifyPersonal: Bool = false, retry: Bool = false) async {
		if let inspection { await inspection.value }
		if !attempted || retry {
			attempted = true
			inspecting = true
			let task = Task {
				let cached = self.nativeReceipt?.installation
				self.evidence = await Task.detached(priority: .utility) { Self.readEvidence(cached) }.value
				self.applyEvidence()
			}
			inspection = task
			await task.value
			inspection = nil
			inspecting = false
		} else if verifyPersonal {
			applyEvidence()
		}

		guard verifyPersonal, method == .personal, nativeUUID == nil, !inspecting,
			  let evidence, let scope = ZagNativeAccountInstall.runningSigningScope(signer: evidence.signer, team: evidence.team) else { return }
		guard ZagNativeAccountInstall.hasConnectedAccount(scope.accountID) else {
			recovery = "Sign in with the Apple ID that signed this installation."
			return
		}
		guard ZagRPPairingCore.shared.hasSavedPairing else {
			recovery = "Set up installation pairing to verify renewable profiles."
			return
		}
		inspecting = true
		defer { inspecting = false }
		do {
			try await ZagNativeAccountInstall.verifyRunningInstallation()
			// Recheck actual code against the newly enrolled receipt.
			let cached = nativeReceipt?.installation
			self.evidence = await Task.detached(priority: .utility) { Self.readEvidence(cached) }.value
			applyEvidence()
		} catch let failure as ZagNativeAccountInstall.SelfRenewalFailure {
			recovery = failure.localizedDescription
		} catch {
			recovery = "Check LocalDevVPN and installation pairing, then retry verification."
		}
	}

	private var nativeReceipt: ZagNativeAppInventory.Entry? {
		Bundle.main.bundleIdentifier.flatMap { ZagNativeAppInventory.entry(bundleIdentifier: $0) }
	}

	private func applyEvidence() {
		guard attempted else { return }
		guard let evidence else {
			method = .unknown
			expiry = nil
			nativeUUID = nil
			importedCertificate = nil
			recovery = "Zag Store could not match its signed code to an authentic provisioning profile."
			return
		}
		let candidates = Storage.shared.getAllCertificates().filter { !$0.revoked }
		importedCertificate = candidates.first { pair in
			guard let file = Storage.shared.getFile(.certificate, from: pair),
				  let bytes = try? Data(contentsOf: file),
				  let identity = try? ZagImportedSigningIdentity.importIdentity(pkcs12: bytes, password: pair.password ?? "").get()
			else { return false }
			var cert: SecCertificate?
			return SecIdentityCopyCertificate(identity, &cert) == errSecSuccess &&
				cert.map { SecCertificateCopyData($0) as Data } == evidence.signer
		}
		let kinds = (try? ZagNativeAppleIDs.shared.catalog().accounts) ?? []
		let teamKinds = kinds.flatMap(\.teams).filter { $0.identifier == evidence.team }.map(\.kind)
		let renewed = nativeReceipt.flatMap { entry -> ZagNativeAppInventory.Entry? in
			guard let identity = entry.installation.executableIdentity, identity.certificate == evidence.signer,
				  identity.version == Bundle.main.version, identity.build == runningApp.build,
				  entry.pendingInstall == nil, entry.installation.record.expiryVerified == true,
				  entry.installation.record.owner?.teamKind == .personalFree, evidence.matchesRenewalReceipt
			else { return nil }
			return entry
		}
		method = ZagRunningSigningMethod.identify(imported: importedCertificate != nil && renewed == nil,
			personal: renewed != nil || teamKinds.contains(.personalFree),
			paid: teamKinds.contains(.individualPaid) || teamKinds.contains(.organization), distribution: evidence.distribution)
		nativeUUID = renewed?.uuid
		expiry = renewed?.installation.record.expiresAt ?? evidence.expiration
		recovery = nil
		if method == .imported || method == .certificate {
			expiry = max(evidence.expiration, evidence.renewedCertificateExpiry ?? evidence.expiration)
		}
		if let owner = renewed?.installation.record.owner,
		   !ZagNativeAccountInstall.hasConnectedAccount(owner.scope.accountID) {
			recovery = "Sign in with the original Apple ID before refreshing Zag Store."
		} else if method == .personal, nativeUUID == nil {
			recovery = "Verify the original Apple ID and its signing certificate to enable profile renewal."
		} else if method == .unknown {
			recovery = "The profile is verified, but no local account or imported certificate identifies its signing method."
		}
	}

	nonisolated private static func readEvidence(_ receipt: ZagNativeInstalledProfiles?) -> Evidence? {
		let root = Bundle.main.bundleURL
		guard let executable = Bundle.main.executableURL,
			  let binary = try? Data(contentsOf: executable, options: .mappedIfSafe),
			  let signers = ZagCodeSignatureInspection.signerCertificates(in: binary),
			  let signer = signers.first, signers.allSatisfy({ $0 == signer }),
			  let cert = ZagCertificateInspection(der: signer), let team = cert.organizationalUnit,
			  let components = try? ZagNativeAccountInstall.runningComponents(certificate: signer) else { return nil }
		let stored = ZagCertificateProfileReceipt.runningReceipt()
		let replacement = stored.flatMap { value -> ZagProfileContents? in
			guard value.runningBundleIdentifier == Bundle.main.bundleIdentifier,
				  value.runningVersion == Bundle.main.version,
				  value.runningBuild == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
				  let decoded = try? ZagCMSVerifier.verify(value.profile).get(),
				  let profile = ZagMobileProvision.parseUnverified(decoded),
				  profile.teamIdentifier == team, profile.developerCertificates.contains(signer) else { return nil }
			return profile
		}
		var coversReplacement = replacement != nil
		var expiry = cert.expiresAt
		for path in [""] + ZagFreeAccountSigningAdapter.nestedBundles(in: root) {
			let bundle = path.isEmpty ? root : root.appendingPathComponent(path)
			guard let id = Bundle(url: bundle)?.bundleIdentifier, let raw = components[id],
				  let entitlements = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any],
				  let data = try? Data(contentsOf: bundle.appendingPathComponent("embedded.mobileprovision")),
				  let decoded = try? ZagCMSVerifier.verify(data).get(),
				  let profile = ZagMobileProvision.parseUnverified(decoded),
				  let issued = try? ZagIssuedProfile(profileData: decoded),
				  profile.teamIdentifier == team, profile.developerCertificates.contains(signer),
				  ZagImportedIdentityProfileMatch.bundleMatches(target: id, applicationIdentifier: profile.applicationIdentifier, team: team),
				  ZagEntitlementAudit.disallowed(requested: entitlements.mapValues(ZagEntitlementValue.init),
					granted: profile.entitlements).isEmpty else { return nil }
			expiry = min(expiry, issued.expiresAt)
			if let replacement {
				coversReplacement = coversReplacement &&
					ZagImportedIdentityProfileMatch.bundleMatches(target: id, applicationIdentifier: replacement.applicationIdentifier, team: team) &&
					ZagEntitlementAudit.disallowed(requested: entitlements.mapValues(ZagEntitlementValue.init),
						granted: replacement.entitlements).isEmpty
			}
		}
		let receiptMatches = receipt.map { ZagNativeAccountInstall.matchesRunningComponents(components, receipt: $0) } ?? false
		let name = cert.commonName ?? ""
		let distribution = name.hasPrefix("Apple Distribution:") || name.hasPrefix("iPhone Distribution:")
		return Evidence(signer: signer, team: team, expiration: expiry, matchesRenewalReceipt: receiptMatches,
			renewedCertificateExpiry: coversReplacement ? stored.map { min($0.effectiveExpiration, cert.expiresAt) } : nil,
			distribution: distribution)
	}
	#else
	private init() {}
	func inspect(verifyPersonal: Bool = false, retry: Bool = false) async {}
	#endif

	var runningApp: ZagRunningApp {
		ZagRunningApp(uuid: nativeUUID ?? "running:\(Bundle.main.bundleIdentifier ?? "ZagStore")")
	}

	func certificateDidRenew(to expiry: Date) { self.expiry = expiry }
}
