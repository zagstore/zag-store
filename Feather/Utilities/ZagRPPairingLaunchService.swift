import Combine

@MainActor final class ZagRPPairingLaunchService: ZagLaunchPairingService {
    private let core = ZagRPPairingCore.shared
    var hasPairingRecord: Bool { core.pairingFileExists && !core.localPairingCleanupPending }
    var isBusy: Bool { core.isTransportBusy || core.isGate2Running || core.isRunning }

    var verificationEvents: AnyPublisher<ZagOnboardingPolicy.Verification, Never> {
        // Drop the publisher's initial cached value. Only this new live check counts.
        core.$gate2State.dropFirst().compactMap { [weak self] state -> ZagOnboardingPolicy.Verification? in
            guard self?.core.gate2Endpoint == .localDevVPN, self?.core.localPairingCleanupPending == false else { return nil }
            switch state {
            case .complete: return .verified
            case .failed(let message):
                switch ZagRPPairingFailure.classify(message, installationStarted: false) {
                case .pairingFile, .pairingRejected: return .invalid
                case .deviceUnreachable, .connectionInterrupted, .sessionSetup: return .unknown
                default: return .failed
                }
            default: return nil
            }
        }.eraseToAnyPublisher()
    }

    var setupSuccesses: AnyPublisher<Void, Never> {
        core.$state.dropFirst().compactMap { [weak self] state -> Void? in
            guard self?.core.localPairingCleanupPending == false else { return nil }
            if case .paired = state { return () }
            return nil
        }.eraseToAnyPublisher()
    }

    func verify() {
        // Diagnostic mode validates a copy of the saved credentials without
        // pair-setup fallback or rewriting them, then checks the device services.
        core.startGate2Probe(endpoint: .localDevVPN)
    }
}

extension ZagPairingLaunchCoordinator {
    convenience init() { self.init(service: ZagRPPairingLaunchService()) }
}
