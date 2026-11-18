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

To get full benefit, the key should also be stored as a **Keychain key item** (`kSecClassKey`, this-device-only) rather than as bytes inside `ZagSigningIdentity`. Then the app only ever holds a reference. RSA keys cannot live in the Secure Enclave, and iOS performs software-key operations within the app's process, so this removes export rather than making the key hardware-bound.

That migration, and switching the adapter to `Zsign.signComponents`, waits for the Zsign branch to be approved and the submodule pointer to be updated.

## Ownership

- Each account and team has its own identity item.
- Sign-out keeps identities so refreshes can resume.
- Removing an account deletes every item of that account.
- Certificates are never revoked automatically.
