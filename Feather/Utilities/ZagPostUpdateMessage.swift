import Foundation

/// A notice is created only from the same executable-identity proof used for
/// installed-update reconciliation. Neither a download nor an installer callback is proof.
struct ZagPostUpdateMessage: Codable, Equatable {
    enum Channel: String, Codable, CaseIterable {
        case stable, beta, nightly
        var title: String { rawValue.capitalized }
    }
    struct RunningIdentity: Equatable {
        let bundleIdentifier: String
        let version: String
        let build: String
        let executableSHA256: String
    }
    struct Candidate {
        let bundleIdentifier: String
        let version: String
        let build: String
        let channel: String?
        let expectedExecutableSHA256: String?
        let originatingExecutableSHA256: String?
        var originatingVersion: String? = nil
        var originatingBuild: String? = nil

        func verifiedMessage(running: RunningIdentity) -> ZagPostUpdateMessage? {
            guard ZagPostUpdateMessage.isReleaseAdvance(version: version, build: build,
                                                        fromVersion: originatingVersion, fromBuild: originatingBuild),
                  !bundleIdentifier.isEmpty, !version.isEmpty, !build.isEmpty,
                  bundleIdentifier == running.bundleIdentifier,
                  version == running.version, build == running.build,
                  let channel = channel.flatMap(Channel.init(rawValue:)),
                  let expected = expectedExecutableSHA256,
                  let original = originatingExecutableSHA256,
                  ZagPostUpdateMessage.isDigest(expected), ZagPostUpdateMessage.isDigest(original),
                  expected.caseInsensitiveCompare(running.executableSHA256) == .orderedSame,
                  original.caseInsensitiveCompare(running.executableSHA256) != .orderedSame else { return nil }
            return ZagPostUpdateMessage(bundleIdentifier: running.bundleIdentifier,
                                        version: running.version, build: running.build,
                                        channel: channel, executableSHA256: expected.lowercased())
        }
    }
    let bundleIdentifier: String
    let version: String
    let build: String
    let channel: Channel
    let executableSHA256: String

    /// Exactly three reveal groups preserve the cinematic signature's timing.
    var tokens: [String] { ["Updated", "to", "\(version) \(channel.title) \(build)"] }
    var text: String { tokens.joined(separator: " ") }
    var identity: String { [bundleIdentifier, version, build, executableSHA256].joined(separator: "|") }

    func matches(_ running: RunningIdentity) -> Bool {
        bundleIdentifier == running.bundleIdentifier && version == running.version && build == running.build
            && Self.isDigest(executableSHA256)
            && executableSHA256.caseInsensitiveCompare(running.executableSHA256) == .orderedSame
    }

    /// A differently signed executable with identical release labels is not a
    /// new release. Legacy records without a source version require a higher build.
    static func isReleaseAdvance(version: String, build: String,
                                 fromVersion: String?, fromBuild: String?) -> Bool {
        guard let fromBuild, !fromBuild.isEmpty else { return false }
        guard let fromVersion, !fromVersion.isEmpty else {
            return fromBuild.compare(build, options: .numeric) == .orderedAscending
        }
        let order = fromVersion.compare(version, options: .numeric)
        return order == .orderedAscending || (order == .orderedSame && fromBuild.compare(build, options: .numeric) == .orderedAscending)
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { "0123456789abcdefABCDEF".unicodeScalars.contains($0) }
    }
}

/// Persist before showing; acknowledge only after the signature has actually been
/// revealed. A skip, disabled splash or app termination leaves it pending.
struct ZagPostUpdateMessageStore {
    private let defaults: UserDefaults
    private let pendingKey = "ZagStore.selfUpdate.pendingSplashMessage.v1"
    private let displayedKey = "ZagStore.selfUpdate.displayedSplashMessage.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func record(_ candidate: ZagPostUpdateMessage.Candidate,
                running: ZagPostUpdateMessage.RunningIdentity) -> ZagPostUpdateMessage? {
        guard let message = candidate.verifiedMessage(running: running),
              defaults.string(forKey: displayedKey) != message.identity,
              let data = try? JSONEncoder().encode(message) else { return nil }
        defaults.set(data, forKey: pendingKey)
        return message
    }

    func pending(running: ZagPostUpdateMessage.RunningIdentity) -> ZagPostUpdateMessage? {
        guard let data = defaults.data(forKey: pendingKey),
              let message = try? JSONDecoder().decode(ZagPostUpdateMessage.self, from: data),
              message.matches(running), defaults.string(forKey: displayedKey) != message.identity else { return nil }
        return message
    }

    func acknowledgeDisplayed(_ message: ZagPostUpdateMessage) {
        guard let data = defaults.data(forKey: pendingKey),
              let pending = try? JSONDecoder().decode(ZagPostUpdateMessage.self, from: data),
              pending == message else { return }
        defaults.set(message.identity, forKey: displayedKey)
        defaults.removeObject(forKey: pendingKey)
    }
}
