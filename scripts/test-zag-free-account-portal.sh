#!/bin/bash
# Free Apple Account phase 3 groundwork: provisioning (devices, certificates,
# App IDs, app groups, profiles, entitlements) against the simulated
# developer portal. Synthetic data only; nothing contacts Apple.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-free-account-portal.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library -D DEBUG -target "$(uname -m)-apple-macos13" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$ROOT/scripts/ZagFreeAccountTestSupport.swift" "$ROOT/scripts/ZagFreeAccountPortalTests.swift" -o "$WORK/tests"
"$WORK/tests"
