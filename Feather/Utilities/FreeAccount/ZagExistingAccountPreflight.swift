import Foundation

/// Pure, offline decision policy for a previously used Apple Account.
/// This type does not authenticate, contact Apple, or mutate developer assets.
/// An incomplete inventory is never interpreted as an empty inventory.
enum ZagExistingAccountPreflight {
    enum Inventory<Asset: Sendable>: Sendable {
        case unknown
        case complete([Asset])
    }

    struct Certificate: Sendable {
        let serial: String
        let expiresAt: Date
        /// Verified cryptographic possession of the matching private key,
        /// not merely presence of a certificate or matching subject name.
        let matchingPrivateKeyProven: Bool
    }

    struct Device: Sendable {
        let identifier: String
    }

    struct AppID: Sendable {
        let bundleIdentifier: String
    }

    struct Profile: Sendable {
        let bundleIdentifier: String
        let deviceIdentifiers: Set<String>
        let certificateSerial: String
        let expiresAt: Date
    }

    struct Snapshot: Sendable {
        let teamVerified: Bool
        let certificates: Inventory<Certificate>
        let devices: Inventory<Device>
        let appIDs: Inventory<AppID>
        let profiles: Inventory<Profile>
    }

    enum Decision: Equatable, Sendable {
        case blocked(String)
        case unknown
        case needsExplicitMutationApproval
        case reusePossible
    }

    /// This is only a local recommendation. It never authorises provisioning.
    static func evaluate(_ snapshot: Snapshot, bundleID: String,
                         verifiedLocalDeviceID: String, now: Date = Date()) -> Decision {
        guard snapshot.teamVerified else { return .unknown }
        guard !bundleID.isEmpty, !verifiedLocalDeviceID.isEmpty else {
            return .blocked("Missing verified app or local device identity")
        }
        guard case .complete(let certificates) = snapshot.certificates,
              case .complete(let devices) = snapshot.devices,
              case .complete(let appIDs) = snapshot.appIDs,
              case .complete(let profiles) = snapshot.profiles else {
            return .unknown
        }
        let matchingDevices = devices.filter { $0.identifier == verifiedLocalDeviceID }
        guard matchingDevices.count <= 1 else {
            return .blocked("Ambiguous device registration")
        }
        guard matchingDevices.count == 1 else { return .needsExplicitMutationApproval }
        guard appIDs.contains(where: { $0.bundleIdentifier == bundleID }) else {
            return .needsExplicitMutationApproval
        }
        let usableCertificates = certificates.filter {
            $0.matchingPrivateKeyProven && $0.expiresAt > now
        }
        guard !usableCertificates.isEmpty else { return .needsExplicitMutationApproval }
        let serials = Set(usableCertificates.map(\.serial))
        guard profiles.contains(where: {
            $0.bundleIdentifier == bundleID &&
            $0.deviceIdentifiers.contains(verifiedLocalDeviceID) &&
            serials.contains($0.certificateSerial) &&
            $0.expiresAt > now
        }) else { return .needsExplicitMutationApproval }
        return .reusePossible
    }
}
