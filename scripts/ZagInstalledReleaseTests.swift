import Foundation

// Installed-release presentation: What's New extraction from signed release
// notes, release labels and installation dates. Run by
// scripts/test-zag-installed-release.sh; no network, no device.

/// The signed Beta 4 release notes, byte for byte from the sequence-7 payload.
let beta4Notes = #"""
# Zag Store 1.0.0 — Beta 4 (Build 4)

Beta 4 rebuilds the in-app update experience and refines pairing, installation and onboarding.

## What's new

- **Software Update:** Measured download and transfer progress, a continuous update control and expandable release notes.
- **Confirmed handoff:** An in-app update finishes only after iOS acknowledges the update request. Restart to Complete then closes Zag Store so iOS can finish installing.
- **Installed-version check:** After an update, Zag Store confirms on the next launch that the new version is installed.
- **Welcome and Installation:** A new welcome flow, with clearer Installation, pairing and Developer Mode status.
- **Pairing:** Pairing removal is local and recoverable, and pairing codes are no longer copied to the clipboard automatically.
- **Fixes:** Safer handling of links that open Zag Store, an Account Activity navigation fix and more reliable source refresh.

## Download

Download `ZagStore-1.0.0-beta.4.ipa`.

SHA-256:
`1acb00079417473ab5384179586d254d289384d8ae40aa510029629083820ad3`

The IPA is unsigned. You must sign it using your own Apple signing certificate and provisioning profile.

Requires iOS/iPadOS 16.4 or later.

## Updating

Beta 2 and later use the `zag-v2-2026-b` update-signing trust key.

The signed Beta 4 in-app update will become available after its separately verified update manifest is published.

## Source

Commit: `c5b517b441a5687dedc8f3e2d46dc35f0e3787f4`

Source: https://github.com/zagstore/zag-store

