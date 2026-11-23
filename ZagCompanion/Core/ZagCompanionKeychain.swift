import Foundation
import Security

// Read-only Keychain queries the companion needs: does an identity exist for a
// certificate serial, and which Apple Development teams are present. These read
// references only; no private key is ever read or exported.

public enum ZagCompanionKeychain {
	public struct TeamIdentity: Sendable { public let team: String; public let commonName: String; public let serial: String }

	/// All Apple Development identities, as (team, common name, serial).
	public static func appleDevelopmentTeams() -> [TeamIdentity] {
		var out: [TeamIdentity] = []
		for (cert, inspection) in identityCertificates() {
			guard let cn = inspection.commonName, cn.hasPrefix("Apple Development") else { continue }
			let team = teamIdentifier(of: cert) ?? ""
			out.append(TeamIdentity(team: team, commonName: cn, serial: inspection.serialNumber))
		}
		return out
	}

	/// Whether a Keychain identity exists for this certificate serial.
	public static func hasIdentity(serial: String) -> Bool {
		identityCertificates().contains { $0.1.serialNumber == serial }
	}

	// MARK: - Internals

	private static func identityCertificates() -> [(SecCertificate, ZagCertificateInspection)] {
		var result: CFTypeRef?
		let status = SecItemCopyMatching([
			kSecClass: kSecClassIdentity,
			kSecReturnRef: true,
			kSecMatchLimit: kSecMatchLimitAll,
		] as CFDictionary, &result)
		guard status == errSecSuccess, let identities = result as? [SecIdentity] else { return [] }
		var out: [(SecCertificate, ZagCertificateInspection)] = []
		for identity in identities {
			var certRef: SecCertificate?
			guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef,
				  let inspection = ZagCertificateInspection(der: SecCertificateCopyData(cert) as Data) else { continue }
			out.append((cert, inspection))
		}
		return out
	}

	/// The Organizational Unit (the team identifier) from a certificate's subject.
	private static func teamIdentifier(of cert: SecCertificate) -> String? {
		guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
			  let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
			  let entries = subject["value"] as? [[String: Any]] else { return nil }
		for entry in entries where (entry["label"] as? String) == (kSecOIDOrganizationalUnitName as String) {
			if let value = entry["value"] as? String { return value }
		}
		return nil
	}
}
