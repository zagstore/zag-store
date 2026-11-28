# ZagAnisetteValidate — Phase C on-device validation

A small harness that runs the **production** Phase C integration
(`ZagAppleAuthMachine`, `ZagOnDeviceAnisetteProvider`, `ZagAnisetteData`) on a
stock iPhone and derives fresh anisette headers from the profile the one
authorised provisioning experiment produced. It makes **no network request**.

It is not part of the app; it exists to prove the integration links and runs on
device. Build it against `AppleAuthCore/apple-auth/ZagAppleAuth.xcframework`
together with the three integration sources and a two-symbol stub for
`ZagDeadline` / `ZagTransportError` (as `scripts/test-zag-on-device-anisette.sh`
does for the host), target `arm64-apple-ios`, then sign it into an app bundle
whose id matches the container that already holds `Documents/zag-adi` and
install over that app so the data container is preserved.

Output (`ZAGVALIDATE …`, also written to `Documents/zag_anisette_validate.json`)
is sanitized: header *names* and counts only, never a provisioning value.
Expected `result: "ok"`, `network_requests: []`.
