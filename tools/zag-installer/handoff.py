"""Explicit USB handoff of the existing desktop signing identity."""

import base64
import hashlib
import hmac
import json
from pathlib import Path
import re
import time

import desktop

MAX_SIZE = 16 * 1024
REQUEST = "Documents/ZagIdentityHandoffRequest.json"
RESPONSE = "Documents/ZagIdentityHandoffResponse.json"


def read_request(path, code, udid, bundle, team):
    with path.open("rb") as stream:
        raw = stream.read(MAX_SIZE + 1)
    desktop.require(0 < len(raw) <= MAX_SIZE, "Invalid iPhone handoff request size")
    expected_code = hashlib.sha256(raw).hexdigest()[:24]
    desktop.require(hmac.compare_digest(code, expected_code), "The iPhone verification code does not match this request")
    request = json.loads(raw)
    desktop.require(request["protocolVersion"] == 1 and request["udid"].casefold() == udid.casefold()
                    and request["bundle"] == bundle and request["team"] == team,
                    "The handoff request is for a different device, bundle or team")
    desktop.require(re.fullmatch(r"[0-9a-f]{64}", request["keyScope"]), "Invalid desktop signing scope")
    desktop.require(0 < request["expires"] - time.time() <= 600, "The iPhone handoff request expired or the clocks differ")
    certificate = base64.b64decode(request["certificate"], validate=True)
    desktop.require(0 < len(certificate) <= 8192, "Invalid signing certificate in the request")
    return request["keyScope"], certificate


def send(repo, cache, scratch, device, team, approve=input):
    bundle = "app.zagstore.ios." + team
    target, udid = device.usb_device()

    def check_destination():
        desktop.require(device.usb_device() == (target, udid), "The trusted USB device changed")
        apps = [app for app in device.apps(target) if app.get("bundleIdentifier") == bundle]
        desktop.require(len(apps) == 1, "The selected Personal Team copy is not installed on the USB device")
        return apps[0]

    installed = check_destination()
    code = approve("Prepare the transfer in Zag Store and enter its 24-character verification code: ").strip().lower()
    desktop.require(re.fullmatch(r"[a-f0-9]{24}", code), "Handoff cancelled or verification code is invalid")
    request = scratch / "handoff-request.json"
    device.copy_from_app(target, bundle, REQUEST, request)
    item, certificate = read_request(request, code, udid, bundle, team)
    signer, openssl = cache.signer_tools(repo)
    keychain = desktop.Keychain(signer)
    leaf = hashlib.sha256(certificate).hexdigest().encode("ascii")
    receipt = keychain.read(desktop.scope("installed-leaf", udid.casefold(), team))
    desktop.require(receipt is None or receipt == leaf, "The iPhone certificate differs from the last verified desktop installation")
    desktop.require(approve(f"Transfer the existing signing key privately to {bundle}? Type HANDOFF: ") == "HANDOFF",
                    "Signing identity handoff cancelled")
    desktop.require(check_destination() == installed, "Destination inventory changed")
    read_request(request, code, udid, bundle, team)
    key = keychain.read(item)
    desktop.require(key, "The existing desktop signing key is unavailable or cannot be exported")
    public = desktop.command([openssl, "pkey", "-pubout"], key, "Check desktop signing key")
    certificate_public = desktop.command([openssl, "x509", "-inform", "DER", "-pubkey", "-noout"],
                                         certificate, "Check the iPhone signing certificate")
    desktop.require(public == certificate_public, "The desktop private key does not match the iPhone certificate")
    helper = cache.build_swift("handoff", [
        Path(__file__).with_name("DesktopHandoff.swift"),
        repo / "Feather/Utilities/ZagIdentityHandoffEnvelope.swift",
    ])
    # The RSA key travels through local pipes only. Only ciphertext is staged.
    der = desktop.command([openssl, "rsa", "-traditional", "-outform", "DER"], key, "Encode desktop RSA key")
    del key
    ciphertext = desktop.command([helper, request], der, "Encrypt signing identity for the iPhone")
    del der
    response = scratch / "handoff-response.json"
    response.write_bytes(ciphertext)
    desktop.require(check_destination() == installed, "Destination inventory changed")
    read_request(request, code, udid, bundle, team)
    device.copy_to_app(target, bundle, response, RESPONSE)
    return {"handoff_delivered": bundle, "next": "Tap Import Desktop Signing Identity in Zag Store"}
