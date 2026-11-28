import base64
import hashlib
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import desktop
import handoff

TEAM = "FTB8PRW638"
UDID = "00008020-0123456789ABCDEF"
BUNDLE = f"app.zagstore.ios.{TEAM}"


class HandoffTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.scratch = Path(temporary.name)
        self.request = self.scratch / "request.json"
        self.leaf = b"running-certificate"
        self.scope = desktop.scope("signing-key", "12345", TEAM)
        self.device = Mock()
        self.device.usb_device.return_value = ("target", UDID)
        self.device.apps.return_value = [{"bundleIdentifier": "com.cwd43.gu29"}, {"bundleIdentifier": BUNDLE}]
        self.cache = Mock()
        self.cache.signer_tools.return_value = ("signer", "openssl")
        self.cache.build_swift.return_value = "crypto"
        self.store = Mock()
        self.store.read.side_effect = lambda key: (
            b"desktop-key" if key == self.scope else hashlib.sha256(self.leaf).hexdigest().encode()
        )

    def request_bytes(self, **changes):
        return json.dumps({
            "protocolVersion": 1, "bundle": BUNDLE, "team": TEAM, "udid": UDID,
            "keyScope": self.scope, "expires": time.time() + 300,
            "certificate": base64.b64encode(self.leaf).decode(), **changes,
        }).encode()

    def send(self, raw, replies=None, commands=None):
        self.device.copy_from_app.side_effect = lambda *args: args[-1].write_bytes(raw)
        answers = iter(replies or [hashlib.sha256(raw).hexdigest()[:24], "HANDOFF"])
        with patch.object(desktop, "Keychain", return_value=self.store), \
             patch.object(desktop, "command", side_effect=commands or [b"same-public", b"same-public", b"DER", b"ciphertext"]):
            return handoff.send(Path("."), self.cache, self.scratch, self.device, TEAM, lambda _: next(answers))

    def test_private_handoff_files_are_exclusive_mode_0600(self):
        target = self.scratch / "private-bootstrap.json"
        handoff.private_write(target, b"transaction-secret")
        self.assertEqual(target.read_bytes(), b"transaction-secret")
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            handoff.private_write(target, b"second")
        self.assertEqual(target.read_bytes(), b"transaction-secret")
        for invalid in (b"", b"x" * (handoff.MAX_WIRE_SIZE + 1)):
            with self.assertRaises(ValueError):
                handoff.private_write(self.scratch / "invalid.json", invalid)

    def test_private_handoff_refuses_symlinks(self):
        original = self.scratch / "original"
        original.write_bytes(b"keep")
        target = self.scratch / "link"
        target.symlink_to(original)
        with self.assertRaises(FileExistsError):
            handoff.private_write(target, b"secret")
        self.assertEqual(original.read_bytes(), b"keep")

    def test_same_scoped_identity_goes_only_to_the_experimental_app_as_ciphertext(self):
        result = self.send(self.request_bytes())
        self.assertEqual(result["handoff_delivered"], BUNDLE)
        sent = self.scratch / "handoff-response.json"
        self.assertEqual(sent.read_bytes(), b"ciphertext")
        self.device.copy_to_app.assert_called_once_with("target", BUNDLE, sent, handoff.RESPONSE)
        self.assertEqual(self.store.read.call_args.args, (self.scope,))
        self.store.write.assert_not_called()

    def test_refuses_wrong_device_team_bundle_and_expired_request(self):
        for fields in ({"udid": "0" * 40}, {"team": "WRONGTEAM1"}, {"bundle": "com.cwd43.gu29"},
                       {"expires": time.time() - 1}):
            with self.subTest(fields=fields):
                with self.assertRaises(ValueError):
                    self.send(self.request_bytes(**fields))
        self.cache.signer_tools.assert_not_called()
        self.device.copy_to_app.assert_not_called()

    def test_code_mismatch_never_reads_a_key(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.send(self.request_bytes(), replies=["0" * 24])
        self.store.read.assert_not_called()
        self.device.copy_to_app.assert_not_called()

    def test_mismatched_key_and_unavailable_scope_never_send(self):
        with self.assertRaisesRegex(ValueError, "private key does not match"):
            self.send(self.request_bytes(), commands=[b"key-public", b"wrong-public"])
        self.store.read.side_effect = lambda _: None
        with self.assertRaisesRegex(ValueError, "unavailable"):
            self.send(self.request_bytes(keyScope=desktop.scope("signing-key", "other-account", TEAM)))
        self.device.copy_to_app.assert_not_called()

    def test_cancel_or_interrupted_read_never_exports_key(self):
        raw = self.request_bytes()
        with self.assertRaisesRegex(ValueError, "cancelled"):
            self.send(raw, replies=[hashlib.sha256(raw).hexdigest()[:24], "cancel"])
        self.assertNotIn(self.scope, [call.args[0] for call in self.store.read.call_args_list])
        self.device.copy_to_app.assert_not_called()


    def test_automatic_setup_authenticates_request_response_and_completion(self):
        from types import SimpleNamespace
        state = SimpleNamespace(sent=False, delivery_attempts=0)

        def copy_to(target, bundle, local, remote):
            self.assertEqual((target, bundle), ("target", BUNDLE))
            if remote == handoff.BOOTSTRAP:
                state.bootstrap = json.loads(local.read_bytes())
                state.secret = base64.b64decode(state.bootstrap["secret"])
                state.request = self.request_bytes(expires=state.bootstrap["expires"] - 10)
            elif remote == handoff.SETUP_RESPONSE:
                state.delivery_attempts += 1
                if state.delivery_attempts == 1:
                    raise ValueError("USB disconnected")
                self.assertEqual(handoff.unwrap(state.secret, state.bootstrap["id"], "response", local.read_bytes()),
                                 b"ciphertext")
                state.sent = True

        def copy_from(target, bundle, remote, local):
            self.assertEqual((target, bundle), ("target", BUNDLE))
            if remote == handoff.SETUP_REQUEST:
                local.write_bytes(handoff.wrap(state.secret, state.bootstrap["id"], "request", state.request))
            elif remote == handoff.ACKNOWLEDGEMENT:
                self.assertTrue(state.sent)
                digest = hashlib.sha256(state.request).digest()
                local.write_bytes(handoff.wrap(state.secret, state.bootstrap["id"], "verified", digest))

        self.device.copy_to_app.side_effect = copy_to
        self.device.copy_from_app.side_effect = copy_from
        with patch.object(handoff, "encrypt", return_value=b"ciphertext") as encrypt, \
             patch.object(handoff.time, "sleep") as wait:
            result = handoff.automatic(Path("."), self.cache, self.scratch, self.device, "target", UDID, TEAM,
                                       self.scope, self.leaf, b"existing-key", "openssl",
                                       {"bundleIdentifier": BUNDLE}, notify=Mock())
        self.assertEqual(result, {"signing_setup": "verified"})
        self.device.launch_app.assert_called_once_with("target", BUNDLE)
        self.assertFalse((self.scratch / "setup-bootstrap.json").exists())
        encrypt.assert_called_once()
        wait.assert_called_once_with(2)
        self.assertEqual(state.delivery_attempts, 2)

    def test_imported_identity_does_not_claim_renewal_verification(self):
        state = {}
        def copy_to(target, bundle, local, remote):
            self.assertEqual((target, bundle), ("target", BUNDLE))
            if remote == handoff.BOOTSTRAP:
                bootstrap = json.loads(local.read_bytes())
                state["id"] = bootstrap["id"]
                state["secret"] = base64.b64decode(bootstrap["secret"])
                state["request"] = self.request_bytes(expires=bootstrap["expires"] - 10)
            else:
                self.assertEqual(remote, handoff.SETUP_RESPONSE)
        def copy_from(target, bundle, remote, local):
            self.assertEqual((target, bundle), ("target", BUNDLE))
            if remote == handoff.SETUP_REQUEST:
                label, payload = "request", state["request"]
            else:
                self.assertEqual(remote, handoff.ACKNOWLEDGEMENT)
                label, payload = "imported", hashlib.sha256(state["request"]).digest()
            local.write_bytes(handoff.wrap(state["secret"], state["id"], label, payload))
        self.device.copy_to_app.side_effect = copy_to
        self.device.copy_from_app.side_effect = copy_from
        with patch.object(handoff, "encrypt", return_value=b"ciphertext"):
            result = handoff.automatic(Path("."), self.cache, self.scratch, self.device,
                                       "target", UDID, TEAM, self.scope, self.leaf,
                                       b"existing-key", "openssl", {"bundleIdentifier": BUNDLE}, notify=Mock())
        self.assertEqual(result, {"signing_setup": "incomplete", "signing_identity": "imported"})

    def test_account_candidate_has_a_separate_authenticated_exchange(self):
        state = {"phase": "account-request"}
        credential = json.dumps({"token": {"accountID": "12345", "token": "synthetic",
                                            "expiresAtMs": int((time.time() + 300) * 1000)}}).encode()
        def copy_to(target, bundle, local, remote):
            self.assertEqual((target, bundle), ("target", BUNDLE))
            if remote == handoff.BOOTSTRAP:
                bootstrap = json.loads(local.read_bytes())
                self.assertTrue(bootstrap["accountTransfer"])
                self.assertNotIn(credential, local.read_bytes())
                state["id"] = bootstrap["id"]
                state["secret"] = base64.b64decode(bootstrap["secret"])
                state["account"] = self.request_bytes(expires=bootstrap["expires"] - 10)
                state["signing"] = self.request_bytes(expires=bootstrap["expires"] - 10, nonce="new")
            elif state["phase"] == "account-request":
                self.assertEqual(remote, handoff.SETUP_RESPONSE)
                self.assertEqual(handoff.unwrap(state["secret"], state["id"], "account-response",
                                                local.read_bytes()), b"encrypted-account")
                state["phase"] = "request"
            else:
                self.assertEqual(remote, handoff.SETUP_RESPONSE)
                self.assertEqual(handoff.unwrap(state["secret"], state["id"], "response",
                                                local.read_bytes()), b"encrypted-key")
                state["phase"] = "imported"
        def copy_from(target, bundle, remote, local):
            self.assertEqual((target, bundle), ("target", BUNDLE))
            phase = state["phase"]
            if phase == "imported":
                self.assertEqual(remote, handoff.ACKNOWLEDGEMENT)
                payload = hashlib.sha256(state["signing"]).digest()
            else:
                self.assertEqual(remote, handoff.SETUP_REQUEST)
                payload = state["account" if phase == "account-request" else "signing"]
            local.write_bytes(handoff.wrap(state["secret"], state["id"], phase, payload))
        self.device.copy_to_app.side_effect = copy_to
        self.device.copy_from_app.side_effect = copy_from
        with patch.object(handoff, "encrypt_payload", return_value=b"encrypted-account") as seal, \
             patch.object(handoff, "encrypt", return_value=b"encrypted-key"):
            result = handoff.automatic(Path("."), self.cache, self.scratch, self.device,
                                       "target", UDID, TEAM, self.scope, self.leaf, b"existing-key",
                                       "openssl", {"bundleIdentifier": BUNDLE}, notify=Mock(),
                                       account_credential=credential)
        self.assertEqual(result, {"signing_setup": "incomplete", "signing_identity": "imported"})
        seal.assert_called_once()
        self.assertEqual(seal.call_args.args[-1], credential)
        self.assertFalse((self.scratch / "account-setup-request.json").exists())
        self.assertFalse((self.scratch / "account-setup-response.json").exists())

    def test_wrong_account_candidate_is_never_delivered(self):
        credential = json.dumps({"token": {"accountID": "99999", "token": "synthetic",
                                            "expiresAtMs": int((time.time() + 300) * 1000)}}).encode()
        with self.assertRaisesRegex(ValueError, "portable developer credential"):
            handoff.automatic(Path("."), self.cache, self.scratch, self.device,
                              "target", UDID, TEAM, self.scope, self.leaf, b"key",
                              "openssl", {"bundleIdentifier": BUNDLE}, notify=Mock(),
                              account_credential=credential)
        self.device.copy_to_app.assert_not_called()

    def test_automatic_wire_rejects_tampering_replay_and_unrelated_phase(self):
        secret = b"1" * 32
        wire = handoff.wrap(secret, "original", "request", b"payload")
        changed = json.loads(wire)
        changed["payload"] = base64.b64encode(b"changed").decode()
        for transaction, phase, candidate in (
            ("original", "request", json.dumps(changed).encode()),
            ("different", "request", wire),
            ("original", "verified", wire),
        ):
            with self.subTest(transaction=transaction, phase=phase), self.assertRaisesRegex(ValueError, "authentication"):
                handoff.unwrap(secret, transaction, phase, candidate)

    def test_existing_and_cancelled_setup_skip_private_key_delivery(self):
        from types import SimpleNamespace
        for label in ("existing", "cancelled"):
            with self.subTest(label=label):
                state = SimpleNamespace()

                def copy_to(_target, _bundle, local, remote):
                    self.assertEqual(remote, handoff.BOOTSTRAP)
                    state.bootstrap = json.loads(local.read_bytes())
                    state.secret = base64.b64decode(state.bootstrap["secret"])

                def copy_from(_target, _bundle, remote, local):
                    if remote == handoff.SETUP_REQUEST:
                        raise ValueError("No new request")
                    self.assertEqual(remote, handoff.ACKNOWLEDGEMENT)
                    digest = hashlib.sha256(self.leaf).digest() if label == "existing" else b""
                    local.write_bytes(handoff.wrap(state.secret, state.bootstrap["id"], label, digest))

                self.device.copy_to_app.side_effect = copy_to
                self.device.copy_from_app.side_effect = copy_from

                def setup():
                    return handoff.automatic(Path("."), self.cache, self.scratch, self.device, "target", UDID, TEAM,
                                             self.scope, self.leaf, b"existing-key", "openssl",
                                             {"bundleIdentifier": BUNDLE}, notify=Mock())

                with patch.object(handoff, "encrypt") as encrypt:
                    if label == "existing":
                        self.assertEqual(setup(), {"signing_setup": "verified"})
                    else:
                        with self.assertRaisesRegex(ValueError, "cancelled on the iPhone"):
                            setup()
                    encrypt.assert_not_called()
