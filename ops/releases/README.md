# Zag Store Unified Release Workflow

## Requirements

- Authenticated GitHub CLI
- SSH access through the zagstore alias
- Server sudo access
- Python environment at ~/.venvs/zagstore-release
- Installed server staging and activation utilities
- Trusted Ed25519 release public key

## Validate a published beta

bash ops/releases/zag-release-unified.sh beta --dry-run

## Deploy a published beta

bash ops/releases/zag-release-unified.sh beta

## Release process

1. Build and package the unsigned IPA.
2. Publish the IPA and checksum to GitHub.
3. Sign and publish the v2 beta manifest.
4. Run the unified release dry run.
5. Run the unified release deployment.
6. Verify both installation pages.

## Deployment protections

- Pinned Ed25519 signature verification.
- Manifest expiry and channel validation.
- GitHub release and asset digest verification.
- IPA checksum and application identity validation.
- Version-aware downgrade rejection.
- Immutable checksum-addressed IPA staging.
- Concurrent deployment protection.
- Signing activity checks.
- Deployment backups and rollback on caught failures.
- Dynamic website release number and publication date.
- Idempotent handling of an already deployed release.

## Server utilities

/usr/local/sbin/zag-stage-release
/usr/local/sbin/zag-activate-release

## Validation baseline

Beta 5 - 27 November 2026

Verified:
- Cryptographic smoke tests.
- Published manifest verification.
- GitHub asset verification.
- IPA validation.
- Dry run.
- Live preview and production page verification.
- Already-deployed release handling.
- Server utility installation and syntax validation.

Isolated regression tests passed:
- Successful synthetic Beta 6 activation.
- Preview failure rollback.
- Production failure rollback.
- Signing worker restart failure rollback.
- Busy signing worker rejection.
- Downgrade rejection.
- New version with reset build number.
- Remote staging path validation.

Run regression tests:
python3 ops/releases/test-release-activation.py

Outstanding:
- End-to-end activation of a newer release.
- Exclusive coordination with incoming signing jobs.
- Independent server-side manifest signature verification.
- Verification of all approved records during idempotency checks.
- Recovery from abrupt process termination or power loss.

Do not treat these outstanding items as tested.

## Design policy

Release deployment must not change website layout,
typography, colours, animations or unrelated components.

Private signing keys must never be committed or uploaded.
