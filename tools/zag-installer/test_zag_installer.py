import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
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
    def test_download_origin_is_restricted_to_release_assets(self):
        self.assertEqual(releases.release_tag(URL), "test")
        for bad in ("http://github.com/file", "https://evil.example/file", URL + "?token=redacted",
                    "https://name@release-assets.githubusercontent.com/file"):
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, "release"):
                releases.release_tag(bad)

    def test_only_structured_helper_diagnostics_are_displayed(self):
        with patch.object(releases.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 1, b"",
                b'{"message":"Official IPA download: TLS verification failed."}')
            with self.assertRaisesRegex(ValueError, "TLS verification failed"):
                releases.run_helper(["helper"], 5, "Official IPA download")
            run.return_value = subprocess.CompletedProcess([], 1, b"", b"raw URL and server credentials")
            with self.assertRaisesRegex(ValueError, "^Official IPA download failed$"):
                releases.run_helper(["helper"], 5, "Official IPA download")
            run.side_effect = subprocess.TimeoutExpired(["helper", "private URL"], 5)
            with self.assertRaisesRegex(ValueError, "^Official IPA download timed out"):
                releases.run_helper(["helper"], 5, "Official IPA download")

    def test_expired_release_is_refused_before_download(self):
        with patch.object(releases, "run_helper") as transfer:
            with self.assertRaisesRegex(ValueError, "expired"):
                releases.acquire(installer.artifact, {**RELEASE, "expires": "2000-01-01T00:00:00Z"},
                                 "helper", Path("unused"))
            transfer.assert_not_called()

    def test_published_beta3_binary_fixture_if_available(self):
        # Original Phase 1 fixture pins are kept for regression only.
        source = Path.home() / "Downloads/ZagStore-1.0.0-beta.3.ipa"
        if not source.is_file():
            self.skipTest("Original Beta 3 fixture is absent")
        self.assertEqual(source.stat().st_size, 60_803_467)
        digest = "da743f30f32723ab2bb16051734caa109fd75d1fdaa292cdcb70c968d582f741"
        self.assertEqual(installer.artifact.sha(source), digest)
        with tempfile.TemporaryDirectory() as tmp, patch.object(releases, "run_helper") as transfer:
            transfer.side_effect = lambda args, *_: shutil.copyfile(source, args[-1])
            target = Path(tmp) / "verified.ipa"
            release = {**RELEASE, "url": URL, "sha256": digest, "build": "3"}
            releases.acquire(installer.artifact, release, "helper", target)
            self.assertEqual(installer.artifact.sha(target), digest)

    def test_payload_digest_mismatch_blocks_before_archive_parsing(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(releases, "run_helper") as transfer:
            transfer.side_effect = lambda args, *_: args[-1].write_bytes(b"wrong bytes")
            release = {**RELEASE, "url": URL, "sha256": hashlib.sha256(b"expected").hexdigest()}
            with self.assertRaisesRegex(ValueError, "digest"):
                releases.acquire(installer.artifact, release, "helper", Path(tmp) / "candidate.ipa")


class NativeUSBAdapterTests(unittest.TestCase):
    """Offline transport-boundary checks. No actual device or write calls."""

    UDID = "00000000-0000000000000000"
    INFO = {"DeviceClass": "iPhone", "ProductType": "iPhone16,2",
            "ProductVersion": "27.2.1", "DeviceName": "Test iPhone"}

    def make_adapter(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        helper = Path(directory.name) / "zag-usb"
        helper.write_bytes(b"offline mock")
        helper.chmod(0o700)
        return installer.StandaloneUSB(Path(directory.name), helper)

    def reply(self, *, udid=None, mode="status", apps=None, developer=True):
        doc = {"transport": "system-usbmuxd", "trust_verified": True,
               "developer_mode": developer, "udid": udid or self.UDID,
               "device": self.INFO}
        if mode == "inventory":
            doc["zag_apps"] = apps if apps is not None else []
        return subprocess.CompletedProcess([], 0, __import__("json").dumps(doc).encode(), b"")

    def test_identity_compatibility_and_inventory(self):
        dev = self.make_adapter()
        with patch.object(installer.subprocess, "run") as run:
            run.side_effect = [self.reply(), self.reply(mode="inventory", apps=[
                {"bundleIdentifier": DESTINATION, "version": "1.0.0", "bundleVersion": "5"}
            ])]
            self.assertEqual(dev.usb_device(), (self.UDID, self.UDID))
            dev.check_compatibility({"MinimumOSVersion": "16.4", "UIDeviceFamily": [1]})
            self.assertEqual(dev.apps(self.UDID), [{
                "bundleIdentifier": DESTINATION, "version": "1.0.0", "bundleVersion": "5"
            }])
            self.assertEqual([call.args[0][-1] for call in run.call_args_list],
                             ["status", "inventory"])

    def test_disconnected_or_untrusted_device_fails(self):
        dev = self.make_adapter()
        with patch.object(installer.subprocess, "run", return_value=self.reply(developer=False)):
            with self.assertRaisesRegex(ValueError, "Developer Mode"):
                dev.usb_device()

    def test_identity_change_rejected_across_calls(self):
        dev = self.make_adapter()
        with patch.object(installer.subprocess, "run") as run:
            run.side_effect = [self.reply(), self.reply(udid="11111111-1111111111111111")]
            dev.usb_device()
            with self.assertRaisesRegex(ValueError, "device changed"):
                dev.apps(self.UDID)

    def test_unexpected_app_and_duplicate_inventory_are_rejected(self):
        dev = self.make_adapter()
        with patch.object(installer.subprocess, "run") as run:
            run.side_effect = [self.reply(), self.reply(mode="inventory", apps=[
                {"bundleIdentifier": "com.other.app", "version": "1.0.0", "bundleVersion": "5"}
            ])]
            dev.usb_device()
            with self.assertRaisesRegex(ValueError, "application identifier"):
                dev.apps(self.UDID)

    def test_empty_native_inventory_remains_ambiguous(self):
        dev = self.make_adapter()
        with patch.object(installer.subprocess, "run") as run:
            run.side_effect = [self.reply(), self.reply(mode="inventory")]
            dev.usb_device()
            with self.assertRaisesRegex(ValueError, "destination occupancy is unconfirmed"):
                dev.apps(self.UDID)

    def test_apptesters_legacy_cannot_be_a_personal_team_destination(self):
        dev = self.make_adapter()
        with patch.object(installer.subprocess, "run") as run:
            status = self.reply()
            legacy = __import__("json").loads(self.reply(mode="inventory").stdout)
            legacy["legacy_app"] = {
                "bundleIdentifier": "com.cwd43.gu29",
                "version": "1.0.0",
                "bundleVersion": "1",
                "signing_class": "AppTesters legacy"
            }
            run.side_effect = [
                status,
                subprocess.CompletedProcess([], 0, __import__("json").dumps(legacy).encode(), b"")
            ]
            dev.usb_device()
            with self.assertRaisesRegex(ValueError, "AppTesters copy detected separately"):
                dev.apps(self.UDID)

    def test_usb_adapter_does_not_expose_device_writes(self):
        dev = self.make_adapter()
        for operation, args in ((dev.install, (self.UDID, Path("signed.app"))),
                                (dev.launch_app, (self.UDID, DESTINATION)),
                                (dev.copy_to_app, (self.UDID, DESTINATION, Path("secret"), "Documents/key")),
                                (dev.copy_from_app, (self.UDID, DESTINATION, "Documents/key", Path("out")))):
            with self.assertRaisesRegex(ValueError, "disabled|not.*validated"):
                operation(*args)

    def test_standalone_cli_blocks_before_provisioning_or_download(self):
        with patch.object(installer.sys, "platform", "darwin"), \
             patch.object(installer.sys, "argv",
                          ["zag_installer.py", "--usb-transport", "standalone", "install"]), \
             patch.object(installer.sys, "stdin", Mock(isatty=Mock(return_value=True))), \
             patch.object(installer.desktop, "locked_cache") as locked, \
             patch.object(installer.releases, "discover") as release, \
             patch.object(installer.desktop.Provisioning, "run") as provision:
            self.assertEqual(installer.main(), 1)
            locked.assert_not_called()
            release.assert_not_called()
            provision.assert_not_called()
