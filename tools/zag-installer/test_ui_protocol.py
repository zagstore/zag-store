"""Offline contract tests for the graphical installer prompt transport."""

import io
import json
import unittest

from ui_protocol import Channel, AppleFailure


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
