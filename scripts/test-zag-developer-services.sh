#!/bin/zsh
# Offline host tests for the native developer-services codec + issuance policy. No Apple contact.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
cp "$ROOT/scripts/ZagDeveloperServicesTests.swift" "$OUT/main.swift"
printf 'import Foundation\nenum ZagAppleAuthError: Error, Equatable { case keychain(OSStatus) }\n' > "$OUT/shim.swift"
swiftc -O -o "$OUT/dsvc" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagPortalError.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagDeveloperServicesProtocol.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagDeveloperTokenStore.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagMutationConsent.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagProfileIdentityAudit.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagCertificateIssuancePolicy.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagCertificateConflictResolution.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagCertificateReplacementCoordinator.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagMachineIdentifier.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagPendingCSRStore.swift" \
  "$OUT/shim.swift" "$OUT/main.swift"
"$OUT/dsvc"
