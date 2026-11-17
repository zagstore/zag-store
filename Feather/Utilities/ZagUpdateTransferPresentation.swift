import Foundation
import Combine

/// A lightweight presentation stream. It never replaces the native event
/// archive, installer completion callback or recovery classification.
@MainActor final class ZagUpdateTransferPresentation: ObservableObject {
    enum Phase: Equatable { case none, transfer, installation }
    private struct Sample: Equatable { let generation: Int; let percent: Int }
    @Published private(set) var fraction: Double?
    private(set) var phase: Phase = .none
    private(set) var authoritativePercent: Int?
    private var generation = 0
    private let samples = PassthroughSubject<Sample, Never>()
    private var subscription: AnyCancellable?

    init() {
        subscription = samples.removeDuplicates()
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] sample in
                guard let self, sample.generation == self.generation else { return }
                self.publish(sample.percent)
            }
    }

    func receive(phase: Phase, percent: Int?) {
        if self.phase != phase {
            self.phase = phase
            generation += 1
            authoritativePercent = nil
            if fraction != nil { fraction = nil }
        }
        guard phase != .none, let percent, (0...100).contains(percent) else { return }
        if let previous = authoritativePercent, percent <= previous { return }
        authoritativePercent = percent
        if fraction == nil {
            publish(percent) // First real sample of a new phase is immediate.
        } else {
            samples.send(.init(generation: generation, percent: percent))
        }
    }

    private func publish(_ percent: Int) {
        let value = Double(percent) / 100
        // A throttled older sample must not overtake a newer first sample.
        if let previous = fraction, value <= previous { return }
        fraction = value
    }
}
