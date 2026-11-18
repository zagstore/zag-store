#!/bin/bash
# Several Apple Accounts at once (free and paid): sessions, stable IDs,
# default and explicit signing scope, migration from the single-account
# version, removal and per-account refresh records. Synthetic accounts and
# the simulated service only; nothing contacts Apple.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-apple-accounts.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library -D DEBUG -target "$(uname -m)-apple-macos13" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$ROOT/scripts/ZagFreeAccountTestSupport.swift" "$ROOT/scripts/ZagAppleAccountsTests.swift" -o "$WORK/tests"
"$WORK/tests"
