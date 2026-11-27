#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Zag Installer's native graphical interface currently requires macOS." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SOURCE="$ROOT/tools/zag-installer/ZagInstallerApp.swift"
UPDATE_SOURCE="$ROOT/tools/zag-installer/InstallerUpdates.swift"
SPARKLE_ROOT="$HOME/Library/Caches/app.zagstore.desktop-installer-ui/sparkle/2.10.1"
CACHE="$HOME/Library/Caches/app.zagstore.desktop-installer-ui"
mkdir -p "$CACHE"
chmod 700 "$CACHE"

command -v xcrun >/dev/null || {
    echo "Install Xcode Command Line Tools before starting Zag Installer." >&2
    exit 1
}

[[ -d "$SPARKLE_ROOT/Sparkle.framework" ]] || {
    echo "Run bash tools/zag-installer/bootstrap-sparkle.sh first." >&2
    exit 1
}

xcrun swiftc -parse "$SOURCE" "$UPDATE_SOURCE"
xcrun swiftc -parse-as-library -O -framework SwiftUI -framework AppKit \
    -F "$SPARKLE_ROOT" -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    "$SOURCE" "$UPDATE_SOURCE" -o "$CACHE/ZagInstaller"

APP="$HOME/Applications/Zag Installer.app"
if [[ -d "/Applications/Zag Installer.app" ]]; then
    APP="/Applications/Zag Installer.app"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
/usr/bin/ditto "$SPARKLE_ROOT/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
ASSETS="$ROOT/Feather/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$ASSETS/zagstore.png" "$ASSETS/zagstore_dark.png" "$APP/Contents/Resources/"
for variant in zagstore zagstore_dark; do
    source="$ROOT/tools/zag-installer/icons/${variant}_installer.png"
    [[ -s "$source" ]] || { echo "Missing approved installer artwork: $source" >&2; exit 1; }
    cp "$source" "$APP/Contents/Resources/${variant}_installer.png"
done
ICON_OUTPUT="$(mktemp -d "$CACHE/native-icon.XXXXXXXX")"
trap 'rm -rf "$ICON_OUTPUT"' EXIT

xcrun actool "$ROOT/tools/zag-installer/icons/ZagInstaller.icon" \
    --compile "$ICON_OUTPUT" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon ZagInstaller \
    --output-partial-info-plist "$ICON_OUTPUT/IconInfo.plist" \
    --output-format human-readable-text \
    --notices --warnings --errors

test -s "$ICON_OUTPUT/Assets.car"
test -s "$ICON_OUTPUT/ZagInstaller.icns"

cp "$ICON_OUTPUT/Assets.car" "$APP/Contents/Resources/"
cp "$ICON_OUTPUT/ZagInstaller.icns" "$APP/Contents/Resources/"
rm -f "$APP/Contents/Resources/ZagInstallerDark.icns"

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
    <key>CFBundleIconFile</key><string>ZagInstaller</string>
    <key>CFBundleIconName</key><string>ZagInstaller</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUAutomaticallyUpdate</key><false/>
    <key>ZagUpdatesReady</key><false/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSUIElement</key><false/>
    <key>LSBackgroundOnly</key><false/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
otool -L "$APP/Contents/MacOS/ZagInstaller" | grep "Sparkle.framework"
touch "$APP"
open -n --env "ZAG_INSTALLER_ROOT=$ROOT" "$APP"
echo "Launched $APP"
