#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc Feather/Utilities/ZagBatchPolicy.swift scripts/ZagBatchPolicyTests.swift -o "$scratch/batch-policy"
"$scratch/batch-policy"
