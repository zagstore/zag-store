#!/bin/bash
# Builds Zag Companion.app — the macOS SwiftUI companion — by compiling Zag
# Store's signing engine, the companion core and the SwiftUI app together and
# linking Zsign, then assembling a double-clickable .app bundle with the
# provisioning template bundled in Resources.
#
# Usage:  ZagCompanion/build-zag-companion.sh [output-dir]
# Output: <output-dir>/ZagCompanion.app   (default: ZagCompanion/build)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${ZAG_ZSIGN_BRANCH:-zag-free-account-signing}"
OUT_DIR="${1:-$ROOT/ZagCompanion/build}"
APP="$OUT_DIR/ZagCompanion.app"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-companion-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"

echo "Building Zsign ($BRANCH)…"
mkdir -p "$WORK/zsign"
git -C "$ROOT/Zsign" archive "$BRANCH" | tar -x -C "$WORK/zsign"
ZAG_ZSIGN_SRC="$WORK/zsign/src" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/branchlib" >/dev/null

echo "Compiling engine + companion + app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -O -D ZAG_ZSIGN_TESTS -D ZAG_ZSIGN_STRICT -target "$(uname -m)-apple-macos$MACOS_MAJOR" \
	-I "$WORK/branchlib/include" \
	"$ROOT"/Feather/Utilities/FreeAccount/*.swift \
	"$ROOT/Feather/Utilities/ZagEntitlementCompatibility.swift" \
	"$ROOT/Feather/Utilities/CertificateReader/Models/CertificateModel.swift" \
	"$ROOT/Feather/Utilities/AnyCodable.swift" \
	"$WORK/zsign/Sources/zsign.swift" \
	"$ROOT"/ZagCompanion/Core/*.swift \
	"$ROOT"/ZagCompanion/App/*.swift \
	-Xlinker "$WORK/branchlib/libzsign.a" -lc++ \
	-framework Security -framework Foundation -framework SwiftUI -framework AppKit -framework CryptoKit \
	-o "$APP/Contents/MacOS/ZagCompanion"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>Zag Companion</string>
	<key>CFBundleDisplayName</key><string>Zag Companion</string>
	<key>CFBundleIdentifier</key><string>com.zagstore.companion</string>
	<key>CFBundleExecutable</key><string>ZagCompanion</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>${MACOS_MAJOR}.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Bundle the provisioning template so the app can provision new bundle IDs.
cp -R "$ROOT/experiments/XcodePTTeamProbe" "$APP/Contents/Resources/XcodePTTeamProbe"
rm -rf "$APP/Contents/Resources/XcodePTTeamProbe/build" "$APP/Contents/Resources/XcodePTTeamProbe"/*.xcodeproj/xcuserdata 2>/dev/null || true

# Ad-hoc sign the companion so macOS runs it without quarantine friction.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "Built: $APP"
echo "Launch with:  open \"$APP\""
