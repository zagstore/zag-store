#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHON="$HOME/.venvs/zagstore-release/bin/python"

if [ ! -x "$PYTHON" ]; then
    echo "Release signing Python environment is missing." >&2
    exit 1
fi

exec "$PYTHON" \
    "$ROOT/ops/releases/zag-release-unified.py" "$@"
