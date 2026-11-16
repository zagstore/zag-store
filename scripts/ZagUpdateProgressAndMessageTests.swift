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
        check(ZagSelfUpdateActionState.awaitingVerification.title != ZagSelfUpdateActionState.handedOff.title, "an unverified attempt is distinct from the successful handoff")
        check(ZagSelfUpdateActionState.progress(message: "Downloaded", fraction: 1).title != ZagSelfUpdateActionState.handedOff.title, "100 percent download never claims installation success")
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
        check(!ZagSelfUpdateActionState.handedOff.showsProgress && ZagSelfUpdateActionState.handedOff.offersGuidance, "the successful handoff expands to an actionable capsule")
        check(ZagSelfUpdateActionState.handedOff.guidance.contains("install"), "outcome guidance describes actual installation proof")
        check(ZagSelfUpdateActionState.handedOff.status == "Update successful. Reopen Zag Store to complete.", "successful handoff uses exact requested final wording")
        check(!ZagSelfUpdateActionState.awaitingVerification.showsProgress, "a failed or ambiguous attempt ends the progress bar")
        check(!ZagSelfUpdateActionState.awaitingVerification.offersGuidance, "an unverified attempt offers no success guidance")
        check(ZagSelfUpdateActionState.awaitingVerification.title.contains("not verified"), "ambiguous failure never claims handoff success")
        check(ZagSelfUpdateActionState.awaitingVerification.status == nil, "the unverified capsule does not repeat its title below")
        check(ZagSelfUpdateActionState.handedOff.reopenInstruction.contains("App Switcher"), "restart action supplies safe manual steps")
        check(ZagUpdateHandoffState.stagedOnDevice.isSuccessfulHandoff && ZagUpdateHandoffState.reportedComplete.isSuccessfulHandoff,
              "verified on-device staging (209) and native completion (207) end the in-app operation")
        for state in [ZagUpdateHandoffState.none, .waiting, .uncertain] {
            check(!state.isSuccessfulHandoff, "no handoff, an attempt in flight and an ambiguous failure never select success")
        }
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
        check(ZagSelfUpdateActionState.handedOff.title == "Restart to Complete...", "successful installer return uses the exact final button label")
        for uncertain in [ZagSelfUpdateActionState.awaitingVerification, .idle,
                          .progress(message: "Failed", fraction: nil), .progress(message: "Transferred", fraction: 1)] {
            check(uncertain.status != ZagSelfUpdateActionState.handedOff.status, "unsuccessful or unconfirmed states never show success wording")
        }
        let activeSequence: [ZagSelfUpdateActionState] = [
            .progress(message: "Preparing", fraction: nil), .progress(message: "Preparing update...", fraction: nil),
            .progress(message: "Connecting", fraction: nil), .progress(message: "Transferring signed IPA...", fraction: 1),
            .progress(message: "Installing", fraction: 0.3)]
        check(activeSequence.allSatisfy { $0.showsProgress } && !ZagSelfUpdateActionState.handedOff.showsProgress,
              "persisting a pending record or a complete transfer cannot reverse the morph before verified staging")
        // Replays the 1:09 PM device recording: transfer to 100%, then 209, then
        // no further installer callback while Zag Store stays open.
        func pending(_ handoff: ZagUpdateHandoffState, running: Bool, title: String = "Transferring signed IPA...",
                     fraction: Double? = nil) -> ZagSelfUpdateActionState {
            .pendingAttempt(handoff: handoff, installerRunning: running, installerTitle: title,
                            installerFraction: fraction, preparingMessage: "Preparing update...")
        }
        check(pending(.none, running: false) == .progress(message: "Preparing update...", fraction: nil),
              "a pending record before the installer starts stays busy, never 'not verified'")
        check(pending(.waiting, running: true, fraction: 0.88).showsProgress, "transfer at 88% is a progress bar")
        check(pending(.waiting, running: true, fraction: 1).showsProgress, "a complete transfer alone does not end the operation")
        let staged = pending(.stagedOnDevice, running: true, title: "IPA verified - waiting for iOS handoff")
        check(staged == .handedOff && !staged.showsProgress, "verified staging (209) morphs back to the final capsule while iOS stays silent")
        check(staged.title == "Restart to Complete..." && staged.status == "Update successful. Reopen Zag Store to complete.",
              "the device sequence ends with the two exact requested strings")
        check(pending(.stagedOnDevice, running: true, title: "Installing update...", fraction: 0.4) == .handedOff,
              "a late installer percentage cannot pull the capsule back into a bar")
        check(pending(.reportedComplete, running: false) == .handedOff, "a native completion (207) also ends on the final capsule")
        let failedAfterStaging = pending(.uncertain, running: false)
        check(failedAfterStaging == .awaitingVerification && !failedAfterStaging.showsProgress,
              "an installer error after staging ends the bar without success wording")
        check(failedAfterStaging.status != staged.status && failedAfterStaging.title != staged.title,
              "failed and ambiguous attempts never reuse either completion string")
        check(pending(.none, running: false) != .handedOff && pending(.waiting, running: false) != .handedOff,
              "released or in-flight attempts never select success")
        check(ZagUpdateMorphSpecification.duration == 0.42, "both directions retain the accepted final-morph duration")
        check(abs(ZagUpdateMorphSpecification.x1 + ZagUpdateMorphSpecification.x2 - 1) < 1e-12 &&
              abs(ZagUpdateMorphSpecification.y1 + ZagUpdateMorphSpecification.y2 - 1) < 1e-12,
              "one shared easing curve is mathematically symmetric under time reversal")
        func bezier(_ t: Double) -> Double {
            3 * (1-t) * (1-t) * t * ZagUpdateMorphSpecification.y1 +
            3 * (1-t) * t * t * ZagUpdateMorphSpecification.y2 + t*t*t
        }
        for time in [0.0, 0.2, 0.5, 0.8, 1.0] {
            let entering = ZagUpdateControlGeometry.height(slotHeight: 54, morph: bezier(time))
            let exitingReversed = ZagUpdateControlGeometry.height(slotHeight: 54, morph: 1 - bezier(1-time))
            check(abs(entering - exitingReversed) < 1e-10, "reverse-time morph has identical geometry at sample \(time)")
        }
        var visual = ZagUpdateVisualProgress(0.1, at: 0)
        visual.update(0.5, at: 1, immediate: false)
        check(visual.value(at: 1) == 0.1 && abs(visual.value(at: 1.05) - 0.3) < 1e-9, "displayed progress interpolates from its previous measurement")
        let beforeRetarget = visual.value(at: 1.06)
        visual.update(0.8, at: 1.06, immediate: false)
        check(abs(visual.value(at: 1.06) - beforeRetarget) < 1e-9, "new percentages do not snap the current displayed value")
        check(visual.value(at: 1.11) >= beforeRetarget && visual.value(at: 3) == 0.8,
              "visual interpolation remains monotonic and never extrapolates past the actual target")
        visual.update(0.02, at: 4, immediate: false)
        check(visual.value(at: 4) == 0.02, "a new measured phase never inherits the previous phase's percentage")
        visual.update(0.7, at: 5, immediate: true)
        check(visual.value(at: 5) == 0.7, "Reduce Motion and Low Power Mode can use immediate authoritative values")
        check((0...100).allSatisfy { ZagUpdateProgressFormatting.percent(Double($0)/100) == $0 },
              "all integer installer percentages survive floating-point formatting exactly")
        check(ZagUpdateProgressFormatting.percent(Double(1).nextDown) == 99,
              "formatting never rounds an incomplete byte transfer up to 100 percent")
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
