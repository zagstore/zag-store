import Foundation
import Combine

@MainActor private final class PairingService: ZagLaunchPairingService {
    var hasPairingRecord = false
    var isBusy = false
    let events = PassthroughSubject<ZagOnboardingPolicy.Verification, Never>()
    let successes = PassthroughSubject<Void, Never>()
    var checks = 0
    var verificationEvents: AnyPublisher<ZagOnboardingPolicy.Verification, Never> { events.eraseToAnyPublisher() }
    var setupSuccesses: AnyPublisher<Void, Never> { successes.eraseToAnyPublisher() }
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

        for result in [ZagOnboardingPolicy.Verification.invalid, .failed, .unknown] {
            let service = PairingService(); service.hasPairingRecord = true
            let gate = launch(service)
            check(!gate.policy.canEnterMain, "saved file cannot bypass pending \(result) verification")
            await settle()
            check(service.checks == 1, "one authoritative check requested for \(result)")
            service.events.send(result)
            check(!gate.policy.canEnterMain && gate.policy.status != .checking,
                  "invalid/stale/revoked, failed or unknown verification shows recoverable welcome: \(result)")
        }

        let stalled = PairingService(); stalled.hasPairingRecord = true
        let timeout = launch(stalled, timeout: 20_000_000)
        await settle()
        try await Task.sleep(nanoseconds: 80_000_000)
        check(timeout.policy.status == .timedOut && !timeout.policy.canEnterMain, "verification timeout cannot block indefinitely or enter app")
        stalled.events.send(.verified)
        check(timeout.policy.status == .timedOut, "late result after timeout ignored")
        timeout.retry()
        await settle()
        stalled.events.send(.verified)
        check(timeout.policy.status == .verified, "retry recovers from timeout")

        let busy = PairingService(); busy.hasPairingRecord = true; busy.isBusy = true
        let busyGate = launch(busy, timeout: 20_000_000)
        try await Task.sleep(nanoseconds: 80_000_000)
        check(busy.checks == 0 && busyGate.policy.status == .timedOut, "unavailable/busy service is bounded and never overlaps native workers")

        let valid = PairingService(); valid.hasPairingRecord = true
        let verified = launch(valid)
        let url = URL(string: "zagstore://settings/installation")!
        verified.enqueue(url)
        check(verified.takeURLs().isEmpty, "deep link held while verification and splash pending")
        verified.finishSplash()
        check(verified.takeURLs().isEmpty, "splash completion cannot dispatch links or expose main before verification")
        await settle()
        valid.events.send(.verified)
        check(verified.policy.canEnterMain, "positively verified operational pairing bypasses welcome")
        check(verified.takeURLs() == [url] && verified.takeURLs().isEmpty, "pending deep link delivered once after verification and splash")
        verified.startIfNeeded()
        check(valid.checks == 1 && verified.policy.canEnterMain, "background/foreground or repeated view task does not restart onboarding")

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
        check(next.policy.status == .checking && !next.policy.canEnterMain, "successful pairing followed by cold relaunch must reverify")
        await settle()
        setup.events.send(.failed)
        check(!next.policy.canEnterMain, "previous native success cannot hide stale pairing on next cold launch")

        var policy = ZagOnboardingPolicy()
        let old = policy.beginIfNeeded(hasRecord: true)!
        policy.skip()
        policy.receive(.verified, generation: old)
        check(policy.status == .skipped, "in-flight result cannot override session skip")
        print("SUCCESS: \(checks) launch pairing regression checks passed")
    }
}
