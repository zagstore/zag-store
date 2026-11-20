# Signing keys: threat model and chosen approach

## Assets

- The RSA 2048 private key of each account and team's development certificate.
- Whoever holds it can sign apps that iOS will run on that team's registered devices, until the certificate expires or is revoked.

## Where the key lives today (pinned Zsign `ab57916`)

| Stage | Protection |
|---|---|
| Creation | Made by the Security framework, in memory (`kSecAttrIsPermanent: false`). Only the CSR (the public key) leaves the device. |
| At rest | Inside `ZagSigningIdentity`, as one Keychain item per account and team: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synchronised, never in backups that restore elsewhere. |
| During signing | The pinned Zsign reads keys only from a file. The adapter writes it with mode `0600` inside a `0700` folder with data protection `completeUnlessOpen`, under the app's private temporary directory. Afterwards it overwrites and deletes the file, whether signing succeeded or failed. |
| Logs | None of the key, provisioner, adapter or directory code logs. Source checks forbid `print`, `NSLog`, `Logger`, `os_log` and `dump` there. Identities describe themselves as `[signing identity <serial>]`. Diagnostics hold no key, token or device ID. |
| Crash reports and analytics | No key material reaches either. Analytics never receives free-account data. |

## Limits of deleting a file

Overwriting and deleting does **not** guarantee the bytes are gone from flash:
- APFS is copy-on-write, so the overwrite may land in new blocks;
- the SSD wear-levels;
- snapshots may hold old blocks.

What protects the key in practice is iOS's per-file encryption. The file's key is wrapped by the data-protection class key and discarded with the file, so leftover blocks are ciphertext whose key is gone. The real exposure is narrower: while the file exists (well under a second), a process that can read this app's container could copy it. On a non-jailbroken device that is only this app.

## Chosen approach: no export (Zsign branch, pending approval)

