#!/usr/bin/env python3
"""Offline-only two-phase IPC fixture; never load native ADI libraries."""
import json
import struct
import sys

LIMIT = 65536


def read_frame():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        raise ValueError("missing frame")
    size = struct.unpack(">I", header)[0]
    if not 0 < size <= LIMIT:
        raise ValueError("invalid frame length")
    payload = sys.stdin.buffer.read(size)
    if len(payload) != size:
        raise ValueError("truncated frame")
    return json.loads(payload)


def write_frame(value):
    payload = json.dumps(value, separators=(",", ":")).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
    sys.stdout.buffer.flush()


def main():
    start = read_frame()
    if set(start) != {"version", "type", "identifier", "spim"} or start["version"] != 1 or start["type"] != "start":
        raise ValueError("invalid Start")
    if not all(isinstance(start[k], str) and start[k] for k in ("identifier", "spim")):
        raise ValueError("invalid Start fields")
    identifier = start["identifier"]
    write_frame({"version": 1, "type": "started", "cpim": "mock"})
    finish = read_frame()
    if set(finish) != {"version", "type", "ptm", "tk"} or finish["version"] != 1 or finish["type"] != "finish":
        raise ValueError("invalid Finish")
    if not all(isinstance(finish[k], str) and finish[k] for k in ("ptm", "tk")):
        raise ValueError("invalid Finish fields")
    assert identifier == start["identifier"]
    write_frame({"version": 1, "type": "finished", "adi_pb": "mock"})
    if sys.stdin.buffer.read(1):
        raise ValueError("extra input")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, AssertionError, TypeError, KeyError, json.JSONDecodeError):
        sys.exit(1)
