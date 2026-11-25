#!/bin/zsh
# Offline host tests for the native developer-services codec + issuance policy. No Apple contact.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
cp "$ROOT/scripts/ZagDeveloperServicesTests.swift" "$OUT/main.swift"
cat > "$OUT/shim.swift" <<'SHIM'
import Foundation
enum ZagAppleAuthError: Error, Equatable { case keychain(OSStatus) }
// Lightweight model structs (defined in heavy portal files in the app) so the
// replacement service compiles for host tests without the transport stack.
struct ZagCertificateRequest: Sendable, Equatable { let data: Data }
struct ZagDevelopmentCertificate: Codable, Equatable, Sendable {
    let serialNumber: String; let name: String; let machineName: String?
    let expiresAt: Date; var data: Data? = nil
}
struct ZagIssuedCertificate: Sendable, Equatable {
    let certificate: ZagDevelopmentCertificate; let data: Data
}
SHIM
swiftc -O -o "$OUT/dsvc" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagPortalError.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagDeveloperServicesProtocol.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagDeveloperTokenStore.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagMutationConsent.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagProfileIdentityAudit.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagCertificateIssuancePolicy.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagCertificateConflictResolution.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagCertificateReplacementCoordinator.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagCertificateReplacementService.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagMachineIdentifier.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagPendingCSRStore.swift" \
  "$OUT/shim.swift" "$OUT/main.swift"
"$OUT/dsvc"
