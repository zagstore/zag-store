#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$scratch/module-cache}" Feather/Utilities/ZagBatchPolicy.swift Feather/Utilities/ZagAppleIDMaintenancePolicy.swift scripts/ZagBatchPolicyTests.swift -o "$scratch/batch-policy"
"$scratch/batch-policy"