Zag Store is based on Feather and distributed under GPL-3.0.
"""#

@main
struct ZagInstalledReleaseTests {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        print((condition ? "PASS: " : "FAIL: ") + message)
        if !condition { failures += 1 }
    }

    static func main() {
        // What's New: the introduction and the What's New items only.
        let whatsNew = ZagUpdateReleaseNotes.whatsNew(from: beta4Notes) ?? ""
        check(whatsNew.hasPrefix("Beta 4 rebuilds the in-app update experience and refines pairing, installation and onboarding."),
              "Beta 4 starts with its approved introduction")
        for item in ["**Software Update:**", "**Confirmed handoff:**", "**Installed-version check:**",
                     "**Welcome and Installation:**", "**Pairing:**", "**Fixes:**"] {
            check(whatsNew.contains("- " + item), "keeps What's New item \(item)")
        }
        for excluded in ["# Zag Store 1.0.0", "## What's new", "## Download", "## Updating", "## Source",
                         "SHA-256", "1acb0007", "unsigned", "zag-v2-2026-b", "Commit:", "github.com", "GPL-3.0",
                         "ZagStore-1.0.0-beta.4.ipa", "iOS/iPadOS 16.4"] {
            check(!whatsNew.contains(excluded), "leaves out \(excluded)")
        }
        let approved = beta4Notes.components(separatedBy: "\n## What's new\n")[1].components(separatedBy: "\n## Download")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check(whatsNew.hasSuffix(approved), "the What's New items are verbatim")
        check(ZagUpdateReleaseNotes.whatsNew(from: "# T\n\nIntro.\n\n## What’s New\n\n- A\n\n### Fixes\n\n- B\n\n## Source\n\nx") == "Intro.\n\n- A\n\n### Fixes\n\n- B",
              "curly apostrophe heading and its subsections are kept; later sections are not")
        check(ZagUpdateReleaseNotes.whatsNew(from: "Plain notes.\n\nSecond line.") == "Plain notes.\n\nSecond line.",
              "notes without sections are kept whole")
        check(ZagUpdateReleaseNotes.whatsNew(from: "# Title\n\n## Download\n\nhash") == nil,
              "nothing user-facing gives no notes")
        check(ZagUpdateReleaseNotes.whatsNew(from: nil) == nil && ZagUpdateReleaseNotes.whatsNew(from: "  \n") == nil,
              "absent notes stay absent")

        // Labels follow the installed identity and channel.
        func release(_ channel: String, version: String = "1.0.0", build: String = "4") -> ZagInstalledRelease {
            ZagInstalledRelease(version: version, build: build, channel: channel, installedAt: nil, whatsNew: nil)
        }
        check(release("beta").label == "1.0.0 Beta 4", "Software Update's subtitle reads 1.0.0 Beta 4")
        check(release("nightly", version: "1.1.0", build: "12").label == "1.1.0 Nightly 12", "nightly is labelled by its build")
        check(release("stable", version: "1.2.0", build: "9").label == "1.2.0", "stable is its version alone")
        check(release("nightly").releaseName == "1.0.0 Nightly" && release("nightly").buildText == "(Build 4)",
              "More Details: 1.0.0 Nightly, then (Build 4), without Zag Store")
        check(release("beta").releaseName == "1.0.0 Beta" && release("beta").versionText == "1.0.0 Beta (Build 4)",
              "More Details: Beta (Build 4)")
        check(release("stable").releaseName == "1.0.0" && release("stable").versionText == "1.0.0 (Build 4)",
              "More Details: Stable keeps its build, without a channel")

        // Settings footer's system line, from the running device.
        check(ZagInstalledRelease.systemText(name: "iOS", version: "27.2.1", build: "24B156") == "iOS 27.2.1 (24B156)",
              "system line: iOS 27.2.1 (24B156)")
        check(ZagInstalledRelease.systemText(name: "iPadOS", version: "26.1", build: "23B85") == "iPadOS 26.1 (23B85)",
              "system line: the device's own OS name")
        for missing: String? in [nil, "", "  "] {
            check(ZagInstalledRelease.systemText(name: "iOS", version: "27.2.1", build: missing) == "iOS 27.2.1",
                  "system line: no build identifier from \(String(describing: missing))")
        }

        // Settings footer: the channel comes from the bundle's own metadata.
        func info(_ channel: Any?) -> [String: Any] {
            var info: [String: Any] = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "4"]
            info["ZagReleaseChannel"] = channel
            return info
        }
        check(ZagInstalledRelease.settingsVersion(info: info("nightly")) == "Version 1.0.0 Nightly (Build 4)", "footer: Nightly (Build 4)")
        check(ZagInstalledRelease.settingsVersion(info: info("beta")) == "Version 1.0.0 Beta (Build 4)", "footer: Beta (Build 4)")
        check(ZagInstalledRelease.settingsVersion(info: info("Nightly")) == "Version 1.0.0 Nightly (Build 4)", "footer: channel case is ignored")
        check(ZagInstalledRelease.settingsVersion(info: info("stable")) == "Version 1.0.0 (Build 4)", "footer: Stable is never labelled Beta or Nightly")
        for missing: Any? in [nil, "", "$(ZAG_RELEASE_CHANNEL)", "off", 4] {
            check(ZagInstalledRelease.settingsVersion(info: info(missing)) == "Version 1.0.0 (Build 4)",
                  "footer: no channel from \(String(describing: missing))")
        }
        check(ZagInstalledRelease.bundleChannel(info: info("beta")) == "beta" && ZagInstalledRelease.bundleChannel(info: info("off")) == nil,
              "bundle channel accepts only stable, beta and nightly")

        // Installation dates.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let gb = Locale(identifier: "en_GB")
        check(ZagInstalledRelease.installedText(now.addingTimeInterval(-3600), now: now, calendar: calendar, locale: gb) == "Installed Today", "today")
        check(ZagInstalledRelease.installedText(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: gb) == "Installed Yesterday", "yesterday")
        check(ZagInstalledRelease.installedText(now.addingTimeInterval(-2 * 86_400), now: now, calendar: calendar, locale: gb) == "Installed 16 November 2026", "older dates in the user's locale")
        check(ZagInstalledRelease.installedText(now.addingTimeInterval(-2 * 86_400), now: now, calendar: calendar, locale: Locale(identifier: "en_US")) == "Installed November 16, 2026", "locale decides the date order")
        let start = now.addingTimeInterval(-600)
        check(ZagInstalledRelease.installationDate(startedAt: start, bundleCreated: now.addingTimeInterval(-300), latest: now) == now.addingTimeInterval(-300),
              "the bundle's creation inside the window is the installation time")
        check(ZagInstalledRelease.installationDate(startedAt: start, bundleCreated: start.addingTimeInterval(-1), latest: now) == nil,
              "a bundle older than the update is not this installation")
        check(ZagInstalledRelease.installationDate(startedAt: start, bundleCreated: now.addingTimeInterval(1), latest: now) == nil,
              "a time after the verified launch is rejected")
        check(ZagInstalledRelease.installationDate(startedAt: start, bundleCreated: nil, latest: now) == nil, "no bundle date, no date")

        let updated = ZagInstalledRelease(version: "1.0.0", build: "4", channel: "nightly", installedAt: start, whatsNew: nil)
        check(updated.dateText(now: now, calendar: calendar, locale: gb) == "Installed Today",
              "a verified in-app update has its installation date")
        check(ZagInstalledRelease(version: "1.0.0", build: "1", channel: "nightly", installedAt: nil, whatsNew: nil)
                .dateText(now: now, calendar: calendar, locale: gb) == nil,
              "a direct installation has no date line")

        print(failures == 0 ? "SUCCESS: installed-release checks passed" : "FAILED: \(failures) installed-release checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
