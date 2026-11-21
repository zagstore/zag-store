#!/usr/bin/python3 -I
"""Offline stand-in for `--native-v2-session`, used only by the coordinator's
integration tests. Speaks the real v2 framing; holds no Apple code or data.

Usage: fake_native_worker.py <script> <claimed-state-dir>
"""
import json
import os
import struct
import sys
import time

SPIM, CPIM, PTM, TK, ADI_PB = (b"offline-spim", b"offline-cpim", b"offline-ptm",
                                b"offline-tk", b"offline-adi-pb")


def read_frame():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        sys.exit(10)
    payload = sys.stdin.buffer.read(struct.unpack(">I", header)[0])
    return json.loads(payload)


def send(message):
    payload = json.dumps(message, separators=(",", ":")).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
    sys.stdout.buffer.flush()


def error():
    send({"version": 2, "type": "error", "code": "backend_unavailable"})
    sys.exit(1)


def main():
    script, state = sys.argv[1], sys.argv[2]
    start = read_frame()
    if start != {"version": 2, "type": "start", "identifier": "-2", "spim_hex": SPIM.hex()}:
        sys.exit(11)
    if script == "reject-start":
        error()
    if script == "exit-at-start":
        sys.exit(3)
    if script == "hang-at-start":
        time.sleep(30)
    send({"version": 2, "type": "started", "cpim_hex": CPIM.hex()})
    if script == "hang-after-start":
        # Ignores stdin closure: only the coordinator's abort stops it early.
        time.sleep(30)
    finish = read_frame()
    if finish != {"version": 2, "type": "finish", "ptm_hex": PTM.hex(), "tk_hex": TK.hex()}:
        sys.exit(12)
    if script == "reject-finish":
        error()
    if script != "no-state":
        with open(os.path.join(state, "adi.pb"), "wb") as handle:
            handle.write(b"other-state" if script == "mismatched-state" else ADI_PB)
    send({"version": 2, "type": "finished", "adi_pb_hex": ADI_PB.hex()})
    sys.exit(4 if script == "fail-after-finish" else 0)


main()
