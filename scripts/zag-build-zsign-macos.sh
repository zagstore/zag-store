#!/bin/bash
# Builds the app's own Zsign sources (the same files Zsign/Package.swift
# compiles for the app) as a macOS library, so tests can sign with the real
# signer. Builds into the directory given; never writes inside Zsign/.
# Needs Homebrew OpenSSL 3 (static libcrypto for this Mac's architecture).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"
Z="$ROOT/Zsign/src"
SSL="${ZAG_OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null || true)}"
[ -f "$SSL/lib/libcrypto.a" ] || { echo "SKIP: Homebrew openssl@3 (static libcrypto) is required" >&2; exit 3; }
mkdir -p "$OUT/obj" "$OUT/include"
TARGET="$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)"
FLAGS=(-target "$TARGET" -std=c++17 -w -O1 -I"$Z" -I"$Z/common" -I"$SSL/include")
for f in archo.cpp bundle.cpp macho.cpp openssl.cpp signing.cpp \
	common/base64.cpp common/fs.cpp common/json.cpp common/log.cpp common/sha.cpp common/timer.cpp common/util.cpp; do
	clang++ "${FLAGS[@]}" -c "$Z/$f" -o "$OUT/obj/${f//\//_}.o" &
done
for f in openssl_tools.mm zsign.mm; do
	clang++ "${FLAGS[@]}" -fobjc-arc -c "$Z/$f" -o "$OUT/obj/$f.o" &
done
wait
rm -f "$OUT/libzsign.a"
libtool -static -o "$OUT/libzsign.a" "$OUT"/obj/*.o "$SSL/lib/libcrypto.a" 2>/dev/null
cat > "$OUT/include/module.modulemap" <<EOF
module Zsign {
	header "$Z/include/Zsign.h"
	export *
}
EOF
echo "$OUT/libzsign.a"
