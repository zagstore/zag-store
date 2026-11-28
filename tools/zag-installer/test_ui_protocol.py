"""Offline contract tests for the graphical installer prompt transport."""

import io
import json
import unittest

from ui_protocol import Channel


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

    def test_event_contract_is_one_json_object_per_line(self):
        channel, out = self.make_channel(b"")
        channel.send({"type": "finished", "result": {"build": "5"}})
        self.assertEqual(
            json.loads(out.getvalue().decode("ascii")),
            {"type": "finished", "result": {"build": "5"}}
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
