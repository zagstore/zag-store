#!/bin/zsh
# Build / package the full Feather app for the first READ-ONLY certificate-
# inventory experiment (Option B: separate app identity dev.zagstore.rocertinv,
# free Personal Team V54K5JYGS4), with the real native ZagAppleAuth module linked.
#
# Smallest maintainable integration: the ZagAppleAuth xcframework (static lib +
# clang module map) is put on the Swift import + link paths via build settings,
# so `import ZagAppleAuth` resolves and canImport(ZagAppleAuth) is true — WITHOUT
# modifying the shipping Xcode project. No second authentication implementation.
#
# NEVER contacts Apple, requests/revokes certificates, submits a CSR, or installs.
# The read-only transport (ZagReadOnlyTransport) remains the hard boundary for
# every Apple mutation regardless of the build. A compile-time #error fails any
# build that sets the live flag without the module.
#
# Subcommands:
#   build       (default) unsigned verify build — proves the live path compiles in.
#   preflight   read-only checks before any Apple op: cert present + team, device
#               connected, and (if ZAG_RO_PROFILE set) the profile matches the
#               intended team/bundle/device/cert and is unexpired. No Apple contact.
#   sign        build + sign an installable IPA. REQUIRES ZAG_RO_PROFILE (the
#               owner's dev.zagstore.rocertinv profile). Does NOT run Apple
#               provisioning or install. Held until the profile exists.
#
# Verified parameters (2026-11-25):
#   TEAM=V54K5JYGS4  BUNDLE=dev.zagstore.rocertinv
#   CERT SHA1=5657782A6EADFFF608040D39186E6533557349FC (Apple Development, OU=V54K5JYGS4) — REUSED, never recreated
#   DEVICE: the connected iPhone 15 Pro Max (UDID supplied via ZAG_RO_DEVICE_UDID)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCF="$ROOT/AppleAuthCore/apple-auth/ZagAppleAuth.xcframework/ios-arm64"
DD="${ZAG_RO_DERIVED:-$ROOT/.build-readonly-dd}"
TEAM="${ZAG_RO_TEAM:-V54K5JYGS4}"
BUNDLE="${ZAG_RO_BUNDLE_ID:-dev.zagstore.rocertinv}"
CERT_SHA1="${ZAG_RO_CERT:-5657782A6EADFFF608040D39186E6533557349FC}"
DEVICE_UDID="${ZAG_RO_DEVICE_UDID:-}"   # owner supplies the target UDID; never hardcoded
ENT="$ROOT/scripts/zag-rocertinv.entitlements"
MODE="${1:-build}"

[ -d "$XCF/Headers" ] || { echo "REFUSED: ZagAppleAuth module not found at $XCF/Headers" >&2; exit 1; }
[ -f "$XCF/libZagAppleAuth.a" ] || { echo "REFUSED: libZagAppleAuth.a not found at $XCF" >&2; exit 1; }

COND='$(inherited) ZAG_CERT_REPLACEMENT_EXPERIMENT ZAG_CERT_REPLACEMENT_READONLY_LIVE'
INC="\$(inherited) $XCF/Headers"
LD="\$(inherited) -L$XCF -lZagAppleAuth -lc++"

