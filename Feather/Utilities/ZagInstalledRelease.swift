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

    /// "1.0.0 Beta 4"; a stable release is its version alone.
    var label: String {
        channel == "beta" || channel == "nightly"
            ? "\(version) \(ZagUpdateChannelPresentation.title(for: channel)) \(build)"
            : version
    }

    var title: String { "Zag Store \(label)" }

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
