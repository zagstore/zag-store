#!/usr/bin/env bash
# Build a separate, locally signed candidate from current source. No device writes.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "$(uname -s)" == Darwin && $# == 3 ]] || {
    echo "Usage: $0 PRIVATE_PYTHON_STAGE NATIVE_USB_HELPER NEW_APP_PATH" >&2; exit 1;
}
PYTHON_STAGE="$1"
USB_HELPER="$2"
APP="$3"
[[ "$APP" == /*.app && ! -e "$APP" && ! -L "$APP" ]] || { echo "Choose a new absolute app path." >&2; exit 1; }
[[ -x "$PYTHON_STAGE/bin/python3" && -x "$USB_HELPER" && ! -L "$USB_HELPER" ]] || { echo "Missing runtime or USB helper." >&2; exit 1; }
[[ "$("$USB_HELPER" capabilities)" == '{"native_install_dev":true}' ]] || { echo "Native USB helper is not enabled." >&2; exit 1; }
export PATH="/opt/homebrew/opt/openssl@3/bin:/usr/local/opt/openssl@3/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
WORK="$(mktemp -d /tmp/zag-candidate.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
(cd tools/zag-installer && python3 -m unittest -q test_zag_installer test_desktop test_handoff test_ui_protocol)
bash tools/zag-installer/package-helpers.sh "$WORK/helpers"
bash tools/zag-installer/relocate-helpers.sh "$WORK/helpers" "$WORK/relocated"
ZAG_INSTALLER_USB_HELPER="$USB_HELPER" bash tools/zag-installer/package-engine.sh "$WORK/relocated" "$WORK/engine"
ZAG_INSTALLER_ENGINE_STAGE="$WORK/engine" ZAG_INSTALLER_PYTHON_STAGE="$PYTHON_STAGE" \
    ZAG_INSTALLER_NATIVE_GUI_DEV=1 ZAG_INSTALLER_APP_OUTPUT="$APP" bash tools/zag-installer/run-gui.sh
codesign --verify --deep --strict "$APP"
echo "=== CANDIDATE VERSION ==="
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist"
echo "PASS: local candidate built; no installation or pairing performed."
