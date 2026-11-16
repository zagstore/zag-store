import Combine

/// Host input fixture only. Production presentation logic is compiled verbatim.
@MainActor final class ZagRPPairingCore: ObservableObject {
    static let shared = ZagRPPairingCore()
    enum Gate4State: Equatable {
        case idle, starting, pairVerified, tunnel, rsd, installing
        case uploading(Int), staged, upgradeSubmitted, progress(Int), complete, failed(String)
    }
    @Published private(set) var gate4State: Gate4State = .idle
    var isGate4Running: Bool {
        switch gate4State {
        case .starting, .pairVerified, .tunnel, .rsd, .installing, .uploading, .staged, .upgradeSubmitted, .progress: return true
        default: return false
        }
    }
    func emit(_ state: Gate4State) { gate4State = state }
}
