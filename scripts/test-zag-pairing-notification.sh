#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-pairing-notification.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
swiftc -warnings-as-errors -parse-as-library "$ROOT/Feather/Utilities/ZagPairingCodeNotification.swift" \
    "$ROOT/scripts/ZagPairingCodeNotificationTests.swift" -o "$WORK/tests"
"$WORK/tests"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
core = (root / 'Feather/RPPairing/ZagRPPairingCore.swift').read_text()
callback = core.split('fileprivate func receive(code:', 1)[1].split('case 5:', 1)[0].split('case 4:', 1)[1]
assert 'state = .pin(message)' in callback
assert 'ZagPairingCodeNotification.content(for: message)' in callback
assert 'identifier: "zag-rppairing-pin"' in callback and 'trigger: nil' in callback
assert 'UIPasteboard' not in callback and 'Logger' not in callback
assert 'withIdentifiers: ["zag-rppairing-pin"]' in core
print('PASS: native callback/delivery/completion lifecycle retained; no automatic copy or code logging')
PY
