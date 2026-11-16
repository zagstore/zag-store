import Combine

/// Host input fixture only. Production presentation logic is compiled verbatim.
/// Mirrors the core's publication contract: every exact state reaches
/// gate4StatePublisher after it is stored; whole-object invalidation is coarse.
@MainActor final class ZagRPPairingCore: ObservableObject {
    static let shared = ZagRPPairingCore()
    enum Gate4State: Equatable {
        case idle, starting, pairVerified, tunnel, rsd, installing
        case uploading(Int), staged, upgradeSubmitted, progress(Int), complete, failed(String)
    }
    private(set) var gate4State: Gate4State = .idle {
        willSet {
            switch (gate4State, newValue) {
            case let (.uploading(a), .uploading(b)), let (.progress(a), .progress(b)):
                if ZagGate4PublicationPolicy.invalidatesViews(fromPercent: a, toPercent: b) { objectWillChange.send() }
            default:
                if gate4State != newValue { objectWillChange.send() }
            }
        }
        didSet { subject.send(gate4State) }
    }
    private let subject = CurrentValueSubject<Gate4State, Never>(.idle)
    var gate4StatePublisher: AnyPublisher<Gate4State, Never> { subject.eraseToAnyPublisher() }
    var isGate4Running: Bool {
        switch gate4State {
        case .starting, .pairVerified, .tunnel, .rsd, .installing, .uploading, .staged, .upgradeSubmitted, .progress: return true
        default: return false
        }
    }
    func emit(_ state: Gate4State) { gate4State = state }
}