The Zsign feature branch (`zag-free-account-signing`, draft PR zagorskey/Zsign-Zag#1) adds two ways to sign without a key file:

1. **Raw signer callback (preferred).**
   - Zsign builds the CMS signature with a key object that contains only the certificate's public key. Its private operation calls back into Swift with the PKCS #1 DigestInfo.
   - Swift signs it with `SecKeyCreateSignature(.rsaSignatureDigestPKCS1v15Raw)` using a Keychain key reference.
   - The private key never enters Zsign or OpenSSL.
   - Tested with a Security framework key: the signatures verify, a refusing or malformed signer fails, and a wrong key is caught by the output check.
2. **Key from memory.** Key data passed as bytes and wiped from Zsign's copy afterwards. No file.

**Implemented (not yet used by the production path):** `ZagKeychainSigningKeys` creates one Keychain key item per account and team, makes the certificate request from the key reference, and signs through Zsign's callback. This is tested on the simulator's real Keychain, and with the Zsign branch in `scripts/test-zag-zsign-branch.sh`.

**Platform finding.** iOS does not enforce `kSecAttrIsExtractable: false` for software RSA keys: the owning app can still export one (checked on the simulator). "No export" therefore means Zag Store's code never exports the private key, which is enforced by a source check. It does not mean export is impossible.

To get full benefit, the key should also be stored as a **Keychain key item** (`kSecClassKey`, this-device-only) rather than as bytes inside `ZagSigningIdentity`. Then the app only ever holds a reference. RSA keys cannot live in the Secure Enclave, and iOS performs software-key operations within the app's process, so this removes export rather than making the key hardware-bound.

That migration, and switching the adapter to `Zsign.signComponents`, waits for the Zsign branch to be approved and the submodule pointer to be updated.

## Ownership

- Each account and team has its own identity item.
- Sign-out keeps identities so refreshes can resume.
- Removing an account deletes every item of that account.
- Certificates are never revoked automatically.

## Keychain-backed signing for the supervised experiment (19 Nov 2026)

These changes make the Keychain key item the only signing path for free accounts.

**Key creation.** `ZagKeychainSigningKeyFactory` makes each account and team's key as a Keychain key item, available after first unlock, on this device only and never synchronised.
- The certificate request is made from the key reference.
- The issued certificate is checked by possession: a fresh challenge signed with the key must verify with the certificate's public key.
- The stored `ZagSigningIdentity` carries no key bytes (`keyIsInKeychain`).

**Signing.** `ZagFreeAccountSigningAdapter` signs a Keychain-held identity only through the key reference (`signWithKeychainKey` → Zsign's raw-signer callback).
- No key file, staging folder or exported key is involved.
- A missing key item fails with `keychainKeyMissing`; it never falls back to a key file.
- Another account's authorisation is refused.

**The older key-file path is refused** unless `allowsKeyFiles` is set, which only its own tests do.

**Production.** Keychain signing is compiled only with `ZAG_ZSIGN_STRICT`, which no Xcode configuration sets. Without it, a Keychain-held identity fails with `keychainSigningUnavailable`. The free-account signing gate stays closed. The path is enabled only in the separately approved experiment build, after the live workflow review.

**Tests.**
- `scripts/test-zag-zsign-branch.sh` covers the end-to-end path: provisioning with a Keychain key, signing, independent verification, no key file, cross-account refusal and a missing key.
- `scripts/test-zag-free-account-signing.sh` covers the key policy in a build without the flag.

## Signing-key lifecycle review (19 Nov 2026; L1 and L2 implemented the same day)

**Where things are kept**
- **Keys.** Each key is a Keychain key item, labelled `<namespace>.signing-key.<account ID>`. Its tag is `<label>.<team>.<slot>`; each new key gets a new slot.
- **Identity.** The matching identity holds the certificate and the slot of its key, with no key bytes. It is in the account's generic-password items.
- **Ownership record.** This is also among the account's generic-password items. It holds the hashed Apple Account key and the masked address, nothing secret.

Keys are never retagged. The macOS file keychain reports success for a tag update without applying it, so "swapping" a key by renaming it is not relied on.

| Event | What happens to the key and identity | Evidence |
|---|---|---|
| **Switching accounts** | Nothing moves. Signing needs a `ZagSigningAuthorization` for exactly one account and team. The adapter loads only the key in the slot that account and team's identity names. | Strict integration: "another account's authorisation cannot sign this account's app" |
| **Sign-out** | The session is removed. The key, identity and ownership record stay (owner decision, 18 Nov). They cannot be used, because signing needs a signed-in authorisation. | `test-zag-apple-accounts.sh`, `test-zag-free-account-signing.sh` |
| **Account removal** (confirmed) | Every key item of the account (every team and slot, pending ones included) is removed first, then every generic-password item (the ownership record among them), the summary and the record. The key removal repeats until no match is left, because the macOS file keychain removes one match per call. If the Keychain refuses, the account stays registered and the removal can be repeated. | Strict integration: "removing the account removes…"; accounts suite; simulator Keychain harness |
| **Missing key reference** (Keychain reset, restore, deleted item) | Before reuse, the stored identity is checked against its slot's key by proof of possession. If the key is missing or does not match, a new key and certificate are made. Signing with such an identity fails with `keychainKeyMissing`, never by falling back to a key file. | Strict integration: "an identity whose key is missing is not reused…" |
| **New certificate (L2)** | See "L2: transactional identity creation" below. The identity in use, even one about to expire, keeps working until a new one is stored. | Strict integration: ten "L2:" checks |
| **App deleted and reinstalled (L1)** | See "L1: recovery and cleanup after a reinstall" below. Nothing is deleted automatically. | Accounts suite: eleven reinstall and orphan checks; simulator Keychain harness |
| **Device restore or migration** | Every item is `…ThisDeviceOnly` and not synchronised, so nothing moves to another device. The provisioner makes new keys there. | Item attributes (`ZagKeychainSigningKeys.create`, `ZagKeychainFreeAccountSecretStore.save`) |

### L2: transactional identity creation (owner decision, 19 Nov: approved)

1. **New key.** A new key is made in a new slot, beside the key in use. A journal (`ZagPendingSigningKey`) records:
   - the certificate request and the key's slot;
   - when the request started, and how many attempts it has had.
2. **Request.** The request is sent. If it fails (network, no response, rate limit, certificate limit), nothing else changes, and the identity in use keeps working.
3. **Bounded retries.**
   - The next attempt resubmits **the same request with the same key**, up to 3 attempts within 24 hours.
   - After that, the request is abandoned and a new key is made.
   - A request is never retried for another account or team: the journal and the slot are per account and team.
4. **Verification.** The issued certificate must verify against the new key by proof of possession. If it does not, the request is abandoned: its key and journal are deleted, and nothing is published.
5. **Journal.** The verified certificate is written to the journal before anything else changes.
6. **Publication.** The identity is rewritten to name the new slot. This **single write** publishes the new identity. The journal is then cleared and the previous key deleted.
   - **Interrupted before the write:** the next attempt finishes the publication from the journal, after checking possession again, without requesting another certificate.
   - **Interrupted after the write:** the next attempt finds nothing left to do except remove the old key.
7. **Cleaning up abandoned keys.** A pending key is never published. It is deleted when:
   - its request is abandoned;
   - a new request starts (any key of that account and team that neither the identity in use nor a request in progress names);
   - the account is removed.

**Limitation (Apple's side).** If Apple issues a certificate but the response is lost, the app never receives that certificate. The retry asks for another. The unseen certificate counts against Apple's limit of 2 until it expires or is revoked. When the limit is reached, Zag Store asks the user to choose one to revoke. Recovering it would need the certificate's data in the portal listing; the bridge does not provide that today.

### L1: recovery and cleanup after a reinstall (owner decision, 19 Nov: approved)

**Background.**
- A reinstall clears the preferences (the account registry), but Keychain items can remain.
- Account IDs are random, so before this change a new sign-in got a new ID and the earlier items became unreachable.
- Keychain items surviving an app's deletion is behaviour, not a documented guarantee. Zag Store does not depend on it either way.

**Ownership record.**
- When Apple accepts a sign-in, the account ID is chosen and its ownership record is written **before** anything is stored under that ID.
- The record holds `SHA-256` of the account identifier Apple returned, plus, once the account is added, its masked address.

**Recovery.**
- After a reinstall, a sign-in that **Apple has accepted** for the same Apple Account finds its record and reuses that account ID.
- So only the owner of the Apple Account recovers its items. A different Apple Account always gets a new ID.
- Two records naming one Apple Account are ambiguous, so neither is used.
- Team ownership is not assumed: a recovered identity is reused only if its key passes proof of possession and the team's portal still lists its certificate. Otherwise a new one is made, as for a missing key.

**Cleanup is explicit, scoped and safe.**
- `orphanedItems()` lists the account IDs that own items in this app's own storage but belong to no registered account and no sign-in in progress.
  - It looks only at this app's own items: the secret store's own service, and this namespace's key labels.
  - It marks each as "recoverable by signing in" (has a record, with the masked address if known) or "unowned" (no record).
- Nothing is removed at launch.
- `removeOrphanedItems(_:)` removes exactly what the user confirmed, checking each item again immediately before deleting it:
  - An account is removed only if it is still orphaned **and** its ownership is unchanged since the confirmation (still recoverable or not, same masked address). Otherwise it is reported as skipped and kept.
  - It removes key items first, then the account's local (anisette) state, then its secrets, the ownership record among them. An interrupted cleanup therefore leaves the record, and the next listing shows the account again.
  - The result reports removed, skipped and failed items separately. A failure is never hidden, and the cleanup can be repeated.
- Local anisette state that no account's record names is listed too (see "Account removal and local state" below).

**Enumeration used.** `SecItemCopyMatching` with `kSecMatchLimitAll` and `kSecReturnAttributes`, through the documented API only, over:
- the generic-password items of Zag Store's own service;
- the private-key items of the app's own access group, keeping only labels in Zag Store's namespace.

It does not assume what other apps can see, or that items survive deletion.

**UI.** Settings → Apple Accounts → **Stored Account Data** (owner decision, 20 Nov: in Release, behind the Apple Accounts feature; see "Release gating" below):
- It lists items in three groups: "Recoverable" (with the masked address), "Not Recoverable" and "Anisette State".
- It removes one item, or all listed, only after a confirmation dialog. Removing a recoverable account warns that its keys cannot then be recovered by signing in.
- It reports skipped and failed items, and never runs by itself.
- It is production code (`ZagStoredAccountDataView`, `ZagStoredAccountDataModel`). Debug builds reach it from the simulated Apple Accounts screen.
- It works for signed-out and expired accounts too. Orphan cleanup needs no session; a registered account (signed in or not) is never listed as orphaned. Removing a signed-out or expired account is local and removes its keys and anisette state.
- The simulator walkthrough covers it: step 10 and 2 of its in-app checks.

### Certificate request recovery (20 Nov)

A certificate request can be granted by Apple while its response is lost (network failure, timeout, app stopped). The certificate then exists, counts against the team's limit, and nobody holds a record of it. Retrying blindly would consume further slots.

**Write-ahead marker.**
- Before each certificate request is sent, the pending-key journal is marked `submissionUnconfirmed`.
- The mark is cleared only when Apple has definitely not issued a certificate: it refused with the certificate limit, a rate limit or a rejected session.
- A crash while the request is out leaves the mark set.

**Preflight inventory.** When the journal is marked, the next provisioning attempt checks the team's certificate listing (already fetched for reuse) before requesting anything:
- **Issued.** A listed certificate's public key belongs to the pending key (proof of possession, as for any issued certificate). It is adopted, published through the same journal path, and nothing is requested.
- **Not issued.** Every listed certificate includes its data and none belongs to the pending key. The same request is sent once more (bounded by the existing three attempts).
- **Unknown.** Otherwise: the listing omits certificate data, the pending key is missing, or a match has expired. Provisioning stops with `certificateRequestUnresolved`.
  - Nothing more is requested, however often provisioning is retried.
  - Background refresh treats it as a signing failure and does not retry.
- **Continuing after "unknown": the recovery screen** (owner decision, 20 Nov). The team shows "Certificate Request Unresolved", which opens Settings → Apple Accounts → Certificate Request (`ZagCertificateRecoveryView`, `ZagCertificateRecoveryModel`). It offers two actions:
  - **Check Again** (`checkUnresolvedCertificateRequest`) reads the certificate listing only, never sends a request, and needs the account signed in.
    - It settles the request exactly as provisioning would: recovered (proof of possession), not issued (full listing), or still unresolved.
    - It changes nothing unless the request is still the one it checked.
    - It can be cancelled; signed out, network failure or cancellation is reported and changes nothing.
  - **Abandon Request** (`abandonUnresolvedCertificateRequest`) asks for confirmation first. The dialog warns that a certificate Apple may have issued keeps a slot until it expires or the user revokes it.
    - It discards only the pending key and journal, and works signed out because it is local.
    - The next signing makes one new request with a new key.
  - The result is always reported: recovered, resolved as not issued, still unresolved, abandoned, nothing pending, or could not check (with why).
  - Nothing is revoked, and nothing runs in the background. Background refresh maps the failure to "signing failed" and does not retry.

**Never revoked.** The portal interface has no revoke operation at all. An uncertain certificate stays in the team's listing until it expires or the user revokes it elsewhere.

**Portal data.** Whether Apple's live listing (`listAllDevelopmentCerts`) fills each certificate's content is not established.
- The bridge passes it when present (#29).
- If it is absent, every lost response ends as "unknown", which is the safe outcome.

**Evidence.** 7 strict integration checks ("recovery: …"):
- a lost response is marked;
- with listing data, the certificate is found and used with no new request;
- without listing data, three retries make no request, and the job stops;
- abandoning makes exactly one new request;
- a refusal is marked "not issued" and is resent;
- the mark is written before sending, and a full listing showing nothing issued resends once.

A further accounts check covers the refresh mapping.

### Release gating (20 Nov)

The two recovery screens and their models are compiled in Release (no `#if DEBUG`). Settings shows their entry only `if ZagAppleAccountsFeature.isEnabled`, which is `static let false` in this version. `test-zag-free-account-release-binary.sh` checks, on every Release scan:
- the gate is closed in the source;
- the two files are not Debug-only;
- every Settings reference to the screens is inside the gate.

The placement check was confirmed to refuse an ungated entry. The Debug-only simulation buttons ("Lose a Certificate Response", "Leave Items From an Earlier Installation") are scan markers that must be absent from Release.

### Account removal and local state (20 Nov)

**Ownership record.** It now also lists:
- the hashes of the addresses the account signed in with (`addressKeys`, SHA-256 of the trimmed, lower-cased address; the address itself is never stored);
- the scopes of local state kept for it outside its own items (`localStateScopes`).

For local state, the bridge's per-account anisette state is the only kind.

**Removal order.** Removing an account deletes:
1. its key items;
2. each recorded local state scope;
3. its secrets, the record among them.

**If a local state scope cannot be removed:**
- removal fails with `localStateNotRemoved`;
- the account stays registered with its record and its other secrets;
- removing it again finishes the job.

The local state store is a protocol (`ZagAccountLocalState`) configured on the directory; the bridge provides it in #29.

### Apple Account aliases (20 Nov)

**What the protocol offers.**
- The identifier Apple returns at sign-in (`adsid`) comes from the SPD, which is decrypted with the SRP session key after the server proof (M2) has been verified. So it is authenticated by Apple's sign-in.
- Whether every alias (a second email or phone number) of one Apple Account yields the same `adsid` has not been observed. Zag Store cannot contact Apple to test it.

**Rule (fail closed).**
- Each account records the hashes of the addresses it signed in with.
- A sign-in that Apple accepts for a known account through an address never recorded for it is refused with `addressNotRecognised`: nothing is stored, nothing is merged, and no second account is created.
- The user signs in with the address first used.
- Accounts recorded before this change accept their next address as the first one.

**Owner decision.** Reconciling aliases needs the identity semantics to be established first, for example in the supervised experiment.

### Exportability

As recorded above, iOS does not enforce `kSecAttrIsExtractable: false` for software RSA keys, and the Secure Enclave cannot hold the RSA-2048 keys Apple's development certificates need.

"Never exported" means Zag Store's release code never exports the key:
- It uses the key only through `SecKeyCreateSignature`.
- The test-only key factory that exports keys is compiled only in Debug, and the release scan checks it is absent.

It does not mean export is impossible.
