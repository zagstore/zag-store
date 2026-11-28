#!/usr/bin/env bash
set -Eeuo pipefail

# Pinned official Sparkle binary distribution. No Homebrew or administrator access.
VERSION=2.10.1
EXPECTED_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"

[[ "$(uname -s)" == Darwin ]] || { echo "macOS required" >&2; exit 1; }

CACHE="$HOME/Library/Caches/app.zagstore.desktop-installer-ui/sparkle"
DEST="$CACHE/$VERSION"
mkdir -p "$CACHE"
chmod 700 "$CACHE"

if [[ -x "$DEST/bin/generate_keys" && -d "$DEST/Sparkle.framework" ]]; then
    echo "Sparkle $VERSION is already available at $DEST"
    echo "Key tool: $DEST/bin/generate_keys"
    exit 0
fi

TMP="$(mktemp -d "$CACHE/.download.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading official Sparkle $VERSION distribution..."
curl --fail --location --retry 3 --silent --show-error \
    --output "$TMP/Sparkle.tar.xz" "$URL"

ACTUAL="$(/usr/bin/shasum -a 256 "$TMP/Sparkle.tar.xz" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED_SHA256" ]]; then
    echo "Sparkle archive SHA-256 mismatch. Refusing extraction." >&2
    exit 1
fi
echo "PASS: official release archive SHA-256 verified"

mkdir "$TMP/unpacked"
tar -xf "$TMP/Sparkle.tar.xz" -C "$TMP/unpacked"
[[ -x "$TMP/unpacked/bin/generate_keys" ]] || { echo "Missing Sparkle generate_keys tool" >&2; exit 1; }
[[ -d "$TMP/unpacked/Sparkle.framework" ]] || { echo "Missing Sparkle.framework" >&2; exit 1; }

if [[ -e "$DEST" ]]; then
    echo "Existing incomplete Sparkle directory at $DEST; leaving untouched." >&2
    exit 1
fi
mv "$TMP/unpacked" "$DEST"
echo "Sparkle $VERSION ready at $DEST"
echo "Key tool: $DEST/bin/generate_keys"
echo "No update keys were generated or exported."
