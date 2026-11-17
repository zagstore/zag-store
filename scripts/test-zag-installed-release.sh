#!/bin/bash
# What's New extraction, release labels and installation dates for Software
# Update's up-to-date state and More Details. macOS only; nothing is installed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-installed-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -module-cache-path "$WORK/cache" -parse-as-library \
	"$ROOT/Feather/Utilities/ZagUpdateReleaseNotes.swift" \
	"$ROOT/Feather/Utilities/ZagInstalledRelease.swift" \
	"$ROOT/scripts/ZagInstalledReleaseTests.swift" -o "$WORK/tests"
"$WORK/tests"
