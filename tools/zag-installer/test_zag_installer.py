import hashlib
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import zag_installer as installer

TEAM = "FTB8PRW638"
DESTINATION = f"{installer.artifact.ORIGINAL}.{TEAM}"
APPTESTERS = {"bundleIdentifier": "com.cwd43.gu29"}


class InstallTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.signed = self.root / "input.ipa"
        with zipfile.ZipFile(self.signed, "w") as archive:
            archive.writestr("Payload/Zag.app/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": DESTINATION,
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "3",
            }))
        digest = patch.object(installer, "SIGNED_TEST_DIGEST", hashlib.sha256(self.signed.read_bytes()).hexdigest())
        digest.start()
        self.addCleanup(digest.stop)
        validation = patch.object(installer.artifact, "validate", return_value={
            "bundle_identifier": DESTINATION, "build": "3",
        })
        self.validate = validation.start()
        self.addCleanup(validation.stop)
        self.device = Mock()
        self.device.usb_device.return_value = ("target", "hardware-udid")
        self.device.apps.side_effect = [[APPTESTERS], [APPTESTERS], [
            APPTESTERS, {"bundleIdentifier": DESTINATION, "bundleVersion": "3", "version": "1.0.0"},
        ]]

    def run_install(self, approval):
        return installer.install_signed(self.signed, TEAM, self.root / "root.pem", self.root,
                                        self.device, approve=approval)

    def test_verified_install_preserves_existing_app(self):
        self.assertEqual(self.run_install(lambda _: "INSTALL")["installed_bundle"], DESTINATION)
        self.assertEqual(self.validate.call_args.args[2], "hardware-udid")
        self.device.install.assert_called_once_with("target", self.root / "staged/Payload/Zag.app")

    def test_declining_never_calls_install(self):
        with self.assertRaisesRegex(ValueError, "cancelled"):
            self.run_install(lambda _: "no")
        self.device.install.assert_not_called()

    def test_existing_target_is_refused(self):
        self.device.apps.side_effect = [[APPTESTERS, {"bundleIdentifier": DESTINATION}]]
        with self.assertRaisesRegex(ValueError, "already installed"):
            self.run_install(lambda _: self.fail("must not prompt"))
        self.validate.assert_not_called()
        self.device.install.assert_not_called()

    def test_device_change(self):
        self.device.usb_device.side_effect = [("target", "hardware-udid"), ("other", "another")]
        with self.assertRaisesRegex(ValueError, "changed"):
            self.run_install(lambda _: "INSTALL")
        self.device.install.assert_not_called()

    def test_missing_readback_is_not_success(self):
        self.device.apps.side_effect = [[APPTESTERS], [APPTESTERS], [APPTESTERS]]
        with self.assertRaisesRegex(ValueError, "did not verify"):
            self.run_install(lambda _: "INSTALL")
        self.device.install.assert_called_once()

    def test_modified_signed_artifact_is_rejected(self):
        with self.signed.open("ab") as stream:
            stream.write(b"changed")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.run_install(lambda _: self.fail("must not prompt"))
        self.validate.assert_not_called()
        self.device.install.assert_not_called()

    def test_non_https_redirect_rejected(self):
        with self.assertRaisesRegex(ValueError, "redirect"):
            installer.ReleaseRedirect().redirect_request(None, None, 302, "", {}, "http://github.com/file")


if __name__ == "__main__":
    unittest.main()
