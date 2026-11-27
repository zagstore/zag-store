"""Read-only discovery via the macOS system usbmuxd socket."""
import json
import plistlib
import re
import socket
import struct

MAX_PACKET = 4 * 1024 * 1024
UDID = re.compile(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})")

def read_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ValueError("USB service disconnected")
        data.extend(chunk)
    return bytes(data)

def wired_devices():
    payload = plistlib.dumps({"MessageType": "ListDevices",
                              "ClientVersionString": "Zag Installer",
                              "kLibUSBMuxVersion": 3})
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect("/var/run/usbmuxd")
        sock.sendall(struct.pack("<IIII", 16 + len(payload), 1, 8, 1) + payload)
        length, version, kind, tag = struct.unpack("<IIII", read_exact(sock, 16))
        if not 16 < length <= MAX_PACKET or (version, kind, tag) != (1, 8, 1):
            raise ValueError("Invalid USB discovery response")
        result = plistlib.loads(read_exact(sock, length - 16))
    devices = result["DeviceList"]
    if not isinstance(devices, list):
        raise ValueError("Invalid USB device inventory")
    wired = []
    for entry in devices:
        props = entry["Properties"]
        if props.get("ConnectionType") != "USB":
            continue
        udid = props.get("SerialNumber")
        if not isinstance(udid, str) or not UDID.fullmatch(udid):
            raise ValueError("Invalid wired device identity")
        wired.append(udid)
    if len(set(wired)) != len(wired):
        raise ValueError("Ambiguous wired device inventory")
    return wired

if __name__ == "__main__":
    try:
        devices = wired_devices()
        print(json.dumps({"wired_count": len(devices),
                          "transport": "system-usbmuxd",
                          "trust_verified": False}))
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        raise SystemExit("USB discovery failed")
