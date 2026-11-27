# Direct website installation with a Personal Team

Direct installation from zagstore.app is the primary research direction. Phase 1 isolates one question: will stock iOS install and launch a correctly Personal Team-signed copy of Zag Store from Safari using the private preview OTA manifest?

Apple documents HTTPS manifests and `itms-services` for supported distribution workflows. That documentation does not establish support for Personal Team development signatures. [Apple deployment guide](https://support.apple.com/guide/deployment/distribute-proprietary-in-house-apps-depce7cefc4d/web)

The experiment uses an existing Zag Store installation as a signing fixture. The target phone uses Safari for installation. This isolates the OTA transport and does not demonstrate a clean-phone signing bootstrap.

## Publication boundary

The checked-in website mirror's `byoc_private_delivery_worker.py` accepts only a job ID from the designated Unix socket peer. Its root-only `byoc_private_byoc_delivery.py` structurally inspects an already-signed IPA, derives the bundle ID and build from its Info.plist, and issues separate expiring HMAC tokens for the manifest and IPA. The preview plugin uses the manifest token for its Safari install page. That publisher explicitly leaves device validation open.

The checked-in publisher and worker do not invoke a distribution-purpose classifier. Other lanes can have different admission policies. Confirm the actual deployed publisher, credential validator, certificate purpose policy, manifest/token modules and preview reader before enabling an experiment. This checkout could not reach the live host for that comparison. If the deployed preview lane requires Distribution signing, stop and obtain approval for a separate private staging policy. Do not route this test through production signing, disable a gate, change deployed configuration, or transfer Apple credentials. A successful cryptographic preflight is only evidence for the submitted IPA.

## Phase 1 acceptance

### 1. Sign and export

1. On the already paired signing iPhone, choose a signed-in free Apple ID with a Personal Team. The pairing target must be the phone whose UDID will be in the profiles.
2. Import the official unsigned Beta 3 IPA with bundle identifier `app.zagstore.ios`. In Signing Options disable **Install After Signing** and sign with **Apple ID**. Use the production signing flow.
3. In Apps, open the pending signed row's context menu and choose **Export IPA**. Save to Files or AirDrop to the private staging operator. The row should still say **Install**. Do not tap it.
4. The signed artifact must have bundle ID `app.zagstore.ios.<TEAM>`, with the actual Personal Team ID. For the inspected Beta 3 artifact this is `app.zagstore.ios.FTB8PRW638`, version `1.0.0`, build `3`. The installed AppTesters app uses `com.cwd43.gu29` and is explicitly refused. Record the exact iOS version, the signed build, and whether Developer Mode was already enabled.

### 2. Verify the exported bytes on the operator's Mac

Run from this repository. `APPLE_ROOT` is a PEM copy of the classic Apple Root CA from [Apple PKI](https://www.apple.com/certificateauthority/). The tool checks its fingerprint. The operator needs macOS `codesign`, OpenSSL and Python 3. The operator Mac verifies the artifact and transfers it. It is not used to install the IPA onto the target.

```sh
umask 077
IPA="$HOME/Downloads/ZagStore-Signed.ipa"
TEAM='REPLACE_WITH_PERSONAL_TEAM_ID'
UDID='REPLACE_WITH_TARGET_DEVICE_UDID'
APPLE_ROOT="$HOME/Downloads/AppleRootCA.pem"
REPORT="$(mktemp -t zag-personal-ota)"
python3 scripts/zag-personal-ota.py validate --ipa "$IPA" --team "$TEAM" --udid "$UDID" \
  --apple-root "$APPLE_ROOT" > "$REPORT"
SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$REPORT")"
EXPIRES="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["effective_expiration"])' "$REPORT")"
test "${#SHA}" -eq 64
```

Stop if validation fails. External verification failures report the stage, bundle-relative component, exit status and recognised stderr text. The validator uses the same signed XML entitlement invocation as the manual Mac check. It checks the signed bundle identity, codesign verification and Apple Development certificate purpose, the authenticated profile for every app and extension, the actual signer, target device membership, granted entitlements and the earliest expiration. Development credentials alone do not prove free membership. Confirm the team was a Personal Team in the signing app. The report contains a digest, build, expiry and mapped identifier, with no Apple ID credentials or UDID.

### 3. Publish one verified IPA to the private preview lane

Run only after the staging operator confirms the live private preview delivery configuration and approves the artifact. The following paths reflect the checked-in worker configuration. The publisher requires root to use the existing private delivery secret and hands off files under the existing web reader's UID. Use a dedicated private SSH account and keep the signed IPA confidential, since its profile contains device identifiers. Run with failure propagation enabled and do not continue after a failed command.

```sh
HOST=zagstore
REMOTE="$(ssh "$HOST" 'umask 077; mktemp -d /tmp/zag-ota-operator.XXXXXX')"
scp "$IPA" "$HOST:$REMOTE/ZagStore-Signed.ipa"
scp scripts/zag-personal-ota.py "$HOST:$REMOTE/zag-personal-ota.py"
ssh -t "$HOST" "sudo python3 '$REMOTE/zag-personal-ota.py' publish \
  --ipa '$REMOTE/ZagStore-Signed.ipa' --team '$TEAM' --sha256 '$SHA' --effective-expiration '$EXPIRES' \
  --services /opt/zagstore/signing-engine/services \
  --delivery /var/www/zagstore-preview/zag-ota-jobs \
  --secret-file /opt/zagstore/signing-engine/private-secrets/ota-secret \
  --uid \$(id -u www-data) --gid \$(id -g www-data)"
```

Keep the printed job ID and open its `safari_url` privately within ten minutes. The script verifies the transferred digest before invoking the existing publisher. It checks that the publisher emits the expected preview URL, exact identifier and build. It does not start a signing job or deploy a service.

### 4. Record the device result

1. Open the returned HTTPS Safari page, tap the install link and accept the iOS confirmation. **Installation passes** only if the separate app finishes installing and the original app remains installed.
2. Open the new app. **Launch passes** only when it reaches the expected interface. Record Developer Mode or trust prompts separately. Follow normal iOS instructions for the authorised test device.
3. Pairing and profile-only self-renewal are later gates. A launch or pairing failure must not be collapsed into an OTA download failure.
4. If iOS rejects it, record the exact alert, iOS version, time, install stage, and whether the web page, manifest and IPA each returned success. In a private device log or sysdiagnose, correlate the timestamp with `installd` or `MIInstallerErrorDomain` and capture the domain/code. Remove bearer URLs, device identifiers and account information before sharing diagnostics. Keep the signed IPA digest with the test record.

### 5. Remove the artifacts

```sh
JOB='REPLACE_WITH_PUBLISHED_JOB_ID'
ssh -t "$HOST" "sudo python3 '$REMOTE/zag-personal-ota.py' cleanup --job '$JOB' --sha256 '$SHA' --team '$TEAM'"
ssh "$HOST" "rm -f -- '$REMOTE/ZagStore-Signed.ipa' '$REMOTE/zag-personal-ota.py' && rmdir -- '$REMOTE'"
rm -f -- "$REPORT"
```

The delivery cleanup validates the job, SHA-256 and exact mapped app identifier for the supplied team before removing its private files. Delete the local exported copy according to the experiment's retention policy. Remove the test app manually if desired, preserving the original.

## Interpreting a Mac trust failure

`CSSMERR_TP_NOT_TRUSTED` from full `codesign` verification stops this workflow. As a separate diagnostic, an operator may verify the exported leaf and intermediate using the pinned Apple Root CA supplied explicitly per invocation:

```sh
security verify-cert -L -N -p codeSign -c "$LEAF_DER" -c "$WWDR_INTERMEDIATE_DER" -r "$APPLE_ROOT"
```

This checks certificate trust without changing the Mac trust store. A passing result does not establish that the application, framework or entitlement encoding passes platform verification. In particular, if `codesign` reports an invalid entitlement blob or returns empty signed XML, stop and compare the XML and DER signing slots against the authenticated provisioning profile. Link publication still requires full artifact verification, a target UDID confirmed independently of the exported profile, and a review of the live preview policy.

## Beyond Phase 1

A clean-phone flow needs a supported browser or system authentication handoff, explicit consent for device registration and a reliable device identity channel, account-scoped provisioning and signing that keep credentials and private keys out of the web service, a safe signing-identity handover to the installed app, and computer-free pairing on stock iOS. Prove the launch and handover independently of the Safari result. Browser-based authentication and provisioning need separate design and validation. A public Apple credential endpoint and a desktop companion are outside this plan.

## Physical result and policy evidence

Two attempts on the reported iPhone 15 Pro Max and iOS 27.2.1 created a Home Screen placeholder and ended with an installation failure. The server observed successful Safari HTML and appstored manifest requests and complete 61,050,761-byte IPA responses. The locally exported file matches the recorded SHA-256. The operator's normal Terminal verified the development signature, authenticated profiles, entitlements and target-device eligibility. The captured device logs contain no installer rejection code. An HTTP 200 and a matching server byte count establish delivery from the server's side. iOS package admission and launch are separate observations.

Apple describes Personal Team provisioning as personal device testing and distinguishes it from program distribution. An Apple developer support engineer left OTA as a possibility without confirming it. Apple documents registered-device IPA installation via Device Hub and Configurator and separately documents ad hoc distribution. The enterprise OTA document describes a signed in-house IPA, TLS, an XML manifest and `itms-services`. Those flows use different policies. The libimobiledevice installation proxy sends an explicit install operation over a device service and cannot establish browser OTA compatibility. No reproducible modern Personal Team Safari success was found in these sources. [Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account/) · [Apple forum](https://developer.apple.com/forums/thread/749011) · [Registered-device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices) · [Enterprise OTA](https://support.apple.com/guide/deployment/distribute-proprietary-in-house-apps-depce7cefc4d/web) · [Installation proxy source](https://github.com/libimobiledevice/libimobiledevice/blob/master/include/libimobiledevice/installation_proxy.h)

The source mirror generates a single `software-package` asset and `software` metadata with the signed identifier and build. The PHP reader binds the job, digest, token scope and expiry, streams IPA as `application/octet-stream` and manifest as `application/xml`, declares file length and sets private/no-store. The checked reader does not implement byte ranges and the install HTML links to `itms-services` without a server-side redirect. This does not confirm what the live Nginx layer adds, including encoding, redirects or range handling. For a fresh job, privately inspect HEAD and GET status, Content-Type, Content-Length, Content-Encoding and forwarding behavior for both assets. Fetch the manifest and IPA once without following redirects and compare the received IPA digest to the validated report. Check whether any range requests or retries arrive after token expiry. Do not paste URLs or raw access logs into reports. Full delivery with the matching digest narrows the failure to device-side processing or policy without identifying which rule rejected it.

## Controlled probe and device diagnostics

1. Establish an available free-development slot before retrying. Inspect installed apps and free provisioning evidence, including apps installed with other tools. An incomplete inventory gives a lower bound. If availability remains uncertain, use a spare consented phone with independently confirmed free capacity. Leave existing installations intact. Record Developer Mode and the exact iOS version.
2. Build the reference probe with `bash scripts/ota-probe/build.sh "$HOME/Downloads/Zag-OTA-Probe.ipa"`. This builds a small arm64 iPhone app, linked only against system frameworks, with one launch screen and no requested entitlements. Its local ad hoc signature is for packaging. Sign this **probe** with the same Personal Team and certificate through the existing sign-only fixture. Export it without tapping Install. It must map to `app.zagstore.ota-probe.<TEAM>`.
3. Use the validation and publication commands above with `--probe` on both commands and the signed probe path in `IPA`. Use Homebrew OpenSSL 3 at the front of PATH (`export PATH="$(brew --prefix openssl@3)/bin:$PATH"`). Confirm the same leaf certificate locally and confirm the target through CoreDevice separately. The default allowlist stays exact for Zag Store. Probe mode accepts only its distinct mapped identifier and fixed build. Use `--probe` for probe cleanup as well.
4. Tap Install from the private Safari page once. Note the local time and time zone. Record Home Screen completion and whether the app displays **OTA probe launched**. If it fails, immediately capture an iOS sysdiagnose following [Apple's Profiles and Logs instructions](https://developer.apple.com/feedback-assistant/profiles-and-logs/). Export the archive privately from the phone, extract it, and locate its `system_logs.logarchive`. On a Mac use a window from one minute before tapping to one minute after the alert.

   ```sh
   python3 scripts/zag-ota-diagnostics.py /path/to/system_logs.logarchive \
     --start 'YYYY-MM-DD HH:MM:SS' --end 'YYYY-MM-DD HH:MM:SS' \
     --bundle "app.zagstore.ota-probe.$TEAM"
   ```

   The script emits allowlisted installer error domains and codes. Same-window codes may describe a different installation. Only an event containing the exact test bundle is marked bundle-linked. An empty report means these signatures were absent from the selected captured events. Keep the archive private. Use Feedback Assistant if it still lacks the underlying error. CoreDevice app inventory is useful for confirmed completion. Installation Proxy status codes apply to its own installs. Neither substitutes for Safari's archived logs.
5. If necessary, run a separate control through the same preview publisher with a distinct test bundle and valid ad hoc distribution profile for this device, approved and verified under the existing distribution policy. Keep it out of the Personal Team validator. A passing control verifies the lane for that policy. If the probe and control both fail, investigate shared delivery or device configuration. If the probe launches, investigate Zag Store-specific packaging or metadata. If only the probe fails and a correlated platform error identifies a development-profile restriction, record the exact error and tested iOS scope. A failed probe with no code does not establish a universal restriction.

For records from the prior experiment, run `expired-jobs --sha256 "$SHA" --team "$TEAM" --start "$START" --end "$END"` via `ssh zagstore` using the updated script copied into the private operator directory. Supply timezone-qualified timestamps bracketing publication. Match the first known job and identify the second only by an unambiguous match with the operator's publication time and access records. Run the existing exact `cleanup` command only for the independently identified jobs. If records are absent, leave other records untouched. If several candidates remain, retain them until attribution is clear. Remove only the operator files from this experiment after the probe or control work is done.

Apple's separately authorized, notarized EU Web Distribution can meet a direct website experience for eligible publishers and devices without requiring the visitor to buy a certificate. It has publisher and jurisdiction requirements and does not use the visitor's free signing identity. TestFlight can be linked from a website and has publisher membership and TestFlight requirements. A web app can be installed from Safari without signing but cannot deliver Zag Store's native signing and pairing features. None is a verified replacement for the full free Apple ID objective. [Web Distribution](https://developer.apple.com/support/web-distribution-eu/) · [Apple beta distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)

## Failed minimal probe follow-up

On iPhone 15 Pro Max with reported iOS 27.2.1 and Developer Mode enabled, the independently validated Personal Team probe failed with the same generic Safari alert. Its signed IPA is 25,404 bytes. This removes most Zag Store-specific factors from the test. A free slot and a matching installer rejection still need evidence. Do not repeat the test just to obtain streaming logs.

Connect and unlock the already paired phone. Run this one command in normal macOS Terminal from the repository root, replacing the device name and the local-time window with the actual attempt time. The collector checks the installed Xcode command's options, requests device-only sysdiagnose, collects read-only app inventory, extracts only the system log archive and prints a sanitized report. Use Python 3.12 or newer. If the incident has aged out of the device's retained logs, an already captured archive can be supplied with `--archive`.

```sh
python3 scripts/zag-ota-collect.py --device 'PAIRED IPHONE NAME' \
  --start 'YYYY-MM-DD HH:MM:SS' --end 'YYYY-MM-DD HH:MM:SS'
```

Share only `shareable-codes.json`. Keep the raw archive, `apps.json` and command logs private. The CoreDevice roster can identify inventoried installed apps and may include useful signing metadata. Developer-signed, a team ID or a debug entitlement alone cannot distinguish free versus paid development. A profile resident on the device can outlive an install. For capacity proof, match authenticated free-profile evidence to installed bundle IDs and signers, exclude placeholders and paid variants, and record whether every candidate was classifiable. Three reliably matched apps are evidence of saturation under the standard limit. Fewer matches in an incomplete inventory leave availability unknown. A bundle-linked free-profile tracker event or maximum-count error is stronger evidence of actual enforcement.

From normal Terminal, inspect the probe delivery and immediately invalidate its disclosed token by deleting only the digest- and team-bound job. The first command filters the preview Nginx records to method, asset, status and bytes. Use the actual preview access log path if it differs, and include its rotated file if necessary. An empty report means no matching standard combined-log record was read. A complete response means the server accounted for the expected body length.

```sh
JOB=c1a7d19524af4bd0e050024732db59d6
SHA=f8e5e1c77465b0906d0e3ff881e4e25902fcaabb6a0caebaa21a52b9b83e57d3
TEAM=FTB8PRW638
ssh zagstore 'sudo -n cat /var/log/nginx/preview.zagstore.app.access.log' |
  python3 scripts/zag-ota-delivery-audit.py --job "$JOB" --ipa-size 25404
ssh -t zagstore "sudo python3 /tmp/zag-ota-probe.VOMqkn/zag-personal-ota.py cleanup \
  --probe --job '$JOB' --sha256 '$SHA' --team '$TEAM'"
```

The audit pipeline handles private log records locally and prints no raw records. If sudo requires a password, use the Mac's normal private SSH session to run the audit on the server, with a copy of the audit script. Cleanup can proceed even if audit log access fails because it leaves Nginx logs intact. After cleanup, inspect only the exact private operator directory and remove its known probe files when no longer needed. The prior Zag Store attempts still require the runbook's exact expired-record matching step.

If iOS explicitly rejects Personal Team OTA, no examined supported system route consumes a visitor's Personal Team IPA directly from Safari. Managed installation requires enrollment and Apple documents App Store and enterprise packages for managed iOS distribution. Developer device installation uses a paired developer host. App Store links and eligible notarized Web Distribution can start from a website without visitor-side signing, with publisher eligibility and platform requirements. Enterprise OTA is for authorized in-house distribution. [Apple device management](https://developer.apple.com/documentation/devicemanagement/installing-managing-updating-and-removing-apps) · [Registered-device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices) · [Web Distribution](https://developer.apple.com/support/web-distribution-eu/)
