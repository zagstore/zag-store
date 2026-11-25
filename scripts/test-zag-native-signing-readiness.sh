#!/bin/zsh
# Compiles and runs the pure ZagNativeSigningReadiness unit test (no app deps).
set -euo pipefail
root="${0:A:h:h}"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

swiftc -O \
	"$root/Feather/Utilities/FreeAccount/ZagNativeSigningReadiness.swift" \
	"$root/scripts/ZagNativeSigningReadinessTests.swift" \
	-o "$out/readiness-test"
"$out/readiness-test"
