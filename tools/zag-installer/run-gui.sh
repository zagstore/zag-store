#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Zag Installer's native graphical interface currently requires macOS." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SOURCE="$ROOT/tools/zag-installer/ZagInstallerApp.swift"
CACHE="$HOME/Library/Caches/app.zagstore.desktop-installer-ui"
mkdir -p "$CACHE"
chmod 700 "$CACHE"

command -v xcrun >/dev/null || {
    echo "Install Xcode Command Line Tools before starting Zag Installer." >&2
    exit 1
}

xcrun swiftc -parse "$SOURCE"
xcrun swiftc -parse-as-library -O -framework SwiftUI -framework AppKit \
    "$SOURCE" -o "$CACHE/ZagInstaller"

export ZAG_INSTALLER_ROOT="$ROOT"
exec "$CACHE/ZagInstaller"
