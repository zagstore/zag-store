#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$1"
bash "$root/scripts/zag-build-zsign-macos.sh" "$out"
swiftc -module-cache-path "$out/module-cache" -I "$out/include" "$root/tools/zag-installer/DesktopSigner.swift" \
    -Xlinker "$out/libzsign.a" -lc++ -framework Security -o "$out/zag-desktop-signer.pending"
mv -f "$out/zag-desktop-signer.pending" "$out/zag-desktop-signer"
