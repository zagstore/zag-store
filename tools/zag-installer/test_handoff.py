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
