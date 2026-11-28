#!/bin/zsh
# Rebuilds ZagAppleAuth.xcframework from pinned upstreams. apple-auth is a
# clean-room C++20 ADI implementation (MIT); it bundles no Apple or Android
# binaries and needs no CMake/vcpkg. Device arm64 static library.
#
# Pinned upstreams (cloned into a scratch dir; never executed from in-place):
#   apple-auth  github.com/apple-auth/apple-auth @ 98c862f7 (v0.1.3, MIT)
#   Mbed TLS    github.com/Mbed-TLS/mbedtls tag v3.6.2 (Apache-2.0)
#   nlohmann    github.com/nlohmann/json v3.11.3 (MIT, header only)
set -euo pipefail
here="${0:A:h}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
desktop=""
if [[ ${1:-} == --macos-library && $# == 2 ]]; then
  desktop="$2"
  sdk_name=macosx
  target=(-arch "$(uname -m)" -mmacosx-version-min=13.0)
elif (( $# == 0 )); then
  sdk_name=iphoneos
  target=(-arch arm64 -miphoneos-version-min=16.0)
else
  print -u2 "Usage: $0 [--macos-library OUTPUT_DIRECTORY]"
  exit 2
fi
sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
cc="$(xcrun --sdk "$sdk_name" --find clang)"; cxx="$(xcrun --sdk "$sdk_name" --find clang++)"
flags=("${target[@]}" -isysroot "$sdk" -Os)

git clone --depth 1 --branch v3.6.2 https://github.com/Mbed-TLS/mbedtls "$work/mbedtls"
git clone https://github.com/apple-auth/apple-auth "$work/aa"
git -C "$work/aa" checkout 98c862f7bebc8283a9b87f1578e703f0765dc81d
# Experimental diagnostic patch: surface Apple's GrandSlam `em` message.
for p in "$here"/patches/*.patch; do
  [ -e "$p" ] || continue
  git -C "$work/aa" apply "$p"
  echo "applied patch $(basename "$p")"
done
mkdir -p "$work/gen/apple_auth/nlohmann" "$work/obj"
if [[ -n "$desktop" ]]; then
  git clone --depth 1 --branch v3.11.3 https://github.com/nlohmann/json "$work/json"
  mkdir -p "$work/gen/nlohmann"
  cp "$work/json/single_include/nlohmann/json.hpp" "$work/gen/nlohmann/"
else
  curl -fsSL -o "$work/gen/nlohmann/json.hpp" --create-dirs \
    https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp
fi

# static-build export headers (empty visibility macros)
cat > "$work/gen/apple_auth/export.h" <<'H'
#ifndef APPLE_AUTH_EXPORT_H
#define APPLE_AUTH_EXPORT_H
#ifdef APPLE_AUTH_STATIC_DEFINE
#  define APPLE_AUTH_EXPORT
#  define APPLE_AUTH_NO_EXPORT
#else
#  define APPLE_AUTH_EXPORT __attribute__((visibility("default")))
#  define APPLE_AUTH_NO_EXPORT __attribute__((visibility("hidden")))
#endif
#ifndef APPLE_AUTH_DEPRECATED
#  define APPLE_AUTH_DEPRECATED __attribute__((__deprecated__))
#endif
#ifndef APPLE_AUTH_DEPRECATED_EXPORT
#  define APPLE_AUTH_DEPRECATED_EXPORT APPLE_AUTH_EXPORT APPLE_AUTH_DEPRECATED
#endif
#ifndef APPLE_AUTH_DEPRECATED_NO_EXPORT
#  define APPLE_AUTH_DEPRECATED_NO_EXPORT APPLE_AUTH_NO_EXPORT APPLE_AUTH_DEPRECATED
#endif
#endif
H
cat > "$work/gen/apple_auth/client_export.h" <<'H'
#ifndef APPLE_AUTH_CLIENT_EXPORT_H
#define APPLE_AUTH_CLIENT_EXPORT_H
#ifdef APPLE_AUTH_CLIENT_STATIC_DEFINE
#  define APPLE_AUTH_CLIENT_EXPORT
#  define APPLE_AUTH_CLIENT_NO_EXPORT
#else
#  define APPLE_AUTH_CLIENT_EXPORT __attribute__((visibility("default")))
#  define APPLE_AUTH_CLIENT_NO_EXPORT __attribute__((visibility("hidden")))
#endif
#endif
H

echo "== mbedtls =="
for c in "$work"/mbedtls/library/*.c; do
  "$cc" "${flags[@]}" -I"$work/mbedtls/include" -I"$work/mbedtls/library" -c "$c" -o "$work/obj/m_$(basename "$c" .c).o"
done
cxxflags=("${flags[@]}" -std=c++20 -fvisibility=hidden -DAPPLE_AUTH_STATIC_DEFINE -DAPPLE_AUTH_CLIENT_STATIC_DEFINE
  -I"$work/aa/src" -I"$work/aa/include" -I"$work/gen" -I"$work/mbedtls/include")
echo "== apple-auth core =="
for f in adi/core adi/key_derivation adi/file_key/mutation adi/state adi/otp adi/mac adi/android \
         adi/parameters adi/provisioning adi/provisioning/mixer adi/provisioning/seed \
         api/c_api crypto/crypto crypto/session_crypto crypto/srp sap/session sap/certificate; do
  "$cxx" "${cxxflags[@]}" -c "$work/aa/src/$f.cpp" -o "$work/obj/a_$(echo "$f" | tr / _).o"
done
echo "== apple-auth client =="
for f in api/client_api client/client client/client_support client/session_storage client/state_storage \
         client/external_transport client/apple_plist client/authentication client/store; do
  "$cxx" "${cxxflags[@]}" -c "$work/aa/src/$f.cpp" -o "$work/obj/c_$(echo "$f" | tr / _).o"
done
ar rcs "$work/libZagAppleAuth.a" "$work"/obj/*.o

mkdir -p "$work/headers/apple_auth"
cp "$work/aa/include/apple_auth/c_api.h" "$work/aa/include/apple_auth/client_c_api.h" "$work/headers/apple_auth/"
cp "$work/gen/apple_auth/export.h" "$work/gen/apple_auth/client_export.h" "$work/headers/apple_auth/"
cp "$here/include/ZagAppleAuth/module.modulemap" "$here/include/ZagAppleAuth/shim.h" "$work/headers/"

if [[ -n "$desktop" ]]; then
  mkdir -p "$desktop/include"
  cp -R "$work/headers/." "$desktop/include/"
  cp "$work/libZagAppleAuth.a" "$desktop/"
  exit 0
fi

rm -rf "$here/ZagAppleAuth.xcframework"
xcodebuild -create-xcframework -library "$work/libZagAppleAuth.a" -headers "$work/headers" \
  -output "$here/ZagAppleAuth.xcframework"
echo "built $here/ZagAppleAuth.xcframework"
