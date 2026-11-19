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

## Signing-key lifecycle review (19 Nov 2026)

Each key is a Keychain key item. It is tagged `<namespace>.signing-key.<account ID>.<team>` and labelled `<namespace>.signing-key.<account ID>`. The matching identity (the certificate, with no key bytes) is in the account's generic-password items.

| Event | What happens to the key and identity | Evidence |
|---|---|---|
| **Switching accounts** | Nothing moves. Signing needs a `ZagSigningAuthorization` for exactly one account and team. The adapter loads only that account and team's key item, so another account's authorisation cannot sign with this account's identity. | Strict integration: "another account's authorisation cannot sign this account's app" |
| **Sign-out** | The session is removed. The key and identity stay (owner decision, 18 Nov). They cannot be used, because signing needs a signed-in authorisation. | `test-zag-apple-accounts.sh`, `test-zag-free-account-signing.sh` |
| **Account removal** (confirmed) | **Changed today.** The key items are now removed first (`Configuration.signingKeys.deleteAll`), then every generic-password item, the summary and the record. If the Keychain refuses, nothing has been removed yet and the removal can be repeated. | Strict integration: "removing the account removes its signing key items and identities" |
| **Missing key reference** (Keychain reset, restore, deleted item) | **Changed today.** Before reuse, the provisioner checks the stored identity against its key by proof of possession. If the key is missing or does not match, the identity is not reused: a new key and certificate are made. Signing with such an identity fails with `keychainKeyMissing`, never by falling back to a key file. | Strict integration: "an identity whose key is missing is not reused…", "a missing key item fails clearly…" |
| **Unfinished certificate request** | `makeKey` replaces the key of that account and team before requesting. If the request then fails, the old identity's key is gone, so it is no longer reused (see above). | By design. See finding L2 below. |
| **App deleted and reinstalled** | iOS keeps Keychain items after an app is deleted, but the account registry (preferences) is lost. Account IDs are random UUIDs remembered in that registry, so a new sign-in gets a **new** account ID, and the old session, identities and key items are orphaned: unreachable but not removed. | **Open: finding L1** |
| **Device restore or migration** | Every item is `…ThisDeviceOnly` and not synchronised, so nothing moves to another device. The provisioner makes new keys there. | Item attributes (`ZagKeychainSigningKeys.create`, `ZagKeychainFreeAccountSecretStore.save`) |

**Open findings that need a decision**
- **L1: orphaned Keychain items after a reinstall.**
  - Option (a): on a fresh install (no registry in preferences), sweep the namespace's items that belong to no registered account. This deletes automatically, so it is guarded: it runs only when no registry data exists at all, never on decoding failure.
  - Option (b): derive account IDs deterministically from the Apple Account, so a reinstall reconnects to its items. Old sessions are then re-validated, and identities are re-checked by proof of possession.
  - Option (c): leave them, and document a manual "Reset free-account data" action.
- **L2: a failed certificate request discards a still-valid key.** The new key could be created under a temporary tag and swapped in only after the certificate is issued and checked. This is low impact: only identities that expire within 7 days, or are missing, take this path.
- **Exportability.** As recorded above, iOS does not enforce `kSecAttrIsExtractable: false` for software RSA keys. The Secure Enclave cannot hold the RSA-2048 keys Apple's development certificates need. "Never exported" means Zag Store's code never exports the key: it uses the key only through `SecKeyCreateSignature`, and no code path calls `SecKeyCopyExternalRepresentation` on a private key. It does not mean export is impossible.
