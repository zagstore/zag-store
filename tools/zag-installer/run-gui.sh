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

APP="$HOME/Applications/Zag Installer.app"
if [[ -d "/Applications/Zag Installer.app" ]]; then
    APP="/Applications/Zag Installer.app"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ASSETS="$ROOT/Feather/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$ASSETS/zagstore.png" "$ASSETS/zagstore_dark.png" "$APP/Contents/Resources/"
for variant in zagstore zagstore_dark; do
    source="$ROOT/tools/zag-installer/icons/${variant}_installer.png"
    [[ -s "$source" ]] || { echo "Missing approved installer artwork: $source" >&2; exit 1; }
    cp "$source" "$APP/Contents/Resources/${variant}_installer.png"
done
for variant in light dark; do
    name=ZagInstaller
    artwork=zagstore_installer
    if [[ "$variant" == dark ]]; then
        name=ZagInstallerDark
        artwork=zagstore_dark_installer
    fi
    ICONSET="$CACHE/$name.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    xcrun swift "$ROOT/tools/zag-installer/MakeDockIcon.swift" \
        "$APP/Contents/Resources/$artwork.png" "$CACHE/$name.png"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$CACHE/$name.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$CACHE/$name.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$name.icns"
done
install -m 755 "$CACHE/ZagInstaller" "$APP/Contents/MacOS/ZagInstaller"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Zag Installer</string>
    <key>CFBundleDisplayName</key><string>Zag Installer</string>
    <key>CFBundleIdentifier</key><string>app.zagstore.installer</string>
    <key>CFBundleExecutable</key><string>ZagInstaller</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>ZagInstaller.icns</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSUIElement</key><false/>
    <key>LSBackgroundOnly</key><false/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
touch "$APP"
open -n --env "ZAG_INSTALLER_ROOT=$ROOT" "$APP"
echo "Launched $APP"
