import hashlib
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import zag_installer as installer

TEAM = "FTB8PRW638"
BUNDLE = "app.zagstore.ios." + TEAM
APPTESTERS = {"bundleIdentifier": "com.cwd43.gu29", "version": "1.0.0", "bundleVersion": "4"}
INSTALLED = {"bundleIdentifier": BUNDLE, "version": "1.0.0", "bundleVersion": "4"}


class LocalCandidateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.scratch = Path(directory.name)
        self.source = self.scratch / "source.ipa"
        self.device = Mock()
        self.device.usb_device.return_value = ("usb-device", "device-udid")
        self.cache = Mock()

    def make_ipa(self, path, bundle="app.zagstore.ios", version="1.0.0", build="5", profile=False):
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/Zag.app/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": bundle, "CFBundleShortVersionString": version,
                "CFBundleVersion": build, "MinimumOSVersion": "16.4",
            }))
            if profile:
                archive.writestr("Payload/Zag.app/embedded.mobileprovision", b"profile")
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def upgrade(self, digest, approve=lambda _: "1", version="1.0.0", build="5"):
        return installer.upgrade_local_candidate(self.source, digest, version, build, None,
                                                self.scratch, self.device, self.cache, approve)

    def test_wrong_digest_stops_before_device_or_authentication(self):
        self.make_ipa(self.source)
        with self.assertRaisesRegex(ValueError, "SHA-256 does not match"):
            self.upgrade("0" * 64)
        self.device.usb_device.assert_not_called()
        self.cache.installer_tools.assert_not_called()

    def test_metadata_and_unsigned_input_are_required(self):
        cases = [
            ({"bundle": "com.cwd43.gu29"}, "bundle identifier"),
            ({"version": "2.0.0"}, "version"),
            ({"build": "6"}, "build"),
            ({"profile": True}, "provisioning profile"),
        ]
        for index, (overrides, error) in enumerate(cases):
            with self.subTest(overrides=overrides):
                digest = self.make_ipa(self.source, **overrides)
                with self.assertRaisesRegex(ValueError, error):
                    installer.stage_local_candidate(self.source, self.scratch / f"staged-{index}.ipa",
                                                    digest, "1.0.0", "5")

    def test_existing_apptesters_copy_cannot_be_the_destination(self):
        self.device.apps.return_value = [APPTESTERS]
        digest = self.make_ipa(self.source)
        with self.assertRaisesRegex(ValueError, "Upgrade destination is not installed"):
            self.upgrade(digest)
        self.device.install.assert_not_called()
        self.cache.installer_tools.assert_not_called()

    def test_valid_candidate_uses_only_experimental_team_and_existing_identity(self):
        digest = self.make_ipa(self.source)
        signed = self.scratch / "signed.ipa"
        self.make_ipa(signed, bundle=BUNDLE)
        newest = {**INSTALLED, "bundleVersion": "5"}
        self.device.apps.side_effect = [[APPTESTERS, INSTALLED]] * 3 + [[APPTESTERS, newest]]
        self.cache.installer_tools.return_value = ("auth", "signer", "openssl", "anisette")
        identity = Mock(certificate=b"existing-leaf")

        def provision(portal, _):
            self.assertTrue(portal.upgrade)
            self.assertIsNone(portal.endpoint)
            self.assertEqual(portal.choose_team([
                {"id": "OTHERTEAM1", "name": "Other"},
                {"id": TEAM, "name": "Experimental"},
            ]), TEAM)
            portal.receipt_item = "receipt"
            return TEAM, identity, {"": b"profile"}

        steps = iter(["1", "PROVISION", f"UPGRADE {BUNDLE}"])
        with patch.object(installer.desktop, "Keychain"),              patch.object(installer.desktop.Provisioning, "run", provision),              patch.object(installer.desktop, "sign", return_value=signed),              patch.object(installer.artifact, "validate", return_value={"bundle_identifier": BUNDLE, "build": "5"}) as verify,              patch.object(installer.releases, "acquire") as download,              patch.object(installer.releases, "check_fresh") as production_check:
            result = self.upgrade(digest, approve=lambda _: next(steps))
        self.assertEqual(result, {"installed_bundle": BUNDLE, "version": "1.0.0", "build": "5"})
        self.assertEqual(verify.call_args.kwargs["expected_signer"], b"existing-leaf")
        self.device.install.assert_called_once_with("usb-device", self.scratch / "staged/Payload/Zag.app")
        download.assert_not_called()
        production_check.assert_not_called()
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), digest)
