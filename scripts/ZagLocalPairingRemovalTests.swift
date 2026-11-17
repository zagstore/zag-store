import Foundation

@main struct Tests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            checks += 1; print("PASS: \(label)")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = folder.appendingPathComponent("rppairing.plist")
        let identity = folder.appendingPathComponent("rppairing-host-identity.bin")
        let unrelated = folder.appendingPathComponent("other-computer.plist")
        try Data("other identity".utf8).write(to: unrelated)
        let suite = "ZagStore.local-removal-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var pending = false
        var unreadable = false
        var fail: Set<URL> = []
        var removed: [URL] = []
        let operation = ZagLocalPairingRemoval(pairingRecord: record, hostIdentity: identity, env: .init(
            exists: { url in
                if unreadable { throw CocoaError(.fileReadNoPermission) }
                return FileManager.default.fileExists(atPath: url.path)
            },
            remove: { url in
                check(pending, "recovery intent recorded before deleting material")
                if fail.contains(url) { throw CocoaError(.fileWriteNoPermission) }
                removed.append(url)
                try FileManager.default.removeItem(at: url)
            }, setPending: { pending = $0; defaults.set($0, forKey: ZagLocalPairingRemoval.pendingKey) }
        ))
        func seed() throws {
            // Intentionally malformed/stale bytes: explicit local cleanup does not
            // need a successful authentication or access to the system trust list.
            try Data("stale record".utf8).write(to: record)
            try Data([1,2,3]).write(to: identity)
        }
        try seed()
        check(try operation.run() == .localCredentialsRemoved, "successful local cleanup has only a local outcome")
        check(!pending && !FileManager.default.fileExists(atPath: record.path), "successful cleanup clears recovery intent and local record")
        check(!FileManager.default.fileExists(atPath: identity.path), "host identity removed as part of confirmed local action")
        check(try operation.run() == .localCredentialsRemoved, "missing records and repeated cleanup are idempotent")
        check(!pending, "repeated cleanup does not leave a recovery flag")

        for failedFile in [record, identity] {
            try seed(); fail = [failedFile]
            do { try operation.run(); check(false, "partial cleanup must fail") }
            catch { check(error is ZagLocalPairingRemoval.Failure, "partial cleanup reports actionable local failure, not full unpairing") }
            check(pending && UserDefaults(suiteName: suite)!.bool(forKey: ZagLocalPairingRemoval.pendingKey), "partial cleanup retains retry intent across store recreation")
            check(FileManager.default.fileExists(atPath: failedFile.path), "failed file remains available for recovery")
            fail = []
            try operation.run()
            check(!pending && !FileManager.default.fileExists(atPath: record.path) && !FileManager.default.fileExists(atPath: identity.path), "retry removes surviving file and clears recovery intent")
        }
        try seed(); fail = [record, identity]
        do { try operation.run(); check(false, "failed cleanup must not succeed") } catch { }
        check(pending && FileManager.default.fileExists(atPath: record.path), "complete local failure preserves remaining material and recovery intent")
        fail = []; try operation.run()
        check(removed.allSatisfy { $0 == record || $0 == identity }, "only two exact Zag Store paths may be removed")
        check(try Data(contentsOf: unrelated) == Data("other identity".utf8), "unrelated pairing records untouched")

        unreadable = true
        do { try operation.run(); check(false, "unreadable paths must not imply absence") } catch { }
        check(pending, "permission/read failures retain recovery instead of reporting removal")
        unreadable = false; try operation.run()

        let fileSystemOperation = ZagLocalPairingRemoval(pairingRecord: record, hostIdentity: identity, env: .init(
            exists: ZagLocalPairingRemoval.fileExists, remove: ZagLocalPairingRemoval.removeFile,
            setPending: { pending = $0 }
        ))
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        let child = record.appendingPathComponent("unrelated.plist")
        try Data([7]).write(to: child)
        do { try fileSystemOperation.run(); check(false, "directory must not be deleted recursively") } catch { }
        check(pending && FileManager.default.fileExists(atPath: child.path), "a directory at a credential path is refused without deleting children")
        try FileManager.default.removeItem(at: record) // Test fixture cleanup only.
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: unrelated)
        try fileSystemOperation.run()
        check(!pending && FileManager.default.fileExists(atPath: unrelated.path), "removing a link never removes the unrelated target")

        var launch = ZagOnboardingPolicy()
        _ = launch.beginIfNeeded(hasRecord: FileManager.default.fileExists(atPath: record.path) && !pending)
        launch.finishSplash()
        check(launch.status == .missing && !launch.canEnterMain, "cold launch after cleanup shows welcome")
        try seed()
        var rePair = ZagOnboardingPolicy()
        let generation = rePair.beginIfNeeded(hasRecord: true)!
        check(!rePair.isPairingVerified, "new pairing record still requires verification")
        rePair.receive(.verified, generation: generation)
        check(rePair.isPairingVerified, "re-pairing can pass the existing verification gate")
        check(!ZagLocalPairingRemoval.localOnlyMessage.contains("fully unpaired"), "local outcome never claims full system unpairing")
        check(ZagLocalPairingRemoval.localOnlyMessage.contains("has not been revoked"), "remaining system trust is stated explicitly")
        check(ZagLocalPairingRemoval.systemRemovalInstructions.contains("Select only Zag Store"), "manual removal is scoped to Zag Store")
        print("SUCCESS: \(checks) local pairing-removal checks passed")
        print("NOT IMPLEMENTED: automatic device-side revocation; no supported matching API found. No simulated revocation is reported as a device test.")
    }
}
