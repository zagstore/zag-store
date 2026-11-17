# RPPairing interface, notification and public API review

Branch: `codex/beta3-improvements`. Starting point: `2239dc2e`. Development only; version/build, signing configuration and release metadata unchanged. No IPA, signing, packaging, upload, push or merge. Other checkouts and production infrastructure untouched.

## Changes and source references

Notification/privacy commit: `22db97f4`.

- `Feather/RPPairing/ZagRPPairingCore.swift`: only the code-notification presentation block changes. The existing native PIN callback still sets `.pin(message)` and submits the same immediate notification request/category/identifier. The automatic `UIPasteboard.general.string = message` write is removed.
- `Feather/Utilities/ZagPairingCodeNotification.swift`: title **Pairing Code**, body exactly six ASCII digits including leading zeroes; existing default sound, category and time-sensitive interruption level. Malformed callback strings do not become notification bodies. Completion removal and the separate pairing-complete notification are unchanged.
- `scripts/ZagPairingCodeNotificationTests.swift`, `scripts/test-zag-pairing-notification.sh`: real notification-content regressions and callback/lifecycle checks.

Interface commit: the following commit contains these files and this report.

- `Feather/Views/Settings/Installation/InstallationView.swift`: moves the existing Pair/Unpair button intact above Pairing File in the same Control section. Export, saved/not-saved indicators, destructive confirmation, errors, disabled state and other sections retain their behavior. The existing footer now reads exactly: **Settings App → Privacy & Security → Developer Mode → Pair with Zag Store**. It keeps native Section secondary styling and allows vertical wrapping. No Settings navigation button is added.
- The active PIN presentation gains an explicit **Copy Pairing Code** button. Only tapping it writes the validated six-digit code to the general clipboard, with `localOnly: true` and a two-minute expiration. It does not read the clipboard or copy in response to a callback, foreground event or notification. The existing selectable code remains. Standard text-selection Copy is also an explicit user action, but uses the system's ordinary clipboard behavior; the local-only expiration guarantees apply to the dedicated button.
- `Feather/Views/Settings/Installation/ZagPairingIcon.swift`: reusable SwiftUI vector. The source reference is `ZagPhoneSettingsIcon` in `SettingsView.swift`, used by the Bottom Dock and Splash Screen rows at 25 × 25 points: continuous phone corner ratio 0.23, shell 0.68 × width / 0.96 × height, 1.8-point stroke, island 0.18 × width / 0.052 × height and -0.35 × height offset. The central Z uses the original `ZagSourcesTabIcon.swift` 30-unit path (5.1,6.6 → 24.7,6.6 → 5.1,23.4 → 24.7,23.4), 5.8-unit rounded stroke, scaled to the source settings icon's 0.34 proportions. One rounded Bezier radio arc is mirrored on each side. All parts inherit the row tint (including destructive red), without raster assets or another icon set. Status icons share a 25-point label column; the existing 22-point trailing indicator slot stays unchanged. The original Dock/Splash/Settings icon sources and artwork are untouched.
- `scripts/test-zag-pairing-interface.sh`: row-order, control count, exact instructions, icon wiring, copy opt-in and unsupported-route guards.
- `scripts/test-zag-device-link.sh`: narrows the historical whole-core equality check only around PIN presentation, while retaining byte equality for every installer/verification/transport method and the PIN state/delivery lifecycle. The new notification suite covers that allowed presentation block.

The three screenshot attachments were not exposed in this session's available conversation content. Source geometry and native row structure were used; no screenshot pixel-match is claimed.

## Code origin and delivery

The existing native engine generates a zero-padded six-digit PIN in `IDeviceKitten/idevice/src/remote_pairing/responder.rs`, during SRP pair setup. `RPPairingCore/rust-core/src/lib.rs` forwards it as callback code 4; the Swift core publishes it and schedules a local notification. No code generation, protocol, credentials, verification, transport, LocalDevVPN or background task implementation changed. No code is added to analytics, logs, URLs, remote services, notification userInfo or unrelated UI.

The existing background execution budget remains finite. iOS can deliver an already-scheduled notification while the app is backgrounded; notification scheduling does not extend pairing execution or keep the process alive. Notification permission, preview settings, Focus and time-sensitive-notification preferences still control what the user sees. Foreground notification handling is unchanged; no new delegate forces a banner. The same request identifier and completion removal retain the existing code lifecycle. Clipboard expiration is separate from pairing validity; no protocol timeout or validity rule changes.

## Native keyboard AutoFill findings

