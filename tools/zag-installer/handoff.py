"""Explicit USB handoff of the existing desktop signing identity."""

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import time
import uuid
import subprocess

import desktop

MAX_SIZE = 16 * 1024
REQUEST = "Documents/ZagIdentityHandoffRequest.json"
RESPONSE = "Documents/ZagIdentityHandoffResponse.json"
BOOTSTRAP = "Library/Caches/ZagSetupBootstrap.json"
SETUP_REQUEST = "Library/Caches/ZagSetupRequest.json"
SETUP_RESPONSE = "Library/Caches/ZagSetupResponse.json"
ACKNOWLEDGEMENT = "Library/Caches/ZagSetupAcknowledgement.json"
MAX_WIRE_SIZE = 24 * 1024


def private_write(path, content):
    """Create an exclusive mode-0600 message file before invoking native AFC.

    The automatic bootstrap contains a 32-byte transaction secret. It must
    never be staged with default 0644 file permissions.
    """
    if not isinstance(content, bytes) or not 0 < len(content) <= MAX_WIRE_SIZE:
        raise ValueError("Invalid private setup message size")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as destination:
            destination.write(content)
            destination.flush()
            os.fsync(destination.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise



def read_request(path, code, udid, bundle, team):
    with path.open("rb") as stream:
        raw = stream.read(MAX_SIZE + 1)
    desktop.require(0 < len(raw) <= MAX_SIZE, "Invalid iPhone handoff request size")
    expected_code = hashlib.sha256(raw).hexdigest()[:24]
    desktop.require(hmac.compare_digest(code, expected_code), "The iPhone verification code does not match this request")
    return validate_request(raw, udid, bundle, team)


def validate_request(raw, udid, bundle, team):
    request = json.loads(raw)
    desktop.require(request["protocolVersion"] == 1 and request["udid"].casefold() == udid.casefold()
                    and request["bundle"] == bundle and request["team"] == team,
                    "The handoff request is for a different device, bundle or team")
    desktop.require(re.fullmatch(r"[0-9a-f]{64}", request["keyScope"]), "Invalid desktop signing scope")
    desktop.require(0 < request["expires"] - time.time() <= 600, "The iPhone handoff request expired or the clocks differ")
    certificate = base64.b64decode(request["certificate"], validate=True)
    desktop.require(0 < len(certificate) <= 8192, "Invalid signing certificate in the request")
    return request["keyScope"], certificate


def exact_destination(device, target, bundle):
    # Native Installation Proxy can omit development apps in broad inventory.
    # Use the exact targeted lookup when the adapter supports it; never infer
    # installation from a receipt or from the presence of the legacy copy.
    lookup = getattr(type(device), "destination_app", None)
    if callable(lookup):
        app = lookup(device, target, bundle)
        return [app] if app is not None else []
    return [app for app in device.apps(target) if app.get("bundleIdentifier") == bundle]


def send(repo, cache, scratch, device, team, approve=input):
    bundle = "app.zagstore.ios." + team
    target, udid = device.usb_device()

    def check_destination():
        desktop.require(device.usb_device() == (target, udid), "The trusted USB device changed")
        apps = exact_destination(device, target, bundle)
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
    verify_key(openssl, key, certificate)
    ciphertext = encrypt(repo, cache, openssl, request, key)
    del key
    response = scratch / "handoff-response.json"
    private_write(response, ciphertext)
    desktop.require(check_destination() == installed, "Destination inventory changed")
    read_request(request, code, udid, bundle, team)
    device.copy_to_app(target, bundle, response, RESPONSE)
    return {"handoff_delivered": bundle, "next": "Tap Import Desktop Signing Identity in Zag Store"}


def verify_key(openssl, key, certificate):
    public = desktop.command([openssl, "pkey", "-pubout"], key, "Check desktop signing key")
    certificate_public = desktop.command([openssl, "x509", "-inform", "DER", "-pubkey", "-noout"],
                                         certificate, "Check the iPhone signing certificate")
    desktop.require(public == certificate_public, "The desktop private key does not match the iPhone certificate")

def encrypt_payload(repo, cache, request, payload):
    desktop.require(isinstance(payload, bytes) and 0 < len(payload) <= 4096, "Invalid encrypted setup payload")
    helper = cache.build_swift("handoff", [
        Path(__file__).with_name("DesktopHandoff.swift"),
        repo / "Feather/Utilities/ZagIdentityHandoffEnvelope.swift",
    ])
    return desktop.command([helper, request], payload, "Encrypt private setup payload for the iPhone")


def encrypt(repo, cache, openssl, request, key):
    # The RSA key travels through local pipes only. Only ciphertext is staged.
    der = desktop.command([openssl, "rsa", "-traditional", "-outform", "DER"], key, "Encode desktop RSA key")
    ciphertext = encrypt_payload(repo, cache, request, der)
    del der
    return ciphertext


def mac(secret, transaction, label, payload):
    domain = f"Zag Store USB setup v1\n{transaction}\n{label}\n".encode()
    return hmac.digest(secret, domain + payload, "sha256")


def wrap(secret, transaction, label, payload):
    return json.dumps({"payload": base64.b64encode(payload).decode(),
                       "tag": base64.b64encode(mac(secret, transaction, label, payload)).decode()}).encode()


def unwrap(secret, transaction, label, wire):
    desktop.require(len(wire) <= MAX_WIRE_SIZE, "Setup message exceeds size limit")
    message = json.loads(wire)
    payload = base64.b64decode(message["payload"], validate=True)
    tag = base64.b64decode(message["tag"], validate=True)
    desktop.require(len(payload) <= MAX_SIZE and hmac.compare_digest(tag, mac(secret, transaction, label, payload)),
                    "Setup message authentication failed")
    return payload


def receipt_scope(udid, team):
    return desktop.scope("automatic-setup-v1", udid.casefold(), team)


def save_receipt(store, udid, team, item, certificate, result):
    store.write(receipt_scope(udid, team), json.dumps({
        "scope": item, "certificate": base64.b64encode(certificate).decode(),
        "version": result["version"], "build": result["build"],
    }).encode())


def retry(repo, cache, scratch, device, team):
    target, udid = device.usb_device()
    bundle = "app.zagstore.ios." + team
    installed = exact_destination(device, target, bundle)
    desktop.require(len(installed) == 1, "The selected Personal Team copy is not installed on the USB device")
    signer, openssl = cache.signer_tools(repo)
    store = desktop.Keychain(signer)
    saved = store.read(receipt_scope(udid, team))
    desktop.require(saved is not None, "No automatic setup receipt. Use the manual handoff recovery command.")
    receipt = json.loads(saved)
    desktop.require(re.fullmatch(r"[a-f0-9]{64}", receipt["scope"]) and installed[0].get("version") == receipt["version"]
                    and installed[0].get("bundleVersion") == receipt["build"], "The installed app does not match the setup receipt")
    certificate = base64.b64decode(receipt["certificate"], validate=True)
    leaf = store.read(desktop.scope("installed-leaf", udid.casefold(), team))
    desktop.require(leaf == hashlib.sha256(certificate).hexdigest().encode(), "The original signing receipt does not match")
    key = store.read(receipt["scope"])
    desktop.require(key, "The existing desktop signing key is unavailable")
    verify_key(openssl, key, certificate)
    return automatic(repo, cache, scratch, device, target, udid, team, receipt["scope"], certificate, key, openssl, installed[0])


def automatic(repo, cache, scratch, device, target, udid, team, item, certificate, key, openssl,
              installed, notify=print, *, account_credential=None):
    """Shared desktop rendezvous. The device adapter supplies paired USB I/O."""
    bundle = "app.zagstore.ios." + team

    def check_target():
        desktop.require(device.usb_device() == (target, udid), "Reconnect the original trusted iPhone")
        matches = exact_destination(device, target, bundle)
        desktop.require(matches == [installed], "The installed Personal Team copy changed")

    def poll(paths):
        local = scratch / "setup-inbound"
        next_progress = time.monotonic() + 60
        while time.monotonic() < deadline:
            for remote, labels in paths:
                local.unlink(missing_ok=True)
                try:
                    device.copy_from_app(target, bundle, remote, local)
                    with local.open("rb") as stream:
                        wire = stream.read(MAX_WIRE_SIZE + 1)
                except (OSError, ValueError, subprocess.SubprocessError):
                    continue
                for label in labels:
                    try:
                        payload = unwrap(secret, transaction, label, wire)
                    except (ValueError, KeyError, TypeError):
                        continue
                    if label == "cancelled":
                        raise ValueError("Signing Setup was cancelled on the iPhone.")
                    return label, payload
            # Stale and incomplete messages permit no key transfer.
            if time.monotonic() >= next_progress:
                notify("Still awaiting iPhone Signing Setup. Open the Personal Team copy and follow its instructions.")
                next_progress = time.monotonic() + 60
            time.sleep(2)
        raise ValueError("iPhone setup did not complete. Reconnect and use setup to retry.")

    if account_credential is not None:
        desktop.require(isinstance(account_credential, bytes) and 0 < len(account_credential) <= 4096,
                        "Invalid portable developer credential")
        try:
            credential = json.loads(account_credential)["token"]
            desktop.require(desktop.scope("signing-key", credential["accountID"], team) == item
                            and type(credential["expiresAtMs"]) is int
                            and credential["expiresAtMs"] > int(time.time() * 1000),
                            "Portable credential does not match this signing account")
        except (KeyError, TypeError, ValueError):
            raise ValueError("Invalid or expired portable developer credential") from None
        finally:
            credential = None
    try:
        secret = secrets.token_bytes(32)
        transaction = str(uuid.uuid4())
        deadline = time.monotonic() + 600
        bootstrap = scratch / "setup-bootstrap.json"
        try:
            check_target()
            private_write(bootstrap, json.dumps({
                "id": transaction, "expires": time.time() + 600, "secret": base64.b64encode(secret).decode(),
                "udid": udid, "bundle": bundle, "team": team, "keyScope": item,
                "certificate": base64.b64encode(certificate).decode(),
                "accountTransfer": account_credential is not None,
            }).encode())
            device.copy_to_app(target, bundle, bootstrap, BOOTSTRAP)
            notify("Verified USB bootstrap delivery to the installed Personal Team app.")
        finally:
            bootstrap.unlink(missing_ok=True)
        try:
            device.launch_app(target, bundle)
        except (ValueError, subprocess.SubprocessError):
            notify("Unlock the iPhone and open the newly installed Zag Store.")
        notify("Complete any prerequisites on the iPhone and authorize Signing Setup there.")
        notify("Local installation pairing may still be required for renewal. Do not change pairing in the AppTesters copy.")
        labels = ("request", "account-request") if account_credential is not None else ("request",)
        phase, request_bytes = poll([(SETUP_REQUEST, labels), (ACKNOWLEDGEMENT, ("existing", "cancelled"))])
        if phase == "account-request":
            scope, leaf = validate_request(request_bytes, udid, bundle, team)
            desktop.require(scope == item and leaf == certificate, "Account request does not match the installed signing identity")
            check_target()
            account_request = scratch / "account-setup-request.json"
            account_response = scratch / "account-setup-response.json"
            try:
                private_write(account_request, request_bytes)
                ciphertext = encrypt_payload(repo, cache, account_request, account_credential)
                private_write(account_response, wrap(secret, transaction, "account-response", ciphertext))
                while time.monotonic() < deadline:
                    try:
                        check_target()
                        device.copy_to_app(target, bundle, account_response, SETUP_RESPONSE)
                        break
                    except (OSError, ValueError, subprocess.SubprocessError):
                        time.sleep(2)
                else:
                    raise ValueError("Could not deliver the encrypted Apple ID session")
                notify("Encrypted Apple ID session delivered. Zag Store will validate it with Apple.")
            finally:
                account_request.unlink(missing_ok=True)
                account_response.unlink(missing_ok=True)
                account_credential = None
            phase, request_bytes = poll([(SETUP_REQUEST, ("request",)), (ACKNOWLEDGEMENT, ("existing", "cancelled"))])
        if phase == "existing":
            desktop.require(hmac.compare_digest(request_bytes, hashlib.sha256(certificate).digest()),
                            "Existing setup acknowledgement does not match the installed certificate")
            check_target()
            return {"signing_setup": "verified"}
        scope, leaf = validate_request(request_bytes, udid, bundle, team)
        desktop.require(scope == item and leaf == certificate, "Setup request does not match the installed signing identity")
        check_target()
        request = scratch / "setup-request.json"
        private_write(request, request_bytes)
        response = scratch / "setup-response.json"
        private_write(response, wrap(secret, transaction, "response", encrypt(repo, cache, openssl, request, key)))

        # Retry delivery after a transient disconnect, using the same authenticated
        # response. The iPhone consumes the request before importing it.
        while time.monotonic() < deadline:
            try:
                check_target()
                device.copy_to_app(target, bundle, response, SETUP_RESPONSE)
                break
            except (OSError, ValueError, subprocess.SubprocessError):
                time.sleep(2)
        else:
            raise ValueError("Could not deliver the signing identity. Reconnect and use setup to retry.")

        completion, acknowledgement = poll([(ACKNOWLEDGEMENT, ("verified", "imported", "cancelled"))])
        desktop.require(hmac.compare_digest(acknowledgement, hashlib.sha256(request_bytes).digest()),
                        "The completion acknowledgement is for a different request")
        check_target()
        if completion == "imported":
            notify("Signing identity imported. Local installation ownership verification is still pending.")
            return {"signing_setup": "incomplete", "signing_identity": "imported"}
        return {"signing_setup": "verified"}
    finally:
        account_credential = None
        for name in ("setup-bootstrap.json", "setup-inbound", "account-setup-request.json",
                     "account-setup-response.json", "setup-request.json", "setup-response.json"):
            (scratch / name).unlink(missing_ok=True)
