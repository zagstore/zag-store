import base64
import datetime as dt
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import desktop
from test_zag_installer import RELEASE
import zag_installer as installer

TEAM = "FTB8PRW638"
BUNDLE = installer.artifact.mapped_bundle(TEAM)


class IdentityTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required")
    def test_only_matching_inventory_resolves_an_uncertain_request(self):
        def der(key):
            return subprocess.check_output(
                ["openssl", "req", "-x509", "-key", "/dev/stdin", "-subj", "/CN=Test",
                 "-days", "1", "-outform", "DER"], input=key, stderr=subprocess.DEVNULL)

        values = {}
        store = Mock()
        store.read.side_effect = values.get
        store.write.side_effect = values.__setitem__
        approve = Mock(return_value="CREATE")
        identity = desktop.Identity(store, "authenticated-account", TEAM, "openssl", approve)
        request = identity.select([])
        self.assertIn("BEGIN CERTIFICATE REQUEST", request["csr"])
        self.assertEqual(store.read(identity.pending_item), b"pending")
        other_key = subprocess.check_output(
            ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"],
            stderr=subprocess.DEVNULL)
        other = base64.b64encode(der(other_key))
        own = base64.b64encode(der(identity.key))
        restarted = desktop.Identity(store, "authenticated-account", TEAM, "openssl", approve)
        with self.assertRaisesRegex(ValueError, "unresolved"):
            restarted.select([other])
        with self.assertRaisesRegex(ValueError, "does not match"):
            restarted.bind(other)
        self.assertEqual(restarted.select([other, own]), {"index": 1})
        self.assertTrue(restarted.bind(own))
        self.assertEqual(store.read(identity.pending_item), b"")
        other_account = desktop.Identity(store, "different-account", TEAM, "openssl", approve)
        self.assertIsNone(other_account.key)
        approve.assert_called_once()


