#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-update-card-status.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" -parse-as-library \
    "$ROOT/Feather/Utilities/ZagUpdateProgressPresentation.swift" \
    "$ROOT/Feather/Utilities/ZagUpdateCardStatus.swift" \
    "$ROOT/scripts/ZagUpdateCardStatusTests.swift" -o "$WORK/tests"
"$WORK/tests"
