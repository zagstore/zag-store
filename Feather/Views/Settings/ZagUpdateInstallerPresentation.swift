import SwiftUI
import Combine

/// The screen observes stage changes only. Percentage publications belong to
/// the small action-control subtree, not the header/notes/preferences screen.
@MainActor final class ZagUpdateInstallerPresentation: ObservableObject {
    enum Stage: Equatable {
        case idle, starting, paired, tunnel, rsd, preparing, transfer, staged, submitted, installing, complete
        case failed(String)
    }
    @Published private(set) var stage: Stage = .idle
    let progress = ZagUpdateTransferPresentation()
    private var subscription: AnyCancellable?

    init(core: ZagRPPairingCore? = nil) {
        let core = core ?? .shared
        subscription = core.gate4StatePublisher.sink { [weak self] state in
            guard let self else { return }
            let next: Stage
            switch state {
            case .idle: next = .idle
            case .starting: next = .starting
            case .pairVerified: next = .paired
            case .tunnel: next = .tunnel
            case .rsd: next = .rsd
            case .installing: next = .preparing
            case .uploading: next = .transfer
            case .staged: next = .staged
            case .upgradeSubmitted: next = .submitted
            case .progress: next = .installing
            case .complete: next = .complete
            case .failed(let reason): next = .failed(reason)
            }
            switch state {
            case .uploading(let percent): progress.receive(phase: .transfer, percent: percent)
            case .progress(let percent): progress.receive(phase: .installation, percent: percent)
            default: progress.receive(phase: .none, percent: nil)
            }
            if stage != next { stage = next }
        }
    }
}

/// Only this child subscribes to measured fractions. Its structural identity is
/// unchanged when a percentage changes; the nested Canvas owns its own clock.
struct ZagUpdateTransferActionControl: View {
    let state: ZagSelfUpdateActionState
    let usesInstallerProgress: Bool
    var disabled = false
    @ObservedObject var progress: ZagUpdateTransferPresentation
    var complete: (() -> Void)?
    let action: () -> Void

    private var presentedState: ZagSelfUpdateActionState {
        if usesInstallerProgress, progress.phase != .none,
           case .progress(let message, _) = state {
            return .progress(message: message, fraction: progress.fraction)
        }
        return state
    }
    var body: some View {
        ZagSelfUpdateActionControl(state: presentedState, disabled: disabled, complete: complete, action: action)
    }
}

/// Live developer-only details can observe all diagnostic publications without
/// invalidating the normal update screen or its native navigation hierarchy.
struct ZagUpdateLiveInstallerDetails<Content: View>: View {
    @ObservedObject private var core = ZagRPPairingCore.shared
    @ViewBuilder let content: () -> Content
    var body: some View {
        let _ = core.gate4State
        content()
    }
}
