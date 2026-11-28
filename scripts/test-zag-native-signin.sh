#!/bin/bash
# Offline unit test for the pure native sign-in classifier (Option B).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-native-signin.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos13" \
	"$ROOT/Feather/Utilities/FreeAccount/ZagNativeSignInClassifier.swift" \
	"$ROOT/scripts/ZagNativeSignInClassifierTests.swift" \
	-o "$WORK/tests"
"$WORK/tests"
