import Combine

@MainActor final class ZagRPPairingLaunchService: ObservableObject, ZagLaunchPairingService {
    static let shared = ZagRPPairingLaunchService()
    @Published private(set) var currentVerification: ZagOnboardingPolicy.Verification = .unknown
    private var observations: Set<AnyCancellable> = []

    init() {
        // Retain the same authenticated events used by onboarding after it stops
        // waiting. Unlike VPN readiness, pairing validity does not expire on a timer.
        verificationEvents.sink { [weak self] in self?.currentVerification = $0 }
            .store(in: &observations)
        setupSuccesses.sink { [weak self] in self?.currentVerification = .verified }
            .store(in: &observations)
        core.$localPairingCleanupPending.sink { [weak self] pending in
            if pending { self?.currentVerification = .missing }
        }.store(in: &observations)
        core.$gate2State.sink { [weak self] _ in
            guard let self else { return }
            if !self.hasPairingRecord { self.currentVerification = .missing }
        }.store(in: &observations)
    }

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
    convenience init() { self.init(service: ZagRPPairingLaunchService.shared) }
}
