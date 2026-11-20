#!/usr/bin/env bash
# Prepare an isolated, operator-owned Apple Music Android native runtime.
# This does not enable Zag Store provisioning or deploy a listener.
set -euo pipefail
umask 077

usage() {
  echo "Usage: $0 --apk /path/to/applemusic.apk --destination /path/to/runtime [--verify-only]" >&2
  exit 2
}
apk='' destination='' verify_only=0
while (($#)); do
  case "$1" in
    --apk) (($# >= 2)) || usage; apk=$2; shift 2 ;;
    --destination) (($# >= 2)) || usage; destination=$2; shift 2 ;;
    --verify-only) verify_only=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$destination" ]] || usage
command -v unzip >/dev/null || { echo "unzip required" >&2; exit 1; }
command -v file >/dev/null || { echo "file required" >&2; exit 1; }
arch=$(uname -m)
case "$arch" in
  x86_64) abi=x86_64 ;;
  aarch64|arm64) abi=arm64-v8a ;;
  *) echo "Unsupported host architecture: $arch" >&2; exit 1 ;;
esac
destination=$(realpath -m -- "$destination")
[[ "$destination" != / && "$destination" != /tmp && "$destination" != /var ]] || {
  echo "Refusing unsafe destination" >&2; exit 1;
}
libdir="$destination/lib/$abi"
verify() {
  for name in libstoreservicescore.so libCoreADI.so; do
    path="$libdir/$name"
    [[ -f "$path" && ! -L "$path" ]] || { echo "Missing regular library: $path" >&2; exit 1; }
    desc=$(file -b "$path")
    [[ "$desc" == *ELF* && "$desc" == *shared\ object* ]] || { echo "Not an ELF shared library: $name" >&2; exit 1; }
    case "$abi" in
      x86_64) [[ "$desc" == *x86-64* ]] || { echo "Wrong ELF architecture: $name" >&2; exit 1; } ;;
      arm64-v8a) [[ "$desc" == *aarch64* || "$desc" == *ARM\ aarch64* ]] || { echo "Wrong ELF architecture: $name" >&2; exit 1; } ;;
    esac
    sha256sum "$path"
  done
  echo "Native libraries present; provisioning functionality NOT verified."
}
if ((verify_only)); then verify; exit 0; fi
[[ -f "$apk" ]] || usage
[[ ! -e "$destination" ]] || { echo "Destination already exists; refusing overwrite: $destination" >&2; exit 1; }
parent=$(dirname "$destination")
mkdir -p -- "$parent"
stage=$(mktemp -d "$parent/.zag-adi-runtime.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
for name in libstoreservicescore.so libCoreADI.so; do
  member="lib/$abi/$name"
  unzip -Z1 "$apk" | grep -Fxq "$member" || { echo "Missing APK member: $member" >&2; exit 1; }
  mkdir -p "$stage/lib/$abi"
  unzip -p "$apk" "$member" > "$stage/lib/$abi/$name"
done
chmod -R go-rwx "$stage"
mv -- "$stage" "$destination"
trap - EXIT
verify
echo "Runtime staged at: $destination"
echo "No service was started; no native backend was activated."
