import Foundation
import Combine

/// Native engine boundary double: the production event bridge/classifier is compiled below.
@MainActor final class ZagRPPairingCore: ObservableObject {
    static let shared = ZagRPPairingCore()
    enum State { case idle, starting, paired }
    enum Gate2State { case idle, starting, pairRecord(String), complete, failed(String) }
    @Published var state: State = .idle
    @Published var gate2State: Gate2State = .idle
    var pairingFileExists = true
    var localPairingCleanupPending = false
    var isTransportBusy = false
    var isGate2Running = false
    var isRunning = false
    var gate2Endpoint: ZagRPPairingEndpoint = .localDevVPN
    var checks = 0
    func startGate2Probe(endpoint: ZagRPPairingEndpoint) {
        checks += 1
        gate2Endpoint = endpoint
        gate2State = .starting
    }
}

@main struct ServiceTests {
    @MainActor static func main() {
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        let core = ZagRPPairingCore.shared
        core.gate2State = .complete
        core.state = .paired
        let service = ZagRPPairingLaunchService()
        var results: [ZagOnboardingPolicy.Verification] = []
        var successes = 0
        let checkSubscription = service.verificationEvents.sink { results.append($0) }
        let setupSubscription = service.setupSuccesses.sink { successes += 1 }
        defer { checkSubscription.cancel(); setupSubscription.cancel() }
        check(results.isEmpty && successes == 0, "cached health-check/setup successes never grant entry")
        core.localPairingCleanupPending = true
        check(!service.hasPairingRecord, "pending local cleanup blocks cold-launch entry even if a file remains")
        core.gate2State = .complete
        core.state = .paired
        check(results.isEmpty && successes == 0, "pending cleanup rejects late native success events")
        core.localPairingCleanupPending = false
        check(service.hasPairingRecord, "cleanup recovery restores eligibility for a fresh check only")
        service.verify()
        check(core.checks == 1 && core.gate2Endpoint == .localDevVPN, "launch uses existing production-endpoint Gate 2 verifier")
        core.gate2State = .pairRecord("accepted")
        check(results.isEmpty, "partial credential verification is not operational health-check completion")
        core.gate2State = .complete
        check(results == [.verified], "new operational health-check completion grants entry")
        core.gate2Endpoint = .loopbackExperimental
        core.gate2State = .complete
        check(results == [.verified], "experimental-endpoint result cannot bypass launch")
        core.gate2Endpoint = .localDevVPN
        core.gate2State = .failed("Unable to read saved RPPairing credentials: malformed file")
        check(results.last == .invalid, "corrupt record classified invalid")
        core.gate2State = .failed("RPPairing pair-verify failed: rejected")
        check(results.last == .invalid, "stale/revoked credentials classified invalid")
        core.gate2State = .failed("Unable to reach RPPairing at 10.7.0.1:49152")
        check(results.last == .unknown, "unavailable transport reports unknown, not unpaired")
        core.gate2State = .failed("The Gate 2 probe could not be started.")
        check(results.last == .failed, "verification startup failure stays behind welcome")
        core.state = .starting
        check(successes == 0, "opening/starting pairing is not success")
        core.state = .paired
        check(successes == 1, "only fresh native setup completion exits welcome")
        print("SUCCESS: 14 production pairing event-bridge checks passed")
    }
}