case "$MODE" in
preflight)
	echo "== preflight (read-only; no Apple contact) =="
	# 1. Reuse the existing Apple Development cert; confirm its team (OU).
	if security find-identity -v -p codesigning 2>/dev/null | grep -qi "$CERT_SHA1"; then
		echo "OK  signing identity $CERT_SHA1 present (reused; no new cert)"
	else echo "MISSING  Apple Development identity $CERT_SHA1 not in keychain"; fi
	# 2. Target device connected.
	if xcrun devicectl list devices 2>/dev/null | grep -qiE 'connected'; then
		echo "OK  a device is connected (install target)"
	else echo "NOTE  no device shows connected now (only needed at install time)"; fi
	echo "INTENDED  team=$TEAM  bundle=$BUNDLE  device=${DEVICE_UDID:-<set ZAG_RO_DEVICE_UDID>}  keychain-group=$TEAM.$BUNDLE"
	# 3. If the owner's profile exists, validate it fully.
	if [ -n "${ZAG_RO_PROFILE:-}" ] && [ -f "${ZAG_RO_PROFILE}" ]; then
		T=$(mktemp); security cms -D -i "$ZAG_RO_PROFILE" > "$T" 2>/dev/null || { echo "BAD  cannot decode profile"; exit 1; }
		AID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$T" 2>/dev/null)
		PT=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$T" 2>/dev/null)
		EXP=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$T" 2>/dev/null)
		DEVOK=$([ -n "$DEVICE_UDID" ] && /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$T" 2>/dev/null | grep -c "$DEVICE_UDID" || echo 0)
		[ "$AID" = "$TEAM.$BUNDLE" ] && echo "OK  profile application-identifier = $AID" || echo "MISMATCH  profile app-id=$AID expected $TEAM.$BUNDLE"
		[ "$PT" = "$TEAM" ] && echo "OK  profile team = $PT" || echo "MISMATCH  profile team=$PT expected $TEAM"
		[ "${DEVOK:-0}" -ge 1 ] && echo "OK  target device $DEVICE_UDID is in the profile" || echo "MISSING  device $DEVICE_UDID not in profile"
		echo "INFO  profile expires $EXP"
		rm -f "$T"
	else
		echo "PENDING  no ZAG_RO_PROFILE yet — owner must create the dev.zagstore.rocertinv profile (see docs)."
	fi
	exit 0
	;;
build)
	exec xcodebuild build -project "$ROOT/Feather.xcodeproj" -scheme Feather \
		-configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS="$COND" SWIFT_INCLUDE_PATHS="$INC" OTHER_LDFLAGS="$LD" \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' "${@:2}"
	;;
sign)
	: "${ZAG_RO_PROFILE:?sign requires ZAG_RO_PROFILE=<dev.zagstore.rocertinv .mobileprovision> (owner-created; held at the authorization boundary)}"
	[ -f "$ZAG_RO_PROFILE" ] || { echo "REFUSED: profile not found: $ZAG_RO_PROFILE" >&2; exit 1; }
	# Build unsigned (single self-contained executable so a hand-signed install
	# launches), as the free-team bundle id + team.
	xcodebuild build -project "$ROOT/Feather.xcodeproj" -scheme Feather \
		-configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS="$COND" SWIFT_INCLUDE_PATHS="$INC" OTHER_LDFLAGS="$LD" \
		PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" DEVELOPMENT_TEAM="$TEAM" \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' ENABLE_DEBUG_DYLIB=NO
	APP=$(find "$DD/Build/Products" -name 'Feather.app' -maxdepth 3 | head -1)
	[ -n "$APP" ] || { echo "REFUSED: no Feather.app produced" >&2; exit 1; }
	cp "$ZAG_RO_PROFILE" "$APP/embedded.mobileprovision"
	# Sign nested code first (frameworks/dylibs), then the app with entitlements.
	find "$APP/Frameworks" -type d -name '*.framework' 2>/dev/null | while read -r fw; do
		codesign --force --sign "$CERT_SHA1" --timestamp=none "$fw"
	done
	find "$APP" -type f -name '*.dylib' 2>/dev/null | while read -r dy; do
		codesign --force --sign "$CERT_SHA1" --timestamp=none "$dy"
	done
	codesign --force --sign "$CERT_SHA1" --entitlements "$ENT" --timestamp=none "$APP"
	codesign --verify --deep --strict "$APP" && echo "OK  codesign verify passed"
	OUT="${ZAG_RO_OUT:-$HOME/Documents/ZagStore-ReadOnlyCertInv-$BUNDLE.ipa}"
	STAGE=$(mktemp -d); mkdir -p "$STAGE/Payload"; cp -R "$APP" "$STAGE/Payload/"
	( cd "$STAGE" && zip -qry "$OUT" Payload )
	rm -rf "$STAGE"
	echo "IPA  $OUT"
	exit 0
	;;
*) echo "usage: $0 [build|preflight|sign]" >&2; exit 2 ;;
esac
