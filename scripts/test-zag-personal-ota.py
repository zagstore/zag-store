#!/usr/bin/env python3
import datetime as dt
import importlib.util
import io
import plistlib
import tempfile
import unittest
import sys
from contextlib import nullcontext
from types import SimpleNamespace
from unittest.mock import patch
from urllib.parse import quote
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("ota", Path(__file__).with_name("zag-personal-ota.py"))
ota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ota)
TEAM = "ABCDE12345"
BUNDLE = ota.ORIGINAL + "." + TEAM
JOB = "a" * 32


class StagingTests(unittest.TestCase):
    def test_actual_bundle_and_build(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, "w") as archive:
            archive.writestr("Payload/Zag.app/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": BUNDLE, "CFBundleVersion": "12.1",
            }))
        with zipfile.ZipFile(raw) as archive, tempfile.TemporaryDirectory() as directory:
            path, info = ota.main_bundle(archive)
            self.assertEqual(ota.verify_identity(info, TEAM), (BUNDLE, "12.1"))
            ota.extract(archive, Path(directory))
            self.assertTrue((Path(directory) / path / "Info.plist").is_file())
        info["CFBundleIdentifier"] = ota.ORIGINAL
        with self.assertRaises(ValueError):
            ota.verify_identity(info, TEAM)

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


if __name__ == "__main__":
    unittest.main()
