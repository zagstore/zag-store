#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS required" >&2; exit 1; }
[[ $# == 1 && ! -e "$1" ]] || { echo "Usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 1; }
DEST="$1"
export PATH="/opt/homebrew/opt/openssl@3/bin:/usr/local/opt/openssl@3/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
cd "$ROOT"
python3 - "$DEST" <<'PY'
import pathlib, sys, shutil, tempfile, subprocess
sys.path.insert(0, str(pathlib.Path.cwd() / "tools/zag-installer"))
import desktop
root = pathlib.Path.cwd()
dest = pathlib.Path(sys.argv[1]).absolute()
dest.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".zag-helpers-", dir=dest.parent) as tmp:
    stage = pathlib.Path(tmp) / "helpers"
    stage.mkdir(mode=0o700)
    with desktop.locked_cache() as cache:
        source = root / "tools/zag-installer"
        utilities = root / "Feather/Utilities"
        release = cache.build_swift("release", [
            source / "DesktopRelease.swift", source / "DesktopNetwork.swift",
            *[utilities / f"ZagUpdate{name}.swift" for name in
              ("MetadataV2", "TrustStore", "RollbackStore", "VerifiedPipeline", "V2Discovery")],
        ])
        handoff = cache.build_swift("handoff", [
            source / "DesktopHandoff.swift", utilities / "ZagIdentityHandoffEnvelope.swift",
        ])
        auth, signer, openssl, anisette = cache.installer_tools(root, native=True)
        for name, binary in {
            "release": release, "handoff": handoff, "zag_desktop": auth,
            "zag-desktop-signer": signer, "zag-desktop-anisette": anisette,
            "openssl": openssl,
        }.items():
            shutil.copy2(binary, stage / name)
            subprocess.run(["/usr/bin/file", str(stage / name)], check=True)
            subprocess.run(["/usr/bin/otool", "-L", str(stage / name)], check=True)
    adapter = desktop.PrecompiledCache(stage)
    adapter.build_swift("release", [])
    adapter.build_swift("handoff", [])
    adapter.installer_tools(root, native=True)
    if dest.exists():
        raise ValueError("Output directory already exists")
    stage.rename(dest)
print(f"PASS: staged six precompiled helpers at {dest}")
print("Development staging only: dynamic dependencies are not yet relocated.")
PY
