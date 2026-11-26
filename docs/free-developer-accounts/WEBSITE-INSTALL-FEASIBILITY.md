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

Stop if validation fails. It checks the signed bundle identity, codesign verification and Apple Development certificate purpose, the authenticated profile for every app and extension, the actual signer, target device membership, granted entitlements and the earliest expiration. Development credentials alone do not prove free membership. Confirm the team was a Personal Team in the signing app. The report contains a digest, build, expiry and mapped identifier, with no Apple ID credentials or UDID.

### 3. Publish one verified IPA to the private preview lane

Run only after the staging operator confirms the live private preview delivery configuration and approves the artifact. The following paths reflect the checked-in worker configuration. The publisher requires root to use the existing private delivery secret and hands off files under the existing web reader's UID. Use a dedicated private SSH account and keep the signed IPA confidential, since its profile contains device identifiers. Run with failure propagation enabled and do not continue after a failed command.

```sh
HOST=zagstore-prod-01
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
