#!/usr/bin/env bash
# Operator installer for the native anisette server on Ubuntu (x86_64).
# Run as root, and only with the owner's approval for that host.
#
#   install  --server BIN --worker BIN --runtime DIR --client-metadata FILE
#            [--platform android|windows [--licence-reviewed]] [--enable] [--dry-run]
#   rollback [--dry-run]     switch back to the previous release and restart if running
#   status                   unit state, /healthz and /readyz
#
# Each install is a new root-owned release directory holding both binaries
# and the platform's Apple library: the two Apple Music libraries
# (android, the default: DIR/lib/x86_64/*.so) or CoreADI64.dll from iTunes
# for Windows (windows: DIR/CoreADI64.dll, worker from
# tools/windows-coreadi-probe). A windows install also needs
# --licence-reviewed: see WINDOWS_NATIVE_BACKEND.md, "Licence".
# /etc/zag-anisette/native.env names the release,
# and the previous env file is kept for rollback. Nothing is enabled or
# started without --enable. The service binds 127.0.0.1:18760 (never the
# production ports 18743-18745) and never contacts Apple.
set -euo pipefail
umask 022

PREFIX=/usr/local/lib/zag-anisette
RELEASES=$PREFIX/releases
ENV_DIR=/etc/zag-anisette
ENV_FILE=$ENV_DIR/native.env
UNIT_NAME=zag-anisette-native.service
UNIT=/etc/systemd/system/$UNIT_NAME
LINK=/usr/local/bin/zag-anisette-server
SERVICE_USER=zag-anisette
STATE=/var/lib/zag-anisette
BIND=127.0.0.1:18760
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

dry=0
run() { if ((dry)); then printf 'would run:'; printf ' %q' "$@"; echo; else "$@"; fi; }
die() { echo "install-native-anisette: $*" >&2; exit 1; }
elf() { [[ -f "$1" && ! -L "$1" && "$(head -c 4 -- "$1" | od -An -c | tr -d ' ')" == '177ELF' ]]; }
ready() {
  local i
  for i in $(seq 1 30); do
    curl -fsS "http://$BIND/readyz" >/dev/null 2>&1 && { echo "READY: http://$BIND/readyz"; return 0; }
    sleep 1
  done
  echo "NOT READY after 30 s: see 'journalctl -u $UNIT_NAME' and http://$BIND/healthz" >&2
  return 1
}

cmd=${1:-}; shift || true
server='' worker='' runtime='' metadata='' enable=0 platform=android reviewed=0
while (($#)); do
  case "$1" in
    --server) server=$2; shift 2 ;;
    --worker) worker=$2; shift 2 ;;
    --runtime) runtime=$2; shift 2 ;;
    --client-metadata) metadata=$2; shift 2 ;;
    --platform) platform=$2; shift 2 ;;
    --licence-reviewed) reviewed=1; shift ;;
    --enable) enable=1; shift ;;
    --dry-run) dry=1; shift ;;
    *) die "unknown argument $1" ;;
  esac
done
case "$cmd" in install|rollback|status) ;; *) die "usage: install|rollback|status (see header)" ;; esac
if [[ "$cmd" == status ]]; then
  systemctl --no-pager status "$UNIT_NAME" || true
  curl -sS "http://$BIND/healthz"; echo
  curl -sS "http://$BIND/readyz"; echo
  exit 0
fi
((dry)) || [[ $EUID -eq 0 ]] || die "run as root (or --dry-run)"
[[ "$(uname -m)" == x86_64 ]] || die "x86_64 host required"

if [[ "$cmd" == rollback ]]; then
  [[ -f "$ENV_FILE.prev" ]] || die "no previous release recorded ($ENV_FILE.prev)"
  previous=$(sed -n 's/^ZAG_RELEASE=//p' "$ENV_FILE.prev")
  [[ -n "$previous" && -x "$RELEASES/$previous/zag-anisette-server" ]] || die "previous release $previous is missing"
  run cp -p "$ENV_FILE" "$ENV_FILE.rollback-from"
  run cp -p "$ENV_FILE.prev" "$ENV_FILE"
  run mv "$ENV_FILE.rollback-from" "$ENV_FILE.prev"
  run ln -sfn "$RELEASES/$previous/zag-anisette-server" "$LINK"
  if systemctl is-active --quiet "$UNIT_NAME"; then
    run systemctl restart "$UNIT_NAME"
    ((dry)) || ready
  fi
  echo "rolled back to $previous"
  exit 0
