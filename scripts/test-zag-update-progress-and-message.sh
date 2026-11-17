#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-progress-message.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" -parse-as-library \
    "$ROOT/Feather/Utilities/ZagUpdateProgressPresentation.swift" \
    "$ROOT/Feather/Utilities/ZagPostUpdateMessage.swift" \
    "$ROOT/Feather/Utilities/ZagUpdateCompletion.swift" \
    "$ROOT/scripts/ZagUpdateProgressAndMessageTests.swift" -o "$WORK/tests"
"$WORK/tests"
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}" -parse-as-library \
    "$ROOT/Feather/Utilities/ZagPackageIntegrity.swift" \
    "$ROOT/Feather/Utilities/ZagUpdateProgressPresentation.swift" \
    "$ROOT/scripts/ZagUpdateStreamingProgressTests.swift" -o "$WORK/streaming-tests"
"$WORK/streaming-tests"
