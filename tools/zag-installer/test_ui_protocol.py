"""Offline contract tests for the graphical installer prompt transport."""

import io
import json
import unittest
import subprocess
import sys

from ui_protocol import Channel, AppleFailure, run_native_install
import ipa_preview
import tempfile
import zipfile
import plistlib
from pathlib import Path


class ProtocolTests(unittest.TestCase):
    def make_channel(self, wire):
        output = io.BytesIO()
        channel = Channel(
            input_stream=io.BytesIO(wire), event_stream=output,
            isolate_output=False
        )
        return channel, output

    def test_secure_prompt_never_echoes_secret(self):
        channel, output = self.make_channel(b'{"value":"private-password"}\n')
        self.assertEqual(channel.ask("Apple ID password:", secret=True), "private-password")
        value = json.loads(output.getvalue())
        self.assertEqual(value, {
            "type": "prompt", "message": "Apple ID password:", "secure": True
        })
        self.assertNotIn(b"private-password", output.getvalue())

    def test_combined_credentials_are_not_echoed(self):
        fields = {"email": " example@example.com ", "password": "private-password"}
        wire = (json.dumps({"value": json.dumps(fields)}) + "\n").encode()
        channel, output = self.make_channel(wire)
        self.assertEqual(channel.credentials(), ("example@example.com", "private-password"))
        self.assertEqual(json.loads(output.getvalue()), {
            "type": "prompt", "message": "Apple ID credentials: ", "secure": True
        })
        self.assertNotIn(b"private-password", output.getvalue())
        self.assertNotIn(b"example@example.com", output.getvalue())

    def test_combined_credentials_reject_invalid_fields(self):
        for fields in (
            {}, [], {"email": "a", "password": ""},
            {"email": " ", "password": "secret"},
            {"email": "a", "password": 123},
            {"email": "a", "password": "secret", "extra": True},
            {"email": "a" * 321, "password": "secret"},
            {"email": "a", "password": "x" * 1025},
        ):
            with self.subTest(kind=type(fields).__name__):
                wire = (json.dumps({"value": json.dumps(fields)}) + "\n").encode()
                channel, output = self.make_channel(wire)
                with self.assertRaisesRegex(ValueError, "^Invalid credential reply$"):
                    channel.credentials()
                self.assertNotIn(b"secret", output.getvalue())

    def test_combined_credentials_cancel_or_disconnect(self):
        for wire in (b'{"cancel":true}\n', b"", b'{"value":"not-json"}\n'):
            channel, output = self.make_channel(wire)
            with self.assertRaises(ValueError):
                channel.credentials()
            self.assertNotIn(b"not-json", output.getvalue())

    def test_plain_prompt_preserves_exact_response(self):
        channel, output = self.make_channel(b'{"value":"PROVISION"}\n')
        self.assertEqual(channel.ask("Confirm Apple provisioning"), "PROVISION")
        self.assertFalse(json.loads(output.getvalue())["secure"])

    def test_button_confirmation_contract(self):
        channel, output = self.make_channel(b'{"value":"INSTALL"}\n')
        self.assertEqual(channel.confirm("Install exact destination?", "INSTALL", "Install"), "INSTALL")
        self.assertEqual(json.loads(output.getvalue())["confirmation"], "INSTALL")
        self.assertEqual(json.loads(output.getvalue())["action"], "Install")
        for wire in (b'{"value":"wrong"}\n', b'{"cancel":true}\n'):
            channel, _ = self.make_channel(wire)
            with self.assertRaises(ValueError):
                channel.confirm("Install exact destination?", "INSTALL", "Install")

    def test_cancelled_and_broken_connection_fail_closed(self):
        for wire in (b'{"cancel":true}\n', b""):
            channel, _ = self.make_channel(wire)
            with self.assertRaises(ValueError):
                channel.ask("Approve installation")

    def test_malformed_and_oversized_fail_closed(self):
        for wire in (
            b'{"value":"ok","unexpected":1}\n',
            b'{"value":42}\n', b'not-json\n',
            b"x" * 4097 + b"\n",
            b'{"value":"without newline"}'
        ):
            channel, _ = self.make_channel(wire)
            with self.assertRaises(ValueError):
                channel.ask("Choose your Personal Team")

    def test_progress_contract(self):
        channel, out = self.make_channel(b"")
        channel.progress("signing")
        self.assertEqual(json.loads(out.getvalue()), {"type": "progress", "stage": "signing"})
        with self.assertRaises(ValueError):
            channel.progress("private-password")
        self.assertNotIn(b"private-password", out.getvalue())

    def test_native_progress_contract(self):
        channel, out = self.make_channel(b"")
        channel.installation_progress("transfer", 42)
        self.assertEqual(json.loads(out.getvalue()), {
            "type": "progress", "stage": "installation", "phase": "transfer", "percent": 42
        })
        for phase, percent in (("secret", 1), ("transfer", -1), ("transfer", 101),
                               ("installing", True), ("verification", "42")):
            with self.subTest(phase=phase, percent=percent), self.assertRaises(ValueError):
                channel.installation_progress(phase, percent)

    def test_native_stream_reports_measured_progress_in_order(self):
        records = [
            {"native_progress": "transfer", "percent": 0},
            {"native_progress": "transfer", "percent": 50},
            {"native_progress": "transfer", "percent": 20},
            {"native_progress": "transfer", "percent": 50},
            {"native_progress": "verification", "percent": 100},
            {"native_progress": "installing", "percent": 70},
            {"native_progress": "readback", "percent": 0},
            {"installed": True},
        ]
        wire = "".join(json.dumps(item) + "\n" for item in records)
        seen = []
        result = run_native_install(
            [sys.executable, "-c", "import sys; sys.stdout.write(" + repr(wire) + ")"],
            lambda phase, percent: seen.append((phase, percent)), timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"installed": True})
        self.assertEqual(seen, [("transfer", 0), ("transfer", 50), ("verification", 100),
                                ("installing", 70), ("readback", 0)])

    def test_native_stream_rejects_invalid_and_trailing_events(self):
        for wire in ('{"native_progress":"transfer","percent":101}\n',
                     '{"installed":true}\n{"native_progress":"transfer","percent":5}\n',
                     'not-json\n', '{"installed":true}', 'x' * 4097 + '\n'):
            with self.subTest(wire=wire[:60]), self.assertRaises(ValueError):
                run_native_install([sys.executable, "-c", "import sys; sys.stdout.write(" + repr(wire) + ")"],
                                   lambda *_: None, timeout=5)

    def test_native_stream_timeout(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            run_native_install([sys.executable, "-c", "import time; time.sleep(10)"],
                               lambda *_: None, timeout=0.1)

    def test_imported_destination_mapping_is_separate_and_stable(self):
        original = "com.example.app"
        team = "FTB8PRW638"
        mapped = ipa_preview.mapped_import_bundle(original, team)
        self.assertRegex(mapped, r"^app\.zloader\.imported\.[a-f0-9]{32}\.FTB8PRW638$")
        self.assertEqual(mapped, ipa_preview.mapped_import_bundle(original, team))
        self.assertNotEqual(mapped, ipa_preview.mapped_import_bundle(original, "AAAAAAAAAA"))
        for protected in ("app.zagstore.ios", "app.zagstore.ios.FTB8PRW638", "com.cwd43.gu29"):
            with self.assertRaises(ValueError):
                ipa_preview.mapped_import_bundle(protected, team)

    def test_ipa_metadata_uses_main_application_name(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "unrelated-file-name.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Example.app/Info.plist", plistlib.dumps({
                    "CFBundleDisplayName": "Example", "CFBundleIdentifier": "com.example.app",
                    "CFBundleShortVersionString": "2.1", "CFBundleVersion": "3"
                }))
                archive.writestr("Payload/Example.app/PlugIns/Extension.appex/Info.plist", b"ignored")
            self.assertEqual(ipa_preview.inspect(path), {
                "name": "Example", "bundle": "com.example.app", "version": "2.1", "build": "3"
            })

    def test_ipa_metadata_rejects_ambiguous_and_oversized_plists(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/A.app/Info.plist", b"x")
                archive.writestr("Payload/B.app/Info.plist", b"x")
            with self.assertRaises(ValueError):
                ipa_preview.inspect(path)
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("Payload/A.app/Info.plist", b"x" * (ipa_preview.MAX_PLIST + 1))
            with self.assertRaises(ValueError):
                ipa_preview.inspect(path)

    def test_structured_apple_failure(self):
        channel, out = self.make_channel(b"")
        channel.apple_failure(AppleFailure("Apple Personal Team profile", 123,
            "The server is rate limiting requests. Wait and retry."))
        message = json.loads(out.getvalue())["message"]
        self.assertIn("provisioning profile", message)
        self.assertIn("rate limiting", message)
        self.assertIn("123", message)
        channel, out = self.make_channel(b"")
        channel.apple_failure(AppleFailure("private-token", "private-code", "private-hint"))
        self.assertNotIn(b"private-", out.getvalue())

    def test_failure_guidance_is_allowlisted(self):
        channel, out = self.make_channel(b"")
        channel.failure("Expected a six-digit Apple verification code")
        self.assertIn("six-digit", json.loads(out.getvalue())["message"])
        channel, out = self.make_channel(b"")
        channel.failure("unexpected private-token-value")
        self.assertNotIn(b"private-token-value", out.getvalue())
        self.assertIn("Diagnostics", json.loads(out.getvalue())["message"])

    def test_event_contract_is_one_json_object_per_line(self):
        channel, out = self.make_channel(b"")
        channel.send({"type": "finished", "result": {"build": "5"}})
        self.assertEqual(
            json.loads(out.getvalue().decode("ascii")),
            {"type": "finished", "result": {"build": "5"}}
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