class DesktopTests(unittest.TestCase):
    def test_provider_origin_requires_verified_https_origin(self):
        self.assertEqual(desktop.provider_origin("https://ani.example/"), "https://ani.example")
        for bad in ("", "http://ani.example", "https://user:password@ani.example",
                    "https://ani.example:443", "https://ani.example/v3", "https://ani.example/?q=x"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                desktop.provider_origin(bad)

    def test_native_provision_requires_consent_and_reuses_account_state_offline(self):
        store = Mock()
        store.read.return_value = None
        approve = Mock(side_effect=["no", "ANISETTE"])
        native = desktop.NativeAnisette("helper", store, approve)
        native.item = desktop.scope("native", "one-account")
        with patch.object(desktop, "command") as command:
            with self.assertRaisesRegex(ValueError, "cancelled"):
                native.headers(prepare=True)
            command.assert_not_called()
            command.side_effect = [b'{"state":"c3RhdGU=","headers":{"source":"new"}}',
                                   b'{"headers":{"source":"offline"}}']
            self.assertEqual(native.headers(prepare=True), {"source": "new"})
            self.assertEqual(native.headers(prepare=False), {"source": "offline"})
            self.assertEqual(command.call_args.args[:2], (["helper", "headers"], b"state"))
        store.write.assert_called_once_with(native.item, b"state")

    def test_remote_selection_requires_explicit_approval_before_provider_exchange(self):
        portal = desktop.Provisioning("https://ani.example", "udid", Mock(), "openssl", Mock(),
                                      Mock(side_effect=["apple@example.invalid", "no"]))
        with self.assertRaisesRegex(ValueError, "cancelled"):
            portal.handle({"event": "configuration"})
        self.assertIsNone(portal.anisette_scope)

    def test_unknown_second_factor_requires_a_delivery_method(self):
        event = {"retry": False, "unknown": True, "sms": False,
                 "numbers": [{"id": 77, "last_two": "12"}]}
        with patch.object(desktop, "secret") as secret_input:
            self.assertEqual(desktop.two_factor(event, lambda _: "c"), {"action": "abort"})
            self.assertEqual(desktop.two_factor(event, lambda _: "1"), {"action": "sms", "id": 77})
            secret_input.assert_not_called()
        event["unknown"] = False
        with patch.object(desktop, "secret", return_value="012345"):
            self.assertEqual(desktop.two_factor(event, lambda _: "c"),
                             {"action": "code", "code": "012345"})

    def test_profile_must_cover_exact_app_device_key_and_entitlements(self):
        identifier = f"{TEAM}.{BUNDLE}"
        profile = {
            "LocalProvision": True, "TeamIdentifier": [TEAM],
            "DeveloperCertificates": [b"certificate"], "ProvisionedDevices": ["udid"],
            "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1),
            "Entitlements": {"application-identifier": identifier,
                             "com.apple.developer.team-identifier": TEAM, "get-task-allow": True,
                             "keychain-access-groups": [f"{TEAM}.*"]},
        }
        check = desktop.personal_entitlements
        self.assertEqual(check(installer.artifact, profile, b"certificate", TEAM, "UDID")
                         ["keychain-access-groups"], [identifier])
        for change in ({"LocalProvision": False}, {"TeamIdentifier": ["wrong"]},
                       {"ProvisionedDevices": ["wrong"]}, {"DeveloperCertificates": [b"wrong"]},
                       {"Entitlements": {"application-identifier": identifier}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                check(installer.artifact, {**profile, **change}, b"certificate", TEAM, "udid")

    def test_occupied_destination_blocks_before_any_portal_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            scratch = Path(folder)
            source = scratch / "input.ipa"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("Payload/Zag.app/Info.plist", plistlib.dumps({
                    "CFBundleIdentifier": installer.artifact.ORIGINAL,
                }))
            root = scratch / "root.pem"
            root.write_text("mock certificate")
            device = Mock()
            device.usb_device.return_value = ("device", "udid")
            device.apps.return_value = [{"bundleIdentifier": BUNDLE}]

            def run_portal(portal, _):
                portal.handle({"event": "team", "account": "account",
                               "teams": [{"id": TEAM, "name": "Personal Team"}]})
                self.fail("occupied destination was authorized")

            cache = Mock()
            cache.installer_tools.return_value = ("auth", "signer", "openssl", None)
            def acquire(_, _release, destination):
                shutil.copyfile(source, destination)

            with patch.object(installer.releases, "acquire", side_effect=acquire), \
                 patch.object(desktop, "verify_root"), patch.object(desktop.Provisioning, "run", run_portal), \
                 patch.object(desktop, "sign") as sign:
                with self.assertRaisesRegex(ValueError, "already installed"):
                    installer.install_release(RELEASE, root, "https://ani.example", None, scratch, device, cache,
                                              approve=lambda _: "1")
                device.install.assert_not_called()
                sign.assert_not_called()

    def test_signing_validation_failure_prevents_installation(self):
        device = Mock()
        with patch.object(installer.artifact, "validate", side_effect=ValueError("invalid signature")):
            with self.assertRaisesRegex(ValueError, "invalid signature"):
                installer.validate_and_install(Path("signed"), RELEASE, TEAM, Path("root"), Path("."), device,
                                               "target", "udid", Mock(), b"leaf")
        device.install.assert_not_called()

    def test_upgrade_refuses_to_create_a_new_certificate(self):
        store = Mock()
        store.read.return_value = None
        approve = Mock()
        identity = desktop.Identity(store, "account", TEAM, "openssl", approve, upgrade=True)
        with self.assertRaisesRegex(ValueError, "existing local signing key"):
            identity.select([])
        approve.assert_not_called()
        store.write.assert_not_called()

    def test_extensions_keep_their_identifier_suffix(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder)
            extension = app / "PlugIns/Widget.appex"
            extension.mkdir(parents=True)
            info = extension / "Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "app.zagstore.ios.widgets.home"}))
            self.assertEqual(desktop.signing_components(app, "app.zagstore.ios"),
                             {"": "", "PlugIns/Widget.appex": ".widgets.home"})
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.app.widget"}))
            with self.assertRaisesRegex(ValueError, "does not belong"):
                desktop.signing_components(app, "app.zagstore.ios")
