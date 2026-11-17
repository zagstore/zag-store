# Native Software Update: up to date and More Details

Builds on `cfb52009` (green completion pill at verified staging, three-part
splash). Neither is touched here: no change to the action control, spectrum,
morph, handoff states, native code, splash files or next-launch verification.

## References

The owner's iOS Settings screenshots (iPhone, 1290 × 2796 px, 430 × 932 pt,
dark, Dynamic Type xLarge: list rows measure 19 pt): *Software Update* ("iOS is
up to date") and *iOS Version*. Fonts were identified by fitting SF Pro widths
to the measured glyph extents; positions by scanning rows of pixels.

| Element | Reference | Implementation |
|---|---|---|
| Disc | 43 pt, systemGray (139,139,144) | `@ScaledMetric(relativeTo: .title3)` 39 → 43 pt at xLarge, `.systemGray` |
| Checkmark | ~20 pt glyph, heavy stroke (~3.4 pt) | SF Symbol `checkmark`, bold, 20 → 22 pt font; cut-out colour (grouped background) |
| Heading | 22 pt bold | `.title3.weight(.bold)` |
| Version | 22 pt regular, secondaryLabel | `.title3`, `UIColor.secondaryLabel` |
| More Details | 19 pt, systemBlue | `.body`, `UIColor.systemBlue`, borderless (only the label taps) |
| Gaps | disc → heading 28.4, heading → version 9.7, version → link 39.3 pt (glyph to glyph) | 28.4, 10.4, 39.6 pt measured in the simulator |
| Position | centred between the section and the bottom safe area, 3 pt low | `ZagUpToDateLayout`: within 1 pt |
| Details header | 19 pt semibold, secondaryLabel, x 41 pt | `.headline`, `secondaryLabel`, no text case |
| Version title | 22 pt semibold | `.title3.weight(.semibold)` (bold measures 21.3 pt, not a text style) |
| Installed … | 19 pt, secondaryLabel, 211.3 pt | `.body`, `secondaryLabel`; 211.3 pt |
| Notes | 19 pt, inset 8 pt from the title, 24 pt line pitch, 20 pt between paragraphs | `.body`, `.padding(.horizontal, 8)`, 20 pt between paragraphs, 10 pt between list items |

Simulator captures: `scripts/capture-zag-software-update-screens.sh <dir>
[notes.md]` (iPhone 17 Pro Max, 440 × 956 pt, xLarge, dark and light, the
production views with a sample Beta 4 release). Known differences: the
existing Form starts its settings section 20 pt lower than iOS Settings (not
changed here); colours on device follow that device's iOS (systemBlue renders
(0,133,234) in the iOS 26.5 simulator).

## When the up-to-date state shows

Only when a completed check of the selected channel found nothing newer
(`upToDateChannel`, cleared by a newer release, a failed check or a channel
change), there is no pending installation, and nothing is downloading,
preparing or installing. Otherwise the existing sections remain, including
`Previous update not confirmed`, the available-update card and the green
`Restart to Complete...` pill. Pull to refresh runs the existing manual check.

The old card (green seal, "Zag Store Updated", "Installation verified
successfully", the executable-verification text) is removed; verification
itself is unchanged.

## Installed-release record

The existing pending record gains two optional fields, decoded as absent from
older records:

- `whatsNew`: `ZagUpdateReleaseNotes.whatsNew(from:)` of the release's signed
  notes, captured when the pending record is written (before the transfer).
- `installedAt`: set only when next-launch executable verification moves the
  record to `completed`.

Nothing becomes installed-release data before that verification: More Details
reads the completed record only when `installedIdentityVerified` holds and the
record's bundle ID, version and build are the running ones. A pending,
rejected or unverified attempt never replaces it. The record holds no
credentials; it already held the executable hashes for verification.

### Installation time

Three moments are known: the update started (`startedAt`, before the
transfer), the IPA was staged (209, not recorded; not installation) and the
new executable's first verified launch. iOS creates the app bundle when it
installs it, so the bundle's creation date is the installation time. It is
used only inside the one possible window, after `startedAt` and no later than
the verified launch; otherwise the verified launch is recorded (installed no
later than then). Records from before this change get the bundle date only if
it falls inside their own window, else no date is shown.

Format: "Installed Today", "Installed Yesterday", otherwise the long date in
the user's locale and calendar ("Installed 16 November 2026" in en_GB).

## What's New

The introduction under the title and the `What's New` section (heading
dropped, subsections kept). `Download`, `Updating`, `Source` and every other
section are left out; notes without sections are kept whole. The
available-update card uses the same extraction. Beta 4's approved wording is
shown verbatim.

## Labels

`ZagInstalledRelease.label`: beta and nightly read `<version> <Channel>
<build>` ("1.0.0 Beta 4"); stable reads the version alone. The channel is the
verified record's own, else the selected channel.

## Limitations

- Beta 4 copies updated before this change have a completed record without
  What's New, so More Details shows "Release notes for this version are not
  available." The date appears only if the bundle date falls in the record's
  window. Copies installed directly (not through the in-app updater) have no
  record: title only.
- The bundle creation date has not yet been observed on a device after a real
  in-place upgrade.
- On iOS 16 the section spacing is the system default (`listSectionSpacing`
  is iOS 17+), so the vertical position differs slightly there.
