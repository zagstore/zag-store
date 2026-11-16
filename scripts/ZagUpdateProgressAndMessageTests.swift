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
        let newHash = String(repeating: "a", count: 64)
        let oldHash = String(repeating: "b", count: 64)
        let running = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: "app.test.zag", version: "2.4.6", build: "21", executableSHA256: newHash)
        func candidate(channel: String? = "beta", version: String = "2.4.6", build: String = "21", bundle: String = "app.test.zag", expected: String? = nil, original: String? = nil) -> ZagPostUpdateMessage.Candidate {
            .init(bundleIdentifier: bundle, version: version, build: build, channel: channel,
                  expectedExecutableSHA256: expected ?? newHash, originatingExecutableSHA256: original ?? oldHash)
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
        check(candidate(version: "").verifiedMessage(running: running) == nil, "empty installed identity is not success")

        let suite = "ZagStore.post-update-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = ZagPostUpdateMessageStore(defaults: defaults)
        check(store.pending(running: running) == nil, "ordinary launch has no update message")
        check(store.record(candidate(build: "22"), running: running) == nil, "failed installation persists no success message")
        let message = store.record(candidate(), running: running)!
        store = ZagPostUpdateMessageStore(defaults: UserDefaults(suiteName: suite)!)
        check(store.pending(running: running) == message, "pending verified notice survives store recreation")
        check(store.pending(running: running) == message, "reading or skipping does not acknowledge display")
        let otherRunning = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: running.bundleIdentifier, version: running.version, build: "22", executableSHA256: newHash)
        check(store.pending(running: otherRunning) == nil, "pending message must match the currently running identity")
        store.acknowledgeDisplayed(message)
        check(store.pending(running: running) == nil, "successful display restores normal tagline on later launches")
        check(store.record(candidate(), running: running) == nil, "reconciliation replay cannot show the same notice twice")
        let later = ZagPostUpdateMessage.RunningIdentity(bundleIdentifier: running.bundleIdentifier, version: "2.4.7", build: "22", executableSHA256: newHash)
        let next = store.record(candidate(version: "2.4.7", build: "22"), running: later)!
        store.acknowledgeDisplayed(message)
        check(store.pending(running: later) == next, "stale display callback cannot clear a later update message")
        print("SUCCESS: \(count) byte-progress and post-update message policy checks passed")
    }
}
