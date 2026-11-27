#!/usr/bin/env python3
import datetime as dt
import importlib.util
import io
import plistlib
import tempfile
import unittest
import sys
import stat
import struct
from contextlib import nullcontext
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import quote
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("ota", Path(__file__).with_name("zag-personal-ota.py"))
ota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ota)
TEAM = "FTB8PRW638"
BUNDLE = "app.zagstore.ios.FTB8PRW638"
JOB = "a" * 32


class StagingTests(unittest.TestCase):
    def test_codesign_trust_failure_remains_fatal_and_does_not_expose_detail(self):
        result = SimpleNamespace(returncode=1, stdout=b"", stderr=b"private path: CSSMERR_TP_NOT_TRUSTED")
        with patch.object(ota.subprocess, "run", return_value=result), self.assertRaises(ValueError) as error:
            ota.command("codesign", "--verify", "--deep", "--strict", "/private/artifact")
        self.assertIn("CSSMERR_TP_NOT_TRUSTED", str(error.exception))
        self.assertNotIn("private", str(error.exception))

    def test_codesign_invocations_and_stage_diagnostics(self):
        app = Path("/private/scratch/Payload/Test.app")
        relative = Path("Payload/Test.app")
        denied = SimpleNamespace(returncode=1, stdout=b"", stderr=b"/private/data: invalid requirement specification")
        with patch.object(ota.subprocess, "run", return_value=denied) as run, self.assertRaisesRegex(
            ValueError, r"Apple Development certificate requirement \[Payload/Test.app\]: codesign exited 1; stderr: invalid requirement specification",
        ):
            ota.verify_development_certificate(app, relative)
        self.assertTrue(run.call_args.args[0][3].startswith("-R=anchor apple generic"))
        xml = plistlib.dumps({"get-task-allow": True})
        with patch.object(ota.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=xml)) as run:
            self.assertEqual(ota.read_signed_entitlements(app, relative), {"get-task-allow": True})
        self.assertEqual(run.call_args.args[0], ("codesign", "--display", "--entitlements", ":-", str(app)))

    def test_extraction_preserves_executable_bits_and_zip_defaults(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as archive:
            for name, mode in (("Executable", 0o100755), ("Resource", 0), ("Plain", 0o100640)):
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3 if mode else 0
                entry.external_attr = (mode << 16) or 0x20
                archive.writestr(entry, b"same content")
        with zipfile.ZipFile(raw) as archive, tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            ota.extract(archive, base)
            for name, mode in (("Executable", 0o755), ("Resource", 0o644), ("Plain", 0o640)):
                self.assertEqual(stat.S_IMODE((base / name).stat().st_mode), mode)
                self.assertEqual((base / name).read_bytes(), b"same content")

    def test_macho_detection_checks_fat_slice_table(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "candidate"
            thin = bytes.fromhex("cffaedfe") + bytes(28)
            fat = struct.pack(">7I", 0xcafebabe, 1, 0x100000c, 0, 28, len(thin), 0) + thin
            for data, expected in ((thin, True), (fat, True), (fat[:-1], False),
                                   (bytes.fromhex("cafebabe0000003d0002000000"), False)):
                path.write_bytes(data)
                self.assertEqual(ota.is_macho(path), expected)

    def test_actual_bundle_and_build(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as archive:
            archive.writestr("Payload/Zag.app/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": BUNDLE, "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "3",
            }))
        with zipfile.ZipFile(raw) as archive, tempfile.TemporaryDirectory() as directory:
            path, info = ota.main_bundle(archive)
            self.assertEqual(ota.verify_identity(info, TEAM), (BUNDLE, "3"))
            ota.extract(archive, Path(directory))
            self.assertTrue((Path(directory) / path / "Info.plist").is_file())
        for rejected in ("app.zagstore.ios", "com.cwd43.gu29", "com.cwd43.gu29." + TEAM,
                         "app.zagstore.ios.ABCDE12345", BUNDLE + ".extra"):
            with self.subTest(identifier=rejected), self.assertRaises(ValueError):
                ota.verify_identity(dict(info, CFBundleIdentifier=rejected), TEAM)

    def test_profile_binds_target_team_signer_and_entitlements(self):
        now = dt.datetime.now(dt.timezone.utc)
        expiry = now + dt.timedelta(days=2)
        signed = {
            "application-identifier": TEAM + "." + BUNDLE,
            "com.apple.developer.team-identifier": TEAM, "get-task-allow": True,
            "keychain-access-groups": [TEAM + ".example"],
        }
        profile = {
            "TeamIdentifier": [TEAM], "ProvisionedDevices": ["Device"], "ExpirationDate": expiry,
            "DeveloperCertificates": [b"leaf"],
            "Entitlements": dict(signed, **{"keychain-access-groups": [TEAM + ".*"]}),
        }
        self.assertEqual(ota.validate_profile(profile, signed, b"leaf", TEAM, BUNDLE, "device", now), expiry)
        for changed in (
            dict(profile, ProvisionedDevices=["other"]),
            dict(profile, DeveloperCertificates=[b"other"]),
            dict(profile, ExpirationDate=now),
            dict(profile, TeamIdentifier=["other"]),
            dict(profile, Entitlements={}),
        ):
            with self.assertRaises(ValueError):
                ota.validate_profile(changed, signed, b"leaf", TEAM, BUNDLE, "device", now)

    def test_preview_manifest_uses_mapped_identity(self):
        asset = {"kind": "software-package", "url": f"https://{ota.PREVIEW}/wp-json/zag-byoc/v1/ota/{JOB}/ipa?token=sample"}
        metadata = {"bundle-identifier": BUNDLE, "bundle-version": "31", "kind": "software"}
        def validate():
            ota.check_manifest(plistlib.dumps({"items": [{"assets": [asset], "metadata": metadata}]}),
                               JOB, BUNDLE, "31")
        validate()
        metadata["bundle-version"] = "1"
        with self.assertRaises(ValueError):
            validate()

    def test_operator_publish_rejects_changed_upload_and_uses_preview_link(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            delivery = root / "delivery"
            delivery.mkdir()
            ipa = root / "upload.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/Zag.app/Info.plist", plistlib.dumps({
                    "CFBundleIdentifier": BUNDLE, "CFBundleVersion": "7",
                }))
            calls = []

            def publish(**options):
                calls.append(options)
                job = options["job_id"]
                route = f"https://{ota.PREVIEW}/wp-json/zag-byoc/v1/ota/{job}"
                body = {"items": [{"assets": [{"kind": "software-package", "url": route + "/ipa?token=p"}],
                                    "metadata": {"kind": "software", "bundle-identifier": BUNDLE, "bundle-version": "7"}}]}
                (delivery / (job + ".plist")).write_bytes(plistlib.dumps(body))
                return {"sha256": ota.sha(ipa), "install_url":
                        "itms-services://?action=download-manifest&url=" + quote(route + "/manifest?token=m", safe="")}

            simulated = SimpleNamespace(HOST=ota.PREVIEW, publish=publish, delivery_lock=lambda _: nullcontext())
            args = SimpleNamespace(ipa=ipa, sha256="0" * 64, team=TEAM, delivery=delivery, services=root,
                                   secret_file=root / "unused", uid=501, gid=501,
                                   effective_expiration=(dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1)).isoformat())
            with patch.object(ota.os, "geteuid", return_value=0), patch.object(ota, "DELIVERY", delivery), \
                    patch.object(ota, "SERVICES", root), patch.object(ota, "SECRET", root / "unused"), patch.dict(sys.modules, {"byoc_private_byoc_delivery": simulated}):
                with self.assertRaisesRegex(ValueError, "digest differs"):
                    ota.publish(args)
                self.assertEqual(calls, [])
                args.sha256 = ota.sha(ipa)
                result = ota.publish(args)
                self.assertIn("/install?token=m", result["safari_url"])
                self.assertEqual(calls[0]["ttl"], 600)
                args.effective_expiration = dt.datetime.now(dt.timezone.utc).isoformat()
                with self.assertRaisesRegex(ValueError, "expires before"):
                    ota.publish(args)
                self.assertEqual(len(calls), 1)

    def test_cleanup_requires_exact_team_scoped_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            delivery = Path(directory)
            record = delivery / (JOB + ".json")
            digest = "a" * 64
            ipa = delivery / (JOB + ".signed.ipa")
            ipa.write_bytes(b"fixture")
            simulated = SimpleNamespace(delivery_lock=lambda _: nullcontext())
            with patch.object(ota.os, "geteuid", return_value=0), patch.object(ota, "DELIVERY", delivery), \
                    patch.dict(sys.modules, {"byoc_private_byoc_delivery": simulated}):
                for refused in ("com.cwd43.gu29", "com.cwd43.gu29." + TEAM, "app.zagstore.ios.ABCDE12345"):
                    record.write_text(ota.json.dumps({"bundle_id": refused, "job_id": JOB, "sha256": digest}))
                    with self.assertRaises(ValueError):
                        ota.cleanup(JOB, digest, TEAM)
                    self.assertTrue(ipa.is_file())
                record.write_text(ota.json.dumps({"bundle_id": BUNDLE, "job_id": JOB, "sha256": digest}))
                self.assertEqual(ota.cleanup(JOB, digest, TEAM), {"removed": JOB})
                self.assertFalse(ipa.exists())


if __name__ == "__main__":
    unittest.main()
