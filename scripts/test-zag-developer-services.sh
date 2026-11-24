#!/bin/zsh
# Offline host tests for the native developer-services codec. No Apple contact.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
cp "$ROOT/scripts/ZagDeveloperServicesTests.swift" "$OUT/main.swift"
swiftc -O -o "$OUT/dsvc" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagPortalError.swift" \
  "$ROOT/Feather/Utilities/FreeAccount/ZagDeveloperServicesProtocol.swift" \
  "$OUT/main.swift"
"$OUT/dsvc"
