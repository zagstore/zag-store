import Foundation
import Combine

@MainActor private final class PairingService: ZagLaunchPairingService {
    var hasPairingRecord = false
    var isBusy = false
    let events = PassthroughSubject<ZagOnboardingPolicy.Verification, Never>()
    let successes = PassthroughSubject<Void, Never>()
    let removals = PassthroughSubject<Void, Never>()
    var checks = 0
    var verificationEvents: AnyPublisher<ZagOnboardingPolicy.Verification, Never> { events.eraseToAnyPublisher() }
    var setupSuccesses: AnyPublisher<Void, Never> { successes.eraseToAnyPublisher() }
    var recordRemovals: AnyPublisher<Void, Never> { removals.eraseToAnyPublisher() }
    func verify() { checks += 1 }
}

@main struct Tests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            checks += 1
            print("PASS: \(label)")
        }
        func settle() async { for _ in 0..<10 { await Task.yield() } }
        func launch(_ service: PairingService, timeout: UInt64 = 1_000_000_000) -> ZagPairingLaunchCoordinator {
            let gate = ZagPairingLaunchCoordinator(service: service, timeoutNanoseconds: timeout)
            gate.startIfNeeded()
            return gate
        }

        let missing = PairingService()
        let first = launch(missing)
        first.finishSplash()
        check(first.policy.status == .missing && !first.policy.canEnterMain && missing.checks == 0,
              "first cold launch without pairing shows welcome after splash")

        // Real legacy defaults and unrelated data cannot affect the new gate.
        let name = "ZagStore.launch-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for state in ["completed", "existing", "pending"] {
            defaults.set(state, forKey: "ZagStore.onboardingState")
            defaults.set(true, forKey: "ZagStore.activityOptOut")
            let reinstall = launch(missing)
            check(reinstall.policy.status == .missing, "reinstall over existing app data ignores legacy \(state) marker")
        }
        check(defaults.bool(forKey: "ZagStore.activityOptOut"), "unrelated consent preferences retained")
        check(launch(missing).policy.status == .missing, "completed onboarding followed by unpairing shows welcome")

        // Saved pairing, VPN connected: the main interface opens at once and
        // verification completes in the background.
        let connected = PairingService(); connected.hasPairingRecord = true
        let online = launch(connected)
        check(online.policy.canEnterMain && online.policy.hasSavedPairing && !online.policy.isPairingVerified,
              "saved pairing opens main immediately without being treated as verified")
        await settle()
        check(connected.checks == 1, "one asynchronous check requested for a saved pairing")
        connected.events.send(.verified)
        check(online.policy.isPairingVerified && online.policy.canEnterMain, "VPN connected: live check verifies pairing")
        online.startIfNeeded()
        online.connectionAvailable()
        check(connected.checks == 1 && online.policy.isPairingVerified,
              "background/foreground, repeated tasks and reconnects never re-probe verified pairing")

        // Saved pairing, VPN disconnected: unreachable results keep the app open
        // and never read as missing pairing or as verification.
        for result in [ZagOnboardingPolicy.Verification.unknown, .failed] {
            let service = PairingService(); service.hasPairingRecord = true
            let gate = launch(service)
            await settle()
            service.events.send(result)
            check(gate.policy.canEnterMain && gate.policy.isConnectionUnavailable && gate.policy.hasSavedPairing
                  && !gate.policy.isPairingVerified && gate.policy.status != .missing,
                  "VPN disconnected (\(result)): main stays open, connectivity unavailable, pairing kept but unverified")
        }

        // Explicit rejection: open, not verified, not a connectivity problem.
        let rejectedService = PairingService(); rejectedService.hasPairingRecord = true
        let rejected = launch(rejectedService)
        await settle()
        rejectedService.events.send(.invalid)
        check(rejected.policy.status == .invalid && rejected.policy.canEnterMain && rejected.policy.hasSavedPairing
              && !rejected.policy.isPairingVerified && !rejected.policy.isConnectionUnavailable,
              "rejected pairing stays saved, unverified and distinct from connectivity (repair prompt)")
        rejected.connectionAvailable()
        check(rejectedService.checks == 1, "reconnect does not re-probe a rejected pairing")
        rejectedService.successes.send(())
        check(rejected.policy.isPairingVerified, "repairing from inside the main interface verifies pairing")

        let stalled = PairingService(); stalled.hasPairingRecord = true
        let timeout = launch(stalled, timeout: 20_000_000)
        await settle()
        try await Task.sleep(nanoseconds: 80_000_000)
        check(timeout.policy.status == .timedOut && timeout.policy.canEnterMain && timeout.policy.isConnectionUnavailable
              && timeout.policy.hasSavedPairing && !timeout.policy.isPairingVerified,
              "verification timeout is unavailable connectivity: never missing pairing, never verification")
        stalled.events.send(.verified)
        check(timeout.policy.status == .timedOut, "late result after timeout ignored")

        // VPN reconnect after the timeout: exactly one new check. Its outcome
        // is not asserted here: this gate's deadline is deliberately short.
        timeout.connectionAvailable()
        await settle()
        check(stalled.checks == 2, "VPN reconnect after timeout starts one new check")

        // Reconnect re-check with a normal deadline: no overlap, then verified.
        let offline = PairingService(); offline.hasPairingRecord = true
        let reconnect = launch(offline)
        await settle()
        offline.events.send(.unknown)
        reconnect.connectionAvailable()
        await settle()
        check(offline.checks == 2 && reconnect.policy.status == .checking, "VPN reconnect after unavailable starts one new check")
        reconnect.connectionAvailable()
        reconnect.retry()
        await settle()
        check(offline.checks == 2, "repeated reconnects while checking never overlap checks")
        offline.events.send(.verified)
        check(reconnect.policy.isPairingVerified, "reconnect re-check verifies pairing for device operations")

        let busy = PairingService(); busy.hasPairingRecord = true; busy.isBusy = true
        let busyGate = launch(busy, timeout: 20_000_000)
        try await Task.sleep(nanoseconds: 80_000_000)
        check(busy.checks == 0 && busyGate.policy.status == .timedOut, "unavailable/busy service is bounded and never overlaps native workers")

        // Pairing removed during the session.
        let removedService = PairingService(); removedService.hasPairingRecord = true
        let removed = launch(removedService)
        await settle()
        removedService.events.send(.verified)
        removedService.hasPairingRecord = false
        removedService.removals.send(())
        check(removed.policy.status == .missing && !removed.policy.hasSavedPairing && !removed.policy.isPairingVerified
              && removed.policy.canEnterMain, "removal during the session clears verification without leaving main")
        removed.connectionAvailable()
        check(removedService.checks == 1, "no probe runs without a record")
        check(launch(removedService).policy.status == .missing && !launch(removedService).policy.canEnterMain,
              "cold launch after removal shows the first-run welcome")
        let inFlightService = PairingService(); inFlightService.hasPairingRecord = true
        let inFlight = launch(inFlightService)
        await settle()
        inFlightService.hasPairingRecord = false
        inFlightService.removals.send(())
        inFlightService.events.send(.verified)
        check(inFlight.policy.status == .missing, "a check result after removal is discarded")
        let staleRemoval = PairingService(); staleRemoval.hasPairingRecord = true
        let kept = launch(staleRemoval)
        staleRemoval.removals.send(())
        check(kept.policy.hasSavedPairing && kept.policy.status == .checking, "removal signal without a removed record changes nothing")

        // Deep links before and after the splash.
        let url = URL(string: "zagstore://settings/installation")!
        let valid = PairingService(); valid.hasPairingRecord = true
        let verified = launch(valid)
        verified.enqueue(url)
        check(verified.takeURLs().isEmpty, "deep link before the splash is held")
        verified.finishSplash()
        check(verified.takeURLs() == [url] && verified.takeURLs().isEmpty,
              "saved pairing: link released once after the splash, without waiting for the network")
        verified.enqueue(url)
        check(verified.takeURLs() == [url], "link after the splash is delivered immediately")
        let firstRun = launch(missing)
        firstRun.enqueue(url)
        firstRun.finishSplash()
        check(firstRun.takeURLs().isEmpty, "no pairing: links wait behind the first-run welcome")

        let skipped = launch(missing)
        skipped.enqueue(url)
        skipped.skip()
        check(skipped.policy.canEnterMain && skipped.takeURLs().isEmpty, "skip is session-local and still respects splash")
        skipped.finishSplash()
        check(skipped.takeURLs() == [url], "skip releases queued links after splash")
        skipped.startIfNeeded()
        check(skipped.policy.status == .skipped, "foreground after skip does not interrupt current session")
        check(launch(missing).policy.status == .missing, "skip followed by cold relaunch shows welcome again")

        let setup = PairingService()
        let pairing = launch(setup)
        check(!pairing.policy.canEnterMain, "opening pairing is not success")
        setup.hasPairingRecord = true
        check(!pairing.policy.canEnterMain, "record appearing is not verification")
        setup.successes.send(())
        check(pairing.policy.status == .verified, "fresh authenticated native pairing success exits welcome")
        let next = launch(setup)
        check(next.policy.status == .checking && !next.policy.isPairingVerified, "successful pairing followed by cold relaunch must reverify")
        await settle()
        setup.events.send(.failed)
        check(!next.policy.isPairingVerified, "previous native success cannot hide stale pairing on next cold launch")

        var policy = ZagOnboardingPolicy()
        let old = policy.beginIfNeeded(hasRecord: true)!
        policy.skip()
        policy.receive(.verified, generation: old)
        check(policy.status == .skipped, "in-flight result cannot override session skip")
        print("SUCCESS: \(checks) launch pairing regression checks passed")
    }
}
