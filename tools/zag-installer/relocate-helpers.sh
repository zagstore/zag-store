#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(uname -s)" == Darwin && $# == 2 && -d "$1" && ! -e "$2" ]] || { echo "Usage: $0 PREBUILT_DIRECTORY NEW_OUTPUT_DIRECTORY" >&2; exit 1; }
SRC="$(cd "$1" && pwd -P)"
DEST="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
TMP="$(mktemp -d "$(dirname "$DEST")/.zag-relocate.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
/usr/bin/ditto "$SRC" "$TMP/helpers"
cd "$TMP/helpers"
mkdir lib
for name in libssl.3.dylib libcrypto.3.dylib; do
  original="$(otool -L openssl | awk -v n="/$name" '$1 ~ n"$" {print $1}')"
  [[ "$original" == /* && -f "$original" ]] || { echo "Missing dependency: $name" >&2; exit 1; }
  cp -L "$original" "lib/$name"
  chmod u+w "lib/$name"
  install_name_tool -id "@loader_path/$name" "lib/$name"
  chmod u+w openssl
  install_name_tool -change "$original" "@loader_path/lib/$name" openssl
done
for binary in lib/libssl.3.dylib lib/libcrypto.3.dylib; do
  while IFS= read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*|@loader_path/*) ;;
      */libcrypto.3.dylib|*/libssl.3.dylib)
        install_name_tool -change "$dependency" "@loader_path/${dependency##*/}" "$binary" ;;
      *) echo "Unexpected dependency: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$binary" | awk 'NR>2 {print $1}')
done
for binary in lib/*.dylib openssl; do
  codesign --force --sign - "$binary"
  codesign --verify --strict "$binary"
done
for binary in release handoff zag_desktop zag-desktop-signer zag-desktop-anisette openssl lib/*.dylib; do
  otool -L "$binary"
  if otool -L "$binary" | awk 'NR>1 {print $1}' | grep -Ev '^(/usr/lib/|/System/Library/|@loader_path/)' ; then
    echo "Unresolved external dependency: $binary" >&2; exit 1
  fi
done
env -i PATH=/usr/bin:/bin HOME="$HOME" ./openssl version
env -i PATH=/usr/bin:/bin HOME="$HOME" ./openssl dgst -sha256 </dev/null
cd /
[[ ! -e "$DEST" ]] || exit 1
# Resolve the destination before changing working directory (absolute path required).
mv "$TMP/helpers" "$DEST"
echo "PASS: relocated OpenSSL and audited native helper dependencies"
