import hashlib
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.request
import zipfile

import releases
import zag_installer as installer

TEAM = "FTB8PRW638"
DESTINATION = f"{installer.artifact.ORIGINAL}.{TEAM}"
APPTESTERS = {"bundleIdentifier": "com.cwd43.gu29"}
RELEASE = {"version": "1.0.0", "build": "4", "minimum_os": "16.4", "expires": "2099-11-01T00:00:00Z"}
INSTALLED = {"bundleIdentifier": DESTINATION, "bundleVersion": "3", "version": "1.0.0"}
URL = "https://github.com/zagorskey/zag-store-releases/releases/download/test/ZagStore.ipa"


class InstallTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.signed = self.root / "input.ipa"
        with zipfile.ZipFile(self.signed, "w") as archive:
            archive.writestr("Payload/Zag.app/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": DESTINATION, "CFBundleShortVersionString": RELEASE["version"],
                "CFBundleVersion": RELEASE["build"], "MinimumOSVersion": RELEASE["minimum_os"],
            }))
        validation = patch.object(installer.artifact, "validate", return_value={
            "bundle_identifier": DESTINATION, "build": RELEASE["build"],
        })
        self.validate = validation.start()
        self.addCleanup(validation.stop)
        self.device = Mock()
        self.device.usb_device.return_value = ("target", "hardware-udid")
        self.updated = {**INSTALLED, "bundleVersion": RELEASE["build"]}
        self.device.apps.side_effect = [[APPTESTERS], [APPTESTERS, self.updated]]

    def run_install(self, approval, installed=None):
        return installer.validate_and_install(self.signed, RELEASE, TEAM, self.root / "root.pem", self.root,
                                              self.device, "target", "hardware-udid", approval, b"leaf", installed)

    def test_verified_install_preserves_existing_app(self):
        self.assertEqual(self.run_install(lambda _: "INSTALL")["installed_bundle"], DESTINATION)
        self.assertEqual(self.validate.call_args.args[2], "hardware-udid")
        self.assertEqual(self.validate.call_args.kwargs["expected_signer"], b"leaf")
        self.device.install.assert_called_once_with("target", self.root / "staged/Payload/Zag.app")

    def test_declining_never_calls_install(self):
        with self.assertRaisesRegex(ValueError, "cancelled"):
            self.run_install(lambda _: "no")
        self.device.install.assert_not_called()

    def test_device_change(self):
        self.device.usb_device.return_value = ("other", "another")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.run_install(lambda _: "INSTALL")
        self.device.install.assert_not_called()

    def test_missing_readback_is_not_success(self):
        self.device.apps.side_effect = [[APPTESTERS], [APPTESTERS]]
        with self.assertRaisesRegex(ValueError, "did not verify"):
            self.run_install(lambda _: "INSTALL")
        self.device.install.assert_called_once()

    def test_upgrade_in_place_requires_newer_release_and_exact_confirmation(self):
        self.device.apps.side_effect = [[APPTESTERS, INSTALLED], [APPTESTERS, self.updated]]
        self.assertEqual(self.run_install(lambda _: f"UPGRADE {DESTINATION}", INSTALLED)["build"], "4")
        self.device.install.assert_called_once()
        with self.assertRaisesRegex(ValueError, "not newer"):
            installer.check_destination(self.updated, RELEASE, True)

    def test_upgrade_refuses_changed_destination(self):
        self.device.apps.side_effect = [[APPTESTERS, self.updated]]
        with self.assertRaisesRegex(ValueError, "inventory changed"):
            self.run_install(lambda _: f"UPGRADE {DESTINATION}", INSTALLED)
        self.device.install.assert_not_called()

    def test_unexpected_signed_build_blocks_install(self):
        self.validate.return_value["build"] = "999"
        with self.assertRaisesRegex(ValueError, "authorized bundle or build"):
            self.run_install(lambda _: self.fail("must not prompt"))
        self.device.install.assert_not_called()


class ReleaseTests(unittest.TestCase):
    def test_redirect_safety(self):
        redirect = releases.ReleaseRedirect()
        request = urllib.request.Request(URL)
        for bad in ("http://github.com/file", "https://evil.example/file",
                    URL.replace("/test/", "/other/"), "https://name@release-assets.githubusercontent.com/file"):
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, "redirect"):
                redirect.redirect_request(request, None, 302, "", {}, bad)

    def test_expired_release_is_refused_before_download(self):
        with patch.object(releases.urllib.request, "build_opener") as opener:
            with self.assertRaisesRegex(ValueError, "expired"):
                releases.acquire(installer.artifact, {**RELEASE, "expires": "2000-01-01T00:00:00Z"}, Path("unused"))
            opener.assert_not_called()

    def test_published_beta3_binary_fixture_if_available(self):
        # Original Phase 1 fixture pins are kept for regression only.
        source = Path.home() / "Downloads/ZagStore-1.0.0-beta.3.ipa"
        if not source.is_file():
            self.skipTest("Original Beta 3 fixture is absent")
        self.assertEqual(source.stat().st_size, 60_803_467)
        digest = "da743f30f32723ab2bb16051734caa109fd75d1fdaa292cdcb70c968d582f741"
        self.assertEqual(installer.artifact.sha(source), digest)
        with tempfile.TemporaryDirectory() as tmp, patch.object(releases.urllib.request, "build_opener") as opener:
            opener.return_value.open.side_effect = lambda *_args, **_kw: source.open("rb")
            target = Path(tmp) / "verified.ipa"
            release = {**RELEASE, "url": URL, "sha256": digest, "build": "3"}
            releases.acquire(installer.artifact, release, target)
            self.assertEqual(installer.artifact.sha(target), digest)

    def test_payload_digest_mismatch_blocks_before_archive_parsing(self):
        import io
        with tempfile.TemporaryDirectory() as tmp, patch.object(releases.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(b"wrong bytes")
            release = {**RELEASE, "url": URL, "sha256": hashlib.sha256(b"expected").hexdigest()}
            with self.assertRaisesRegex(ValueError, "digest"):
                releases.acquire(installer.artifact, release, Path(tmp) / "candidate.ipa")
