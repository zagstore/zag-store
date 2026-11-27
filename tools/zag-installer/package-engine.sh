#!/usr/bin/env bash
# Stage a source-independent copy of the installer Python engine and native tools.
# Development-only: requires a private Python runtime and USB adapter before distribution.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "$(uname -s)" == Darwin && $# == 2 && -d "$1" && ! -e "$2" ]] || {
    echo "Usage: $0 RELOCATED_HELPERS_DIRECTORY NEW_OUTPUT_DIRECTORY" >&2; exit 1;
}
INPUT="$(cd "$1" && pwd -P)"
mkdir -p "$(dirname "$2")"
PARENT="$(cd "$(dirname "$2")" && pwd -P)"
DEST="$PARENT/$(basename "$2")"
TEMP="$(mktemp -d "$PARENT/.zag-engine.XXXXXXXX")"
trap 'rm -rf "$TEMP"' EXIT

mkdir -p "$TEMP/package/tools/zag-installer" "$TEMP/package/scripts" "$TEMP/package/helpers" \
    "$TEMP/package/AppleAuthCore/zag-isideload/src/assets"
for name in zag_installer.py desktop.py handoff.py releases.py ui_protocol.py; do
    cp "$ROOT/tools/zag-installer/$name" "$TEMP/package/tools/zag-installer/$name"
done
cp "$ROOT/scripts/zag-personal-ota.py" "$TEMP/package/scripts/zag-personal-ota.py"
cp "$ROOT/AppleAuthCore/zag-isideload/src/assets/apple_root.cer" \
   "$TEMP/package/AppleAuthCore/zag-isideload/src/assets/apple_root.cer"
/usr/bin/ditto "$INPUT" "$TEMP/package/helpers"

# Verify the copied artifact validator and desktop modules without executing the
# installation CLI, performing network requests, or contacting an iPhone.
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - "$TEMP/package" <<'PY'
from pathlib import Path
import ast
import importlib.util
import os
import sys

root = Path(sys.argv[1]).resolve(strict=True)
module_root = root / "tools" / "zag-installer"
for name in ("zag_installer", "desktop", "handoff", "releases", "ui_protocol"):
    path = module_root / f"{name}.py"
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
ast.parse((root / "scripts" / "zag-personal-ota.py").read_text(encoding="utf-8"))
sys.path.insert(0, str(module_root))
import desktop
import releases
import handoff
import ui_protocol
sys.path.insert(0, str(root / "scripts"))
spec = importlib.util.spec_from_file_location("artifact_validation", root / "scripts" / "zag-personal-ota.py")
assert spec is not None and spec.loader is not None
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)
assert artifact.ORIGINAL == "app.zagstore.ios"
from hashlib import sha256
certificate = root / "AppleAuthCore/zag-isideload/src/assets/apple_root.cer"
assert sha256(certificate.read_bytes()).hexdigest() == artifact.APPLE_ROOT
cache = desktop.PrecompiledCache(root / "helpers")
assert cache.build_swift("release", []) == root / "helpers" / "release"
assert cache.installer_tools(root, native=True)[0].is_file()
print("PASS: isolated Python resources and precompiled helpers")
PY

# Hard fail if any staging source is a symlink or unexpected executable file.
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 - "$TEMP/package" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in root.rglob("*"):
    if path.is_symlink():
        raise SystemExit(f"Refusing symlink in package: {path}")
print("PASS: staged package has no symlink dependencies")
PY
mv "$TEMP/package" "$DEST"
printf 'PASS: staged desktop engine at %s\n' "$DEST"
echo "NOTE: local Python and CoreDevice still required; this is not distributable."
