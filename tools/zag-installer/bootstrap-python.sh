#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(uname -s)" == Darwin ]] || exit 1
case "$(uname -m)" in
 x86_64) target=x86_64; digest=8198777467d9d3900417dc1cfd9d512956deaebabe293d08aea5cfa5c70d6957 ;;
 arm64) target=aarch64; digest=81fca81fcc8a715288fd12286b66bbdaaf4a0db6818bc91826ddbcffae2ac2cf ;;
 *) echo "Unsupported architecture" >&2; exit 1 ;;
esac
CACHE="$HOME/Library/Caches/app.zagstore.desktop-installer-ui"
mkdir -p "$CACHE"
DEST="$CACHE/python-3.14.10-$target"
[[ ! -e "$DEST" ]] || { echo "Runtime already exists: $DEST"; exit 1; }
TMP="$(mktemp -d "$CACHE/.python.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261124/cpython-3.14.10%2B20261124-$target-apple-darwin-install_only_stripped.tar.gz"
curl --fail --location --proto '=https' --proto-redir '=https' --retry 2 -o "$TMP/runtime.tar.gz" "$URL"
printf '%s  %s\n' "$digest" "$TMP/runtime.tar.gz" | shasum -a 256 -c -
# Only extract the upstream archive after checking its pinned SHA-256.
/usr/bin/tar -xzf "$TMP/runtime.tar.gz" -C "$TMP"
test -x "$TMP/python/bin/python3"
mv "$TMP/python" "$DEST"
env -i HOME="$HOME" PATH=/usr/bin:/bin "$DEST/bin/python3" -I -B -c '
import sys, ssl, hashlib, subprocess, plistlib, zipfile, fcntl, pathlib, ctypes
assert sys.version_info[:3] == (3,14,10)
assert pathlib.Path(sys.prefix).resolve() == pathlib.Path(sys.argv[1]).resolve()
print("PASS: private Python", sys.version)
print(ssl.OPENSSL_VERSION)
' "$DEST"
printf 'PASS: pinned portable Python runtime at %s\n' "$DEST"
