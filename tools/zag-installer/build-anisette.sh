#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$1"
zsh "$root/AppleAuthCore/apple-auth/build-apple-auth.sh" --macos-library "$out"
cp "$root/tools/zag-installer/DesktopAnisette.swift" "$out/main.swift"
swiftc -module-cache-path "$out/module-cache" -I "$out/include" "$out/main.swift" "$root/tools/zag-installer/DesktopNetwork.swift" \
    -Xlinker "$out/libZagAppleAuth.a" -lc++ -o "$out/zag-desktop-anisette.pending"
mv -f "$out/zag-desktop-anisette.pending" "$out/zag-desktop-anisette"
