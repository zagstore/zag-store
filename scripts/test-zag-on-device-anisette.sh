#!/bin/bash
# Phase C: the on-device apple-auth anisette provider and its broker wiring.
# Compiles the anisette provider, the machine wrapper and their dependencies
# for the host (where the ZagAppleAuth module is absent, so the native path is
# compiled out) and runs the logic tests. The native path is validated on
# device separately. Nothing here contacts Apple or an anisette server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FA="$ROOT/Feather/Utilities/FreeAccount"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-on-device-anisette.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Minimal stand-ins for the two transport symbols ZagAnisetteProvider.swift
# references, so this focused test need not pull the whole transport/ASC chain.
# The real ZagDeadline/ZagTransportError are exercised by the bridge test suite.
cat > "$WORK/stubs.swift" <<'SWIFT'
import Foundation
enum ZagTransportError: Error, Equatable, Sendable { case timedOut, cancelled }
enum ZagDeadline {
	static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
		try await operation()
	}
}
SWIFT

swiftc -warnings-as-errors -parse-as-library -D DEBUG -target "$(uname -m)-apple-macos13" \
	"$WORK/stubs.swift" \
	"$FA/ZagAnisetteProvider.swift" \
	"$FA/ZagAppleAuthMachine.swift" \
	"$FA/ZagOnDeviceAnisetteProvider.swift" \
	"$ROOT/scripts/ZagOnDeviceAnisetteTests.swift" \
	-o "$WORK/tests"
"$WORK/tests"
