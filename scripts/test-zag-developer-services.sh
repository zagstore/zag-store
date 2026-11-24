#!/bin/zsh
# Offline host tests for the native developer-services codec. No Apple contact.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
cp "$ROOT/scripts/ZagDeveloperServicesTests.swift" "$OUT/main.swift"
# ZagDeveloperTokenStore uses ZagAppleAuthError (defined in the app's machine);
# stub it for the host-only compile.
printf 'import Foundation\nenum ZagAppleAuthError: Error, Equatable { case keychain(OSStatus) }\n' > "$OUT/shim.swift"
swiftc -O -o "$OUT/dsvc" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagPortalError.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagDeveloperServicesProtocol.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagDeveloperTokenStore.swift" \
  "$OUT/shim.swift" "$OUT/main.swift"
"$OUT/dsvc"