fi

[[ -n "$server" && -n "$worker" && -n "$runtime" && -n "$metadata" ]] || die "install needs --server, --worker, --runtime and --client-metadata"
elf "$server" && elf "$worker" || die "server and worker must be ELF executables"
case "$platform" in
  android)
    for lib in libstoreservicescore.so libCoreADI.so; do
      elf "$runtime/lib/x86_64/$lib" || die "missing or invalid $runtime/lib/x86_64/$lib"
    done ;;
  windows)
    ((reviewed)) || die "windows needs --licence-reviewed (iTunes for Windows licence, WINDOWS_NATIVE_BACKEND.md)"
    [[ -f "$runtime/CoreADI64.dll" && ! -L "$runtime/CoreADI64.dll" && "$(head -c 2 -- "$runtime/CoreADI64.dll")" == MZ ]] \
      || die "missing or invalid $runtime/CoreADI64.dll" ;;
  *) die "--platform must be android or windows" ;;
esac
[[ -f "$metadata" && ! -L "$metadata" ]] || die "client metadata file missing"
release="$(date -u +%Y%m%dT%H%M%SZ)-$(sha256sum -- "$worker" | cut -c1-12)"
dest=$RELEASES/$release
echo "== release $release"
run install -d -o root -g root -m 0755 "$PREFIX" "$RELEASES" "$dest" "$dest/runtime"
run install -o root -g root -m 0755 "$server" "$dest/zag-anisette-server"
run install -o root -g root -m 0755 "$worker" "$dest/zag-native-adi-worker"
if [[ "$platform" == windows ]]; then
  run install -o root -g root -m 0644 "$runtime/CoreADI64.dll" "$dest/runtime/CoreADI64.dll"
else
  run install -d -o root -g root -m 0755 "$dest/runtime/lib" "$dest/runtime/lib/x86_64"
  for lib in libstoreservicescore.so libCoreADI.so; do
    run install -o root -g root -m 0644 "$runtime/lib/x86_64/$lib" "$dest/runtime/lib/x86_64/$lib"
  done
fi
echo "== service account and state"
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  run useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
fi
run install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 "$STATE"
if [[ -e "$STATE/client-info.json" ]]; then
  echo "keeping the existing $STATE/client-info.json (replace it deliberately, owner $SERVICE_USER, mode 0600)"
else
  run install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0600 "$metadata" "$STATE/client-info.json"
fi
echo "== configuration"
run install -d -o root -g root -m 0755 "$ENV_DIR"
env_text="ZAG_RELEASE=$release
ZAG_ANISETTE_BIND=$BIND
ZAG_ANISETTE_NATIVE_PLATFORM=$platform
ZAG_ANISETTE_NATIVE_WORKER=$dest/zag-native-adi-worker
ZAG_ANISETTE_NATIVE_RUNTIME=$dest/runtime
ZAG_ANISETTE_STATE_DIR=$STATE
ZAG_ANISETTE_CLIENT_INFO_FILE=$STATE/client-info.json
ZAG_ANISETTE_MAX_NATIVE_WORKERS=4"
if ((dry)); then
  echo "would write $ENV_FILE:"; echo "$env_text"
else
  [[ -f "$ENV_FILE" ]] && cp -p "$ENV_FILE" "$ENV_FILE.prev"
  printf '%s\n' "$env_text" > "$ENV_FILE.new"
  chmod 0644 "$ENV_FILE.new"
  mv "$ENV_FILE.new" "$ENV_FILE"
fi
run ln -sfn "$dest/zag-anisette-server" "$LINK"
run install -o root -g root -m 0644 "$HERE/zag-anisette-native.service" "$UNIT"
run systemctl daemon-reload
if ((enable)); then
  run systemctl enable --now "$UNIT_NAME"
  ((dry)) || ready
else
  echo "installed, not enabled. Start with: systemctl enable --now $UNIT_NAME; then curl http://$BIND/readyz"
fi
