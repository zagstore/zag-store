import Foundation

/// The running release as Software Update's More Details presents it. Details
/// beyond the running identity come only from the installation record that
/// next-launch executable verification has matched to this executable; a
/// download, staging (209) or an installer callback never supplies them.
struct ZagInstalledRelease: Equatable {
    let version: String
    let build: String
    /// `stable`, `beta` or `nightly`.
    let channel: String
    /// See `installationDate`. Nil when no trustworthy time is known.
    let installedAt: Date?
    /// The installed release's own What's New, from its signed release notes.
    let whatsNew: String?
    /// More Details' date line: only a verified in-app update's installation
    /// date. A direct IPA installation records no trustworthy event, and iOS
    /// gives no installation date, so it has no date line.
    func dateText(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        installedAt.map { Self.installedText($0, now: now, calendar: calendar, locale: locale) }
    }

    /// "1.0.0 Beta 4"; a stable release is its version alone.
    var label: String {
        channel == "beta" || channel == "nightly"
            ? "\(version) \(ZagUpdateChannelPresentation.title(for: channel)) \(build)"
            : version
    }

    /// "1.0.0 Nightly (Build 4)"; a stable release is "1.0.0 (Build 4)".
    var versionText: String { "\(releaseName) \(buildText)" }

    /// "1.0.0 Nightly"; a stable release is its version alone. More Details
    /// sets it in bold before `buildText`.
    var releaseName: String {
        channel == "beta" || channel == "nightly"
            ? "\(version) \(ZagUpdateChannelPresentation.title(for: channel))"
            : version
    }

    /// "(Build 4)".
    var buildText: String { "(Build \(build))" }

    /// The channel the running build was released on, from its own Info.plist
    /// (`ZagReleaseChannel`, set at build time). Never the selected update
    /// channel, which only says where the next update comes from. Missing or
    /// unrecognised values give nil.
    static func bundleChannel(info: [String: Any]) -> String? {
        guard let value = (info["ZagReleaseChannel"] as? String)?.lowercased(),
              ["stable", "beta", "nightly"].contains(value) else { return nil }
        return value
    }

    /// The Settings footer: "Version 1.0.0 Nightly (Build 4)" or "Version
    /// 1.0.0 Beta (Build 4)"; a Stable build, or one without a recorded
    /// channel, is "Version 1.0.0 (Build 4)" and is never given one.
    static func settingsVersion(info: [String: Any]) -> String {
        let release = ZagInstalledRelease(version: info["CFBundleShortVersionString"] as? String ?? "Unknown",
                                          build: info["CFBundleVersion"] as? String ?? "Unknown",
                                          channel: bundleChannel(info: info) ?? "stable",
                                          installedAt: nil, whatsNew: nil)
        return "Version \(release.versionText)"
    }

    /// When iOS installed the release. The record knows three moments: the
    /// update started (`startedAt`, before the transfer), the IPA was staged
    /// (209, not recorded) and the new executable was first verified on launch.
    /// iOS creates the app bundle while installing it, so the bundle's creation
    /// date is the installation time, accepted only inside the one window where
    /// the installation can have happened: after the update started and no
    /// later than the verified launch. Anything else is not used.
    static func installationDate(startedAt: Date, bundleCreated: Date?, latest: Date) -> Date? {
        guard let bundleCreated, bundleCreated >= startedAt, bundleCreated <= latest else { return nil }
        return bundleCreated
    }

    /// "Installed Today", "Installed Yesterday", otherwise the long date in the
    /// user's locale and calendar, e.g. "Installed 16 November 2026".
    /// The Settings footer's system line: "iOS 26.1 (23B85)", or "iOS 26.1"
    /// when the OS build is unknown.
    static func systemText(name: String, version: String, build: String?) -> String {
        guard let build = build?.trimmingCharacters(in: .whitespacesAndNewlines), !build.isEmpty else {
            return "\(name) \(version)"
        }
        return "\(name) \(version) (\(build))"
    }

    static func installedText(_ date: Date, now: Date = Date(),
                              calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Installed Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Installed Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return "Installed \(formatter.string(from: date))"
    }
}
