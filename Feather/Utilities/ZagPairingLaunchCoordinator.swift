import Foundation
import Combine

/// An event bridge to the existing RPPairing engine, not a pairing implementation.
@MainActor protocol ZagLaunchPairingService: AnyObject {
    var hasPairingRecord: Bool { get }
    var isBusy: Bool { get }
    var verificationEvents: AnyPublisher<ZagOnboardingPolicy.Verification, Never> { get }
    var setupSuccesses: AnyPublisher<Void, Never> { get }
    func verify()
}

@MainActor final class ZagPairingLaunchCoordinator: ObservableObject {
    @Published private(set) var policy = ZagOnboardingPolicy()
    private let service: any ZagLaunchPairingService
    private let timeoutNanoseconds: UInt64
    private var verification: AnyCancellable?
    private var setup: AnyCancellable?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(service: any ZagLaunchPairingService, timeoutNanoseconds: UInt64 = 15_000_000_000) {
        self.service = service
        self.timeoutNanoseconds = timeoutNanoseconds
        setup = service.setupSuccesses.sink { [weak self] in
            guard let self, !self.policy.canEnterMain else { return }
            // A new authenticated native setup completion, never a replayed file/status.
            self.policy.setupSucceeded()
            self.stopWaiting()
        }
    }

    func startIfNeeded() {
        guard !policy.started else { return }
        let token = policy.beginIfNeeded(hasRecord: service.hasPairingRecord)
        if let token { check(token) }
    }

    func retry() {
        guard !policy.canEnterMain, policy.status != .checking else { return }
        stopWaiting()
        if let token = policy.retry(hasRecord: service.hasPairingRecord) { check(token) }
    }

    func skip() { policy.skip(); stopWaiting() }
    func finishSplash() { policy.finishSplash() }
    func enqueue(_ url: URL) { policy.enqueue(url) }
    func takeURLs() -> [URL] { policy.takeURLs() }

    private func check(_ token: Int) {
        deadline = Task { [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            self?.finish(.timedOut, token: token)
        }
        worker = Task { [weak self] in
            guard let self else { return }
            // Never overlap a native worker or adopt a previous check's late result.
            // The deadline covers waiting for transport as well as verification.
            while self.service.isBusy {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            guard !Task.isCancelled, self.policy.generation == token else { return }
            guard self.service.hasPairingRecord else { self.finish(.missing, token: token); return }
            self.verification = self.service.verificationEvents.sink { [weak self] result in
                self?.finish(result, token: token)
            }
            self.service.verify()
        }
    }

    private func finish(_ result: ZagOnboardingPolicy.Verification, token: Int) {
        guard policy.generation == token, policy.status == .checking else { return }
        policy.receive(result, generation: token)
        stopWaiting()
    }

    private func stopWaiting() {
        verification = nil
        worker?.cancel()
        worker = nil
        deadline?.cancel()
        deadline = nil
    }
}
