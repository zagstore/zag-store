#!/bin/zsh
# Build the full Feather app for the first READ-ONLY certificate-inventory
# experiment, with the real native ZagAppleAuth module linked. This is the
# smallest maintainable integration: the xcframework (a static lib + clang
# module map) is put on the Swift import and link paths via build settings, so
# `import ZagAppleAuth` resolves and `canImport(ZagAppleAuth)` is true — WITHOUT
# modifying the shipping Xcode project. No second authentication implementation.
#
# It NEVER signs, installs, submits a CSR, revokes anything or contacts Apple.
# The read-only transport (ZagReadOnlyTransport) remains the hard boundary for
# every Apple mutation regardless of the build.
#
# Usage:
#   zag-build-readonly-cert-inventory.sh            # unsigned build (verify compile-in)
#   ZAG_RO_SIGN=1 zag-build-readonly-cert-inventory.sh   # (reserved; signing not wired here)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCF="$ROOT/AppleAuthCore/apple-auth/ZagAppleAuth.xcframework/ios-arm64"
DD="${ZAG_RO_DERIVED:-$ROOT/.build-readonly-dd}"

[ -d "$XCF/Headers" ] || { echo "REFUSED: ZagAppleAuth module not found at $XCF/Headers" >&2; exit 1; }
[ -f "$XCF/libZagAppleAuth.a" ] || { echo "REFUSED: libZagAppleAuth.a not found at $XCF" >&2; exit 1; }

# Both experiment conditions + the native module on the import/link paths. The
# compile-time #error guard (ZagReadOnlyDeveloperTransport.swift) fails the build
# if the module is somehow absent, so a green build is proof the live path is in.
xcodebuild build \
  -project "$ROOT/Feather.xcodeproj" -scheme Feather \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) ZAG_CERT_REPLACEMENT_EXPERIMENT ZAG_CERT_REPLACEMENT_READONLY_LIVE' \
  SWIFT_INCLUDE_PATHS="\$(inherited) $XCF/Headers" \
  OTHER_LDFLAGS="\$(inherited) -L$XCF -lZagAppleAuth -lc++" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  "$@"
