import Foundation

/// Local A→B replacement: two real, distinguishable executables pass through the
/// production executable hasher, verified-message policy and one-shot store across
/// simulated launches. No release metadata, manifest or app version is involved.
@main struct PostUpdateABTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1; print("PASS: \(label)") }
        let arguments = CommandLine.arguments
        let executableA = URL(fileURLWithPath: arguments[1]), executableB = URL(fileURLWithPath: arguments[2])
        let resignedB = URL(fileURLWithPath: arguments[3])
        let hashA = try ZagPackageIntegrity.sha256(of: executableA)
        let hashB = try ZagPackageIntegrity.sha256(of: executableB)
        let hashResigned = try ZagPackageIntegrity.sha256(of: resignedB)
        check(Set([hashA, hashB, hashResigned]).count == 3, "A, B and a differently built B are distinguishable executables")

        let suite = "ZagStore.post-update-ab.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        func launch() -> ZagPostUpdateMessageStore { ZagPostUpdateMessageStore(defaults: UserDefaults(suiteName: suite)!) }
        /// The splash's own selection: the verified message, otherwise the normal tagline.
        func tagline(_ message: ZagPostUpdateMessage?) -> String {
            (message?.tokens ?? ["Sideloading", "and", "beyond."]).joined(separator: " ")
        }
        let bundle = "com.cwd43.gu29"
        let runningA = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: bundle, version: "1.0.0", build: "2", executableSHA256: hashA)
        let runningB = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: bundle, version: "1.0.0", build: "3", executableSHA256: hashB)
        // The pending record A writes before handing B to the installer.
        let handoff = ZagPostUpdateMessage.Candidate(bundleIdentifier: bundle, version: "1.0.0", build: "3", channel: "beta",
                                                     expectedExecutableSHA256: hashB, originatingExecutableSHA256: hashA,
                                                     originatingVersion: "1.0.0", originatingBuild: "2")

        // Launch 0: A is running; the installer has the IPA but no relaunch has happened.
        check(launch().record(handoff, running: runningA) == nil, "A running after the handoff cannot create a notice")
        check(tagline(launch().pending(running: runningA)) == "Sideloading and beyond.", "A keeps the normal tagline")

        // Launch 1: B is running. Reconciliation hashes it and records the verified notice.
        let message = launch().record(handoff, running: runningB)
        check(message?.text == "Updated to 1.0.0 Beta 3", "B's first launch builds the exact message from its actual identity")
        check(tagline(launch().pending(running: runningB)) == "Updated to 1.0.0 Beta 3", "the splash replaces the tagline on B's first launch")
        check(message?.tokens == ["Updated", "to", "1.0.0 Beta 3"], "three reveal groups: Updated, to, then the whole release")

        // The reveal was skipped (or the app ended) before the signature appeared.
        check(launch().pending(running: runningB) == message, "an unrevealed notice stays pending for the next launch")

        // Launch 2: the signature is revealed and acknowledged.
        launch().acknowledgeDisplayed(message!)
        // Launch 3: an ordinary launch of B.
        check(tagline(launch().pending(running: runningB)) == "Sideloading and beyond.", "the next ordinary launch restores the tagline")
        check(launch().record(handoff, running: runningB) == nil, "the same verified replacement cannot re-arm the notice")

        // Negative replacements on a fresh device.
        let freshSuite = "\(suite).fresh"
        defer { UserDefaults().removePersistentDomain(forName: freshSuite) }
        let fresh = ZagPostUpdateMessageStore(defaults: UserDefaults(suiteName: freshSuite)!)
        let otherB = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: bundle, version: "1.0.0", build: "3", executableSHA256: hashResigned)
        check(fresh.record(handoff, running: otherB) == nil, "a different executable at B's version and build is not the verified replacement")
        let sameBuild = ZagPostUpdateMessage.Candidate(bundleIdentifier: bundle, version: "1.0.0", build: "3", channel: "beta",
                                                       expectedExecutableSHA256: hashB, originatingExecutableSHA256: hashA,
                                                       originatingVersion: "1.0.0", originatingBuild: "3")
        check(fresh.record(sameBuild, running: runningB) == nil, "re-installing the same version and build never announces an update")
        check(fresh.pending(running: runningB) == nil, "rejected replacements leave the normal tagline")
        print("SUCCESS: \(checks) local A→B post-update splash checks passed")
    }
}
