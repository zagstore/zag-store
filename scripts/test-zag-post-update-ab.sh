#!/bin/bash
# Local A→B post-update splash test: real, distinguishable executables through the
# production hasher and one-shot message store. Publishes and signs nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-post-update-ab.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
CACHE="${CLANG_MODULE_CACHE_PATH:-$WORK/module-cache}"
for variant in A B B2; do
    printf 'print("Zag Store A/B fixture %s")\n' "$variant" > "$WORK/$variant.swift"
    swiftc -module-cache-path "$CACHE" "$WORK/$variant.swift" -o "$WORK/$variant"
done
swiftc -module-cache-path "$CACHE" -parse-as-library \
    "$ROOT/Feather/Utilities/ZagPackageIntegrity.swift" \
    "$ROOT/Feather/Utilities/ZagUpdateProgressPresentation.swift" \
    "$ROOT/Feather/Utilities/ZagPostUpdateMessage.swift" \
    "$ROOT/scripts/ZagPostUpdateABTests.swift" -o "$WORK/tests"
"$WORK/tests" "$WORK/A" "$WORK/B" "$WORK/B2"
