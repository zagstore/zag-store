# Installing Zag Store from zagstore.app with the visitor's own free Apple Account: feasibility

Status 18 November 2026: **assessment only.** Nothing has been tested against Apple's services. Where something is unconfirmed, it says so. No paid certificates are generated or supplied to users in any option.

## What Apple's restrictions mean here

- **Free (Personal Team) profiles:**
  - development profiles that expire **7 days** after issue;
  - at most **10 App IDs per 7 days**;
  - **3 apps per device**;
  - only devices registered to that team.

  Sources: Apple's membership comparison and developer-forum answers. The installed app stops launching when its profile expires.
- **Developer Mode** (iOS 16 and later) is required to run development-signed apps. Its switch appears in Settings only after the device has been connected to Xcode or a development-signed app has been installed or attempted.
- **Device identifier:** a development profile must list the device. A website can learn the identifier only through a configuration profile (a "Profile Service" payload) that the visitor installs from Safari in Settings.

## The four cases

| Case | Feasible? | Why |
|---|---|---|
| **1. Signing with a free Personal Team** | Technically yes, but **not on our website** | Signing needs the visitor's Apple Account sign-in (password and 2FA), a development certificate with its private key, device registration and a profile. Done on zagstore.app, our server would receive the visitor's password and 2FA code and would hold their signing key. That contradicts our rules against handling or persisting Apple credentials and keys for others. Apple's endpoints cannot be called from browser JavaScript directly (no cross-origin access), so everything would have to go through our server. |
| **2. Downloading a signed IPA** | Yes, but useless alone | Any IPA can be downloaded. Safari cannot install it; it only saves to Files. |
| **3. Installing that IPA from Safari** | **Unconfirmed; do not rely on it** | Safari installs apps only through an `itms-services` manifest over HTTPS. Apple supports this for ad hoc and enterprise distribution, and its tools can export development builds with a manifest. But for **free Personal Team** profiles, an Apple engineer says it "might" work and "is not what the Personal Team feature is intended for". We found no confirmation, and Developer Mode cannot be switched on before the first development app has been attempted. Even if it works, case 1's credential problem remains, as does a 7-day expiry with no way to re-sign from the website. |
| **4. Using a companion device or an existing pairing** | **Yes: the established route** | A computer that the visitor trusts can sign with their free account *on their own computer* and install over USB or Wi-Fi. This is how Xcode, AltStore, SideStore and iloader work, the last built on `isideload`. The same step can create the pairing file that Zag Store already uses for on-device installs and 7-day refreshes, so no computer is needed afterwards. |

## Recommended initial-installation mechanism

**1. A small open-source desktop companion** (macOS first, then Windows and Linux), downloadable from zagstore.app. It runs entirely on the visitor's own computer:
- sign-in, with credentials never leaving the computer except to Apple;
- Personal Team, certificate, device registration and profile;
- signing the Zag Store IPA, which is downloaded from our GitHub releases and verified against its published hash;
- installation over USB;
- creating the pairing file and handing it to Zag Store.

It can reuse the reviewed `zag-isideload` fork for the Apple side, and our RPPairing core or an equivalent for the device side. Our website only links to signed companion builds and documentation. It never sees an Apple credential.

**2. After that, Zag Store refreshes and installs on the device.** It uses its free-account support (this project) and the existing pairing. The computer is needed again only if the pairing is lost, for example after a device reset, or sometimes after an iOS update.

**3. Optional, after testing:** an experiment to settle case 3 with our own dedicated test account. Can a free-profile app be installed from an `itms-services` manifest on a device with Developer Mode already on? Even if it can, it would only help visitors who already have Developer Mode on and a way to sign, so it would not replace the companion.

**Not recommended:**
- server-side signing with visitors' credentials;
- WebUSB-based installation from the browser (unreliable: the operating system's own drivers claim the iPhone, and Safari has no WebUSB);
- any paid or shared certificate.

## Sources

- Apple, [membership comparison](https://developer.apple.com/support/compare-memberships/) (free limits: 7-day profiles, 10 App IDs, 3 apps)
- Apple Developer Forums: [personal team intent](https://developer.apple.com/forums/thread/749011), [app limits](https://developer.apple.com/forums/thread/724896)
- WWDC22 ["Get to know Developer Mode"](https://wwdcnotes.com/notes/wwdc22/110344); [Expo on Developer Mode](https://docs.expo.dev/guides/ios-developer-mode/)
- Apple, [Profile Service (OTA enrolment)](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/iPhoneOTAConfiguration/profile-service/profile-service.html)
- [iloader](https://github.com/nab138/iloader) (desktop installer built on isideload); [AltStore no-computer FAQ](https://faq.altstore.io/altstore-classic/no-computer-instructions.md) (pairing still requires an initial trusted host)