1. `.oneTimeCode` describes the input an app owns. It does not publish a generated code, and Zag Store cannot set text-input traits on a Settings-owned pairing field. Apple's documented example is an SMS code entry field. [Apple: enabling AutoFill on a text input view](https://developer.apple.com/documentation/security/enabling-password-autofill-on-a-text-input-view).
2. Apple's domain-bound SMS mechanism ties suggestions to a website or associated app domain. The RPPairing callback/local notification is not an SMS and has no such association with Settings. No SMS, email or fake account flow was added. [Apple: domain-bound SMS codes](https://developer.apple.com/documentation/security/enabling-autofill-for-domain-bound-sms-codes).
3. A supported general OTP-provider API does exist: a user-enabled Credential Provider Extension with the AutoFill entitlement and `ProvidesOneTimeCodes`, responding to system OTP requests. The installed SDK marks OTP credential APIs as available from iOS 18. This is a credential-manager integration, not a direct pairing-code injection API. Apple's documentation does not establish that the system Developer Mode pairing prompt requests those credentials. Adding an extension, entitlements and credential sharing cannot be justified as a working fix for this Settings prompt, so none were added. [Apple: providing OTPs](https://developer.apple.com/documentation/authenticationservices/providing-one-time-passcodes-to-autofill), [Apple: credential provider integration](https://developer.apple.com/documentation/authenticationservices/ascredentialproviderviewcontroller).
4. No documented public mechanism was found that makes an arbitrary local notification populate QuickType, or passes this PIN directly into the system pairing prompt. This is a conclusion from the reviewed API surface, not a claim that all iOS keyboards/pairing fields behave identically. A digits-only notification improves readability; it does not enable AutoFill. [Apple: local notification content](https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent).
5. Supported alternative: read the notification and type the digits. The explicit Copy button also allows user-controlled paste where the receiving field supports it; paste support in Apple's pairing prompt is unverified and is not promised. The dedicated copy stays on this device and expires after two minutes, avoiding Universal Clipboard transfer. The existing native text-selection menu remains an alternative explicit action. [Apple: UIPasteboard user intent, local-only items and expiration](https://developer.apple.com/documentation/uikit/uipasteboard).

No private keyboard APIs, accessibility automation, custom keyboard, input injection, background clipboard polling or system-prompt hooks were introduced.

## Settings navigation findings

| Destination | Public support and decision |
| --- | --- |
| Zag Store's own Settings page | `UIApplication.openSettingsURLString` (iOS 8+) opens Settings to this app's custom settings, not Developer Mode. Useful for permissions, but misleading as a pairing destination; not added here. |
| Settings app root | The public app-settings constant launches Settings to the app's page. No documented arbitrary root-navigation API was found. No private root URL is used. |
| App notification settings / global Default Apps | Separate public constants exist (iOS 15.4+ / 18.3+ in the installed SDK). Neither opens pairing. |
| Privacy & Security → Developer Mode | Apple documents manual navigation. No public direct URL/API was found. |
| Pair with Zag Store | No documented public deep link or direct PIN-submission API was found. Keep the existing manual pairing workflow and exact requested footer. |

Sources: [Apple: openSettingsURLString](https://developer.apple.com/documentation/uikit/uiapplication/opensettingsurlstring), [Apple: UIApplication supported Settings destinations](https://developer.apple.com/documentation/uikit/uiapplication), [Apple: Developer Mode manual navigation](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

The local iPhoneOS SDK is **26.5**. Its public headers and current Apple documentation were inspected. Apple's [iOS/iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) were also checked; no new documented pairing/Developer Mode jump or local-notification OTP injection mechanism was identified. This is not device testing on iOS 26 or 27. Availability and precise system pairing/paste UI must be checked on the target OS; user-reported working pairing is preserved. Undocumented `App-prefs:` / `prefs:` paths are not used, regardless of reports that a route opens somewhere on a particular release.

## Validation

- **Passed:** 28 real notification-content checks (title, digits-only body/leading zeroes, no metadata/instructions, sound/category, time-sensitive level, malformed inputs), plus native callback/delivery/completion wiring checks.
- **Passed:** pairing interface assertions: both paired/unpaired actions precede the file row; one action and one file row; same four sections; exact footer; native actions and trailing indicators; explicit local-only expiring copy; no unsupported Settings shortcut.
- **Passed:** 45 onboarding/coordinator/event-bridge checks and app integration assertions. Welcome and cold-launch verification files unchanged.
- **Passed:** self-update recovery and deep-link suites (59 route cases plus configuration checks).
- **Passed:** final device-link suite includes real install-job, pause/resume, mobile-data and control-state regressions. Initial behavioral runs passed, but the historical whole-core equality guard (against `cdc94c31`) correctly noticed the requested notification presentation change. The guard now excludes only construction of the PIN notification content/automatic clipboard write; all source outside that presentation block, including state publication, request submission, completion lifecycle and every installation/verification method, must still match the historical baseline byte for byte. No installer protection was removed. The notification suite separately verifies the changed presentation block.
- **Passed:** targeted arm64/iOS 16.4 SDK type-check with the real Installation/RPPairing interface prefix, new vector icon and notification helper; unrelated native manager, Nimble list wrapper and diagnostics destinations stubbed. Full Swift syntax and whitespace checks passed.
- **Blocked:** CoreSimulator eligibility probe exceeded a 15-second limit. No simulator repair, installation, signing or UI-test build attempted. Real-tap installation UI tests remain unexecuted. The previously established full Xcode pre-compilation environment failure was not retried for this UI-only task.
- Byte comparison confirms splash/welcome, launch gate, original icons, other Settings sections, URL entry point, updater and project/version/build settings are unchanged. In the native pairing core, only the intended PIN notification/clipboard block differs from the starting baseline.

Logs: `/tmp/zag-pairing-notification.log`, `/tmp/zag-pairing-interface-*.log` and `/tmp/zag-installation-typecheck.log`.

Device-only acceptance remains: paired/unpaired row geometry and separators, both themes and custom tint, small-screen footer wrapping, VoiceOver and large text, six-digit notification with foreground/background/locked-device/permission/Focus settings, completion removal, explicit copy expiration/local-only behavior and whether the Settings pairing field offers Paste. No native AutoFill or direct Developer Mode navigation is claimed.
