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

# Compile the original iOS renderer and presentation model directly.
# Extract only the shared palette declaration from its iOS-specific icon file.
SPECTRUM_SOURCE="$ROOT/Feather/Views/Settings/ZagUpdateSpectrumSurface.swift"
PROGRESS_SOURCE="$ROOT/Feather/Utilities/ZagUpdateProgressPresentation.swift"
PALETTE_SOURCE="$CACHE/ZagInstallerSpectrumPalette.swift"
{
    echo 'import SwiftUI'
    sed -n '/^enum ZagSelfUpdateSpectrum {$/,/^}$/p' "$ROOT/Feather/Views/TabView/Bars/ZagAppsTabIcon.swift"
} > "$PALETTE_SOURCE"
grep -q '^enum ZagSelfUpdateSpectrum {' "$PALETTE_SOURCE"
xcrun swiftc -parse "$SOURCE" "$UPDATE_SOURCE" "$SPECTRUM_SOURCE" "$PROGRESS_SOURCE" "$PALETTE_SOURCE"
xcrun swiftc -parse-as-library -O -framework SwiftUI -framework AppKit \
    -F "$SPARKLE_ROOT" -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    "$SOURCE" "$UPDATE_SOURCE" "$SPECTRUM_SOURCE" "$PROGRESS_SOURCE" "$PALETTE_SOURCE" -o "$CACHE/ZagInstaller"

APP="$HOME/Applications/Zag Installer.app"
NATIVE_DEV="${ZAG_INSTALLER_NATIVE_GUI_DEV:-0}"
if [[ -n "${ZAG_INSTALLER_APP_OUTPUT:-}" ]]; then
    APP="$ZAG_INSTALLER_APP_OUTPUT"
    [[ "$APP" == /*.app && ! -e "$APP" && ! -L "$APP" ]] || {
        echo "Specify an absolute, new .app output path." >&2; exit 1;
    }
elif [[ -d "/Applications/Zag Installer.app" ]]; then
    APP="/Applications/Zag Installer.app"
fi
if [[ "$NATIVE_DEV" == 1 ]]; then
    [[ -n "${ZAG_INSTALLER_APP_OUTPUT:-}" && -n "${ZAG_INSTALLER_ENGINE_STAGE:-}" ]] || {
        echo "Native GUI development requires a separate app output and staged engine." >&2; exit 1;
    }
    [[ "$("$ZAG_INSTALLER_ENGINE_STAGE/helpers/zag-usb" capabilities)" == '{"native_install_dev":true}' ]] || {
        echo "Native GUI development requires the explicitly feature-enabled USB helper." >&2; exit 1;
    }
elif [[ "$NATIVE_DEV" != 0 ]]; then
    echo "Invalid native GUI development setting." >&2; exit 1
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

# Opt-in development packaging: bundle the already-verified isolated engine.
# No source checkout or helper compilation is used by the GUI in this mode.
ENGINE_STAGE="${ZAG_INSTALLER_ENGINE_STAGE:-}"
ENGINE_DEST="$APP/Contents/Resources/DesktopEngine"
if [[ -n "$ENGINE_STAGE" ]]; then
    [[ -d "$ENGINE_STAGE" && ! -L "$ENGINE_STAGE" ]] || {
        echo "Invalid staged installer engine." >&2; exit 1;
    }
    ENGINE_STAGE="$(cd "$ENGINE_STAGE" && pwd -P)"
    for source in tools/zag-installer/zag_installer.py tools/zag-installer/native_preflight.py \
                  scripts/zag-personal-ota.py \
                  AppleAuthCore/zag-isideload/src/assets/apple_root.cer \
                  helpers/release helpers/handoff helpers/zag_desktop helpers/zag-usb \
                  helpers/zag-desktop-anisette helpers/zag-desktop-signer helpers/openssl \
                  helpers/lib/libssl.3.dylib helpers/lib/libcrypto.3.dylib; do
        [[ -f "$ENGINE_STAGE/$source" && ! -L "$ENGINE_STAGE/$source" ]] || {
            echo "Incomplete staged engine: $source" >&2; exit 1;
        }
    done
    ENGINE_NEXT="$APP/Contents/Resources/.DesktopEngine.next"
    rm -rf "$ENGINE_NEXT"
    [[ -x "$ENGINE_STAGE/helpers/zag-usb" ]] || { echo "Native USB helper is not executable." >&2; exit 1; }
    /usr/bin/ditto "$ENGINE_STAGE" "$ENGINE_NEXT"
    PYTHON_STAGE="${ZAG_INSTALLER_PYTHON_STAGE:-}"
    [[ -d "$PYTHON_STAGE" && ! -L "$PYTHON_STAGE" && -x "$PYTHON_STAGE/bin/python3" ]] || {
        echo "Bundled engine requires a verified private Python runtime via ZAG_INSTALLER_PYTHON_STAGE." >&2
        exit 1
    }
    /usr/bin/ditto "$PYTHON_STAGE" "$ENGINE_NEXT/python"
    env -i HOME="$HOME" PATH=/usr/bin:/bin \
        "$ENGINE_NEXT/python/bin/python3" -I -B -c \
        'import sys,ssl,hashlib,plistlib,zipfile; assert sys.version_info[:3] == (3,14,10)'
    env -i HOME="$HOME" PATH="$ENGINE_NEXT/helpers:/usr/bin:/bin" \
        "$ENGINE_NEXT/python/bin/python3" -B \
        "$ENGINE_NEXT/tools/zag-installer/zag_installer.py" --help >/dev/null
    rm -rf "$ENGINE_DEST"
    mv "$ENGINE_NEXT" "$ENGINE_DEST"
else
    rm -rf "$ENGINE_DEST"
fi

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
    <key>SUPublicEDKey</key><string>fJxMeEWbjDNHPzsWKgrJ83ymzKyh5u9Cx5Pi3HfEoWg=</string>
    <key>ZagUpdatesReady</key><false/>
    <key>ZagEngineBundled</key><false/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSUIElement</key><false/>
    <key>LSBackgroundOnly</key><false/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
if [[ -n "$ENGINE_STAGE" ]]; then
    /usr/libexec/PlistBuddy -c "Set :ZagEngineBundled true" "$APP/Contents/Info.plist"
fi
if [[ "$NATIVE_DEV" == 1 ]]; then
    /usr/libexec/PlistBuddy -c "Add :ZagNativeInstallDevelopment bool true" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 8" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
otool -L "$APP/Contents/MacOS/ZagInstaller" | grep "Sparkle.framework"
touch "$APP"
if [[ "$NATIVE_DEV" == 1 ]]; then
    echo "Built separate native USB development candidate: $APP"
else
    open -n --env "ZAG_INSTALLER_ROOT=$ROOT" "$APP"
    echo "Launched $APP"
fi
