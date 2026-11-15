import Foundation

/// Local cleanup only. Never represents, requests or confirms device-side revocation.
struct ZagLocalPairingRemoval {
    static let pendingKey = "ZagStore.localPairingCleanupPending"
    static let systemRemovalInstructions = "Open the paired-device list in Settings (Privacy & Security → Developer Mode, or Developer → Paired Computers on some versions). Select only Zag Store, open its details, and tap Unpair."
    static let localOnlyMessage = "Local credentials removed. iOS trust has not been revoked or verified by Zag Store. Remove Zag Store's paired-device entry in Settings to finish unpairing."

    enum Outcome: Equatable { case localCredentialsRemoved }
    enum Failure: LocalizedError {
        case incomplete
        var errorDescription: String? {
            "Some local pairing files could not be removed. Local cleanup is incomplete and iOS trust has not been revoked. Retry Local Cleanup before pairing again."
        }
    }

    struct Environment {
        let exists: (URL) throws -> Bool
        let remove: (URL) throws -> Void
        let setPending: (Bool) -> Void
    }
    let pairingRecord: URL
    let hostIdentity: URL
    let env: Environment

    @discardableResult func run() throws -> Outcome {
        // Persist intent before touching either file. Interrupted/partial cleanup
        // stays recoverable, even if the main credential was already removed.
        env.setPending(true)
        var failed = false
        for file in [pairingRecord, hostIdentity] {
            do {
                if try env.exists(file) { try env.remove(file) }
            } catch {
                // Still attempt the other exact file. A permission/read error is
                // never treated as evidence that credentials are absent.
                failed = true
            }
        }
        do {
            let recordRemains = try env.exists(pairingRecord)
            let identityRemains = try env.exists(hostIdentity)
            guard !failed, !recordRemains, !identityRemains else { throw Failure.incomplete }
        } catch { throw Failure.incomplete }
        env.setPending(false)
        return .localCredentialsRemoved
    }
    static func fileExists(_ file: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: file.path)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return false
        }
    }

    static func removeFile(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let kind = attributes[.type] as? FileAttributeType,
              kind == .typeRegular || kind == .typeSymbolicLink else { throw Failure.incomplete }
        // Remove a file/link only, never recursively delete a directory.
        try FileManager.default.removeItem(at: file)
    }

}
