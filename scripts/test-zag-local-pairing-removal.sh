#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-local-removal.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library "$ROOT/Feather/Utilities/ZagLocalPairingRemoval.swift" \
    "$ROOT/Feather/Utilities/ZagOnboardingPolicy.swift" "$ROOT/scripts/ZagLocalPairingRemovalTests.swift" -o "$WORK/tests"
"$WORK/tests"
