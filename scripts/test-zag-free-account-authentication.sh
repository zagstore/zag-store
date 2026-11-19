#!/bin/bash
# Free Apple Account phase 2 groundwork: anisette provider settings and
# broker, transport policy, sign-in state machine with two-factor prompts,
# session storage and sign-out, validation, timeouts, cancellation and
# redacted diagnostics. Simulated services and synthetic credentials only:
# nothing contacts Apple or an anisette provider.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-free-account-auth.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos13" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" "$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" "$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$ROOT/scripts/ZagFreeAccountAuthenticationTests.swift" -o "$WORK/tests"
"$WORK/tests"
