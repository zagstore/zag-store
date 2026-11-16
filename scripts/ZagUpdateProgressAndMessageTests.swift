import Foundation

@main struct UpdateProgressAndMessageTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            count += 1
            print("PASS: \(name)")
        }
        check(ZagUpdateByteProgress(received: 25, expected: 100).fraction == 0.25, "download fraction uses real received and expected bytes")
        check(ZagUpdateByteProgress(received: 25, expected: nil).fraction == nil, "unknown length has no invented percentage")
        check(ZagUpdateByteProgress(received: 25, expected: -1).fraction == nil, "invalid length has no percentage")
        check(ZagUpdateByteProgress(received: 120, expected: 100).fraction == 1, "display fraction remains bounded")
        var sampler = ZagUpdateProgressSampler()
        check(sampler.receive(bytes: 0, expected: 100, now: 0)?.fraction == 0, "first measurement is published")
        check(sampler.receive(bytes: 25, expected: 100, now: 0.01) == nil, "rapid callbacks do not flood UI")
        check(sampler.receive(bytes: 50, expected: 100, now: 0.11)?.received == 50, "next real byte measurement is retained")
        check(sampler.receive(bytes: 30, expected: 100, now: 0.22) == nil, "late lower byte count cannot move progress backwards")
        check(sampler.receive(bytes: 100, expected: 100, now: 0.23, finished: true)?.fraction == 1, "final measurement is not lost to throttling")
        check(sampler.receive(bytes: 100, expected: 100, now: 0.24, finished: true) == nil, "identical final callbacks are not republished")
        var fresh = ZagUpdateProgressSampler()
        check(fresh.receive(bytes: 0, expected: 200, now: 0)?.received == 0, "new download starts with independent progress")
        var burst = ZagUpdateProgressSampler()
        var publications = 0
        for i in 0..<1000 {
            if burst.receive(bytes: Int64(i), expected: 1000, now: Double(i)/1000) != nil { publications += 1 }
        }
        check(publications <= 11, "1000 callbacks produce at most eleven first/10Hz publications")

        check(ZagSelfUpdateActionState.idle.title == "Update Now", "idle control remains Update Now")
        check(ZagSelfUpdateActionState.confirmed.title == "Restart to Complete...", "only confirmed state offers restart guidance")
        check(ZagSelfUpdateActionState.awaitingVerification.title != ZagSelfUpdateActionState.confirmed.title, "installer handoff is distinct from confirmed replacement")
        check(ZagSelfUpdateActionState.progress(message: "Downloaded", fraction: 1).title != ZagSelfUpdateActionState.confirmed.title, "100 percent download never claims installation success")
        for state in [ZagUpdatePreparationState.verifying, .importing, .signing, .readyForHandoff] {
            check(state.fraction == nil, "preparation phase has no fabricated percentage")
        }
        let heights = (0...100).map { ZagUpdateControlGeometry.height(slotHeight: 54, morph: Double($0) / 100) }
        check(heights.first == 54 && heights.last == 14, "morph preserves original capsule and progress-track endpoints")
        check(heights.allSatisfy { $0.isFinite && (14...54).contains($0) }, "morph never disappears, overshoots or produces invalid geometry")
        check(zip(heights, heights.dropFirst()).allSatisfy { $0 > $1 }, "compression remains strictly monotonic at intermediate samples")
        check(zip(heights, heights.dropFirst()).allSatisfy { $0 - $1 < 0.5 }, "small morph steps cannot introduce abrupt height jumps")
        check(ZagUpdateControlGeometry.height(slotHeight: 86, morph: 0) == 86, "Dynamic Type capsule retains its full slot height")
        check(ZagUpdateControlGeometry.height(slotHeight: 86, morph: 1) == 14, "Dynamic Type progress track remains inside the same slot")
        check(ZagUpdateControlGeometry.filledFraction(progress: 0.25, morph: 1) == 0.25, "real byte fraction determines the filled track")
        check(ZagUpdateControlGeometry.filledFraction(progress: 0.25, morph: 0) == 1, "idle and terminal pills have a continuous full body")
        for terminal in [ZagSelfUpdateActionState.awaitingHandoff, .handedOff, .awaitingVerification, .confirmed] {
            check(!terminal.showsProgress && terminal.offersGuidance, "every non-busy outcome expands to an actionable capsule")
            check(terminal.guidance.contains("install") || terminal.guidance.contains("installed"), "outcome guidance describes actual installation proof")
        }
        check(ZagSelfUpdateActionState.handedOff.status?.contains("handed off") == true, "successful native return is described as handoff")
        check(ZagSelfUpdateActionState.awaitingVerification.status?.contains("not verified") == true, "ambiguous failure never claims handoff success")
        check(ZagSelfUpdateActionState.awaitingHandoff.status?.contains("Signed IPA transferred") == true, "staged data describes transfer without claiming installation")
        check(ZagSelfUpdateActionState.awaitingHandoff.title == "Reopen After Installation...", "normal staged state has a concise user-facing action")
        check(ZagSelfUpdateActionState.confirmed.status == "Update completed. Please restart Zag Store.", "confirmed installation retains exact completion text")
        check(ZagSelfUpdateActionState.confirmed.reopenInstruction.contains("App Switcher"), "restart action supplies safe manual steps")
        check(ZagSelfUpdateActionState.idle.showsProgress == false, "failed pre-handoff operation can restore the original capsule")
        check(!ZagPostUpdateMessage.isReleaseAdvance(version: "2.4.6", build: "21", fromVersion: "2.4.6", fromBuild: "21"), "same version/build re-signing is not a new release")
        check(ZagPostUpdateMessage.isReleaseAdvance(version: "2.5.0", build: "1", fromVersion: "2.4.6", fromBuild: "21"), "newer semantic version supports reset build numbers")
        check(ZagUpdateDecorationPolicy.animates(progress: true, active: true, reduceMotion: false, lowPower: false), "decorative flow is available at the system display cadence")
        check(!ZagUpdateDecorationPolicy.animates(progress: true, active: true, reduceMotion: true, lowPower: false), "Reduce Motion pauses decorative motion")
        check(!ZagUpdateDecorationPolicy.animates(progress: true, active: true, reduceMotion: false, lowPower: true), "Low Power Mode pauses decorative motion")
        check(!ZagUpdateDecorationPolicy.animates(progress: true, active: false, reduceMotion: false, lowPower: false), "background scene never drives a display clock")
        check(!ZagUpdateDecorationPolicy.animates(progress: false, active: true, reduceMotion: false, lowPower: false), "idle and terminal capsules stop the gradient clock")
        check(ZagSelfUpdateActionState.progress(message: "Downloading update...", fraction: 0.42).status == "Downloading update... 42%", "visible percentage uses the authoritative measured fraction")
        check(ZagSelfUpdateActionState.progress(message: "Verifying IPA...", fraction: nil).status == "Verifying IPA...", "unknown verification duration displays no percentage")
        let newHash = String(repeating: "a", count: 64)
        let oldHash = String(repeating: "b", count: 64)
        let running = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: "app.test.zag", version: "2.4.6", build: "21", executableSHA256: newHash)
        func candidate(channel: String? = "beta", version: String = "2.4.6", build: String = "21", bundle: String = "app.test.zag", expected: String? = nil, original: String? = nil) -> ZagPostUpdateMessage.Candidate {
            .init(bundleIdentifier: bundle, version: version, build: build, channel: channel,
                  expectedExecutableSHA256: expected ?? newHash, originatingExecutableSHA256: original ?? oldHash,
                  originatingVersion: "2.4.5", originatingBuild: "20")
        }
        for channel in ZagPostUpdateMessage.Channel.allCases {
            let message = candidate(channel: channel.rawValue).verifiedMessage(running: running)
            check(message?.channel == channel && message?.matches(running) == true, "verified installed identity supports \(channel.rawValue)")
            check(message?.tokens.count == 3, "\(channel.rawValue) preserves exactly three cinematic reveal groups")
            check(message?.text == "Updated to 2.4.6 \(channel.title) 21", "\(channel.rawValue) message uses actual version/channel/build")
        }
        check(candidate(version: "2.4.7").verifiedMessage(running: running) == nil, "downloaded newer version is not installation proof")
        check(candidate(build: "22").verifiedMessage(running: running) == nil, "wrong build cannot produce success")
        check(candidate(bundle: "other.app").verifiedMessage(running: running) == nil, "another bundle cannot produce success")
        check(candidate(expected: oldHash).verifiedMessage(running: running) == nil, "wrong executable hash cannot produce success")
        check(candidate(original: newHash).verifiedMessage(running: running) == nil, "unchanged original executable cannot prove installation")
        check(candidate(channel: nil).verifiedMessage(running: running) == nil, "legacy record without verified channel does not infer one")
        check(candidate(channel: "other").verifiedMessage(running: running) == nil, "unknown channel cannot be shown as Beta")
        check(candidate(expected: "bad").verifiedMessage(running: running) == nil, "malformed digest rejected")
        let sameRelease = ZagPostUpdateMessage.Candidate(bundleIdentifier: running.bundleIdentifier,
            version: running.version, build: running.build, channel: "beta", expectedExecutableSHA256: newHash,
            originatingExecutableSHA256: oldHash, originatingVersion: running.version, originatingBuild: running.build)
        check(sameRelease.verifiedMessage(running: running) == nil, "changed executable at the same version/build never announces a new release")
        check(candidate(version: "").verifiedMessage(running: running) == nil, "empty installed identity is not success")

        let suite = "ZagStore.post-update-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = ZagPostUpdateMessageStore(defaults: defaults)
        check(store.pending(running: running) == nil, "ordinary launch has no update message")
        check(store.record(candidate(build: "22"), running: running) == nil, "failed installation persists no success message")
        let stillOriginal = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: running.bundleIdentifier,
            version: "2.4.5", build: "20", executableSHA256: oldHash)
        check(store.record(candidate(), running: stillOriginal) == nil, "failed or cancelled update with the original app still running cannot persist success")
        check(store.pending(running: stillOriginal) == nil, "incomplete update cannot display a post-update splash")
        let interrupted = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: running.bundleIdentifier,
            version: running.version, build: running.build, executableSHA256: oldHash)
        check(store.record(candidate(), running: interrupted) == nil, "interrupted replacement with updated labels but the original executable never announces success")
        defaults.set(Data("handoff without installed proof".utf8), forKey: "zagStore.selfUpdate.pending")
        check(store.pending(running: stillOriginal) == nil, "a persisted pending handoff alone cannot create a splash notice")
        let message = store.record(candidate(), running: running)!
        store = ZagPostUpdateMessageStore(defaults: UserDefaults(suiteName: suite)!)
        check(store.pending(running: running) == message, "pending verified notice survives store recreation")
        check(store.pending(running: running) == message, "reading or skipping does not acknowledge display")
        let otherRunning = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: running.bundleIdentifier, version: running.version, build: "22", executableSHA256: newHash)
        check(store.pending(running: otherRunning) == nil, "pending message must match the currently running identity")
        store.acknowledgeDisplayed(message)
        check(store.pending(running: running) == nil, "successful display restores normal tagline on later launches")
        check(ZagPostUpdateMessageStore(defaults: UserDefaults(suiteName: suite)!).pending(running: running) == nil,
              "a second ordinary launch after successful reveal has no post-update message")
        check(store.record(candidate(), running: running) == nil, "reconciliation replay cannot show the same notice twice")
        let later = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: running.bundleIdentifier, version: "2.4.7", build: "22", executableSHA256: newHash)
        let next = store.record(candidate(version: "2.4.7", build: "22"), running: later)!
        store.acknowledgeDisplayed(message)
        check(store.pending(running: later) == next, "stale display callback cannot clear a later update message")
        print("SUCCESS: \(count) byte-progress and post-update message policy checks passed")
    }
}
