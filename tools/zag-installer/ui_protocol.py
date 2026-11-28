"""Bounded, local JSON prompt transport for the macOS graphical installer.

Only prompts/results use the original stdout pipe. Ordinary Python and child
process stdout is redirected to stderr so it cannot forge a trusted UI prompt.
The protocol carries no passwords to the website and never writes a secret to
the log stream. This is an opt-in replacement for interactive Terminal prompts.
"""

import json
import os
import sys

MAX_REPLY = 4096


class Channel:
    def __init__(self, *, input_stream=None, event_stream=None, isolate_output=True):
        self.input = sys.stdin.buffer if input_stream is None else input_stream
        self.events = event_stream
        self.fd = None
        if isolate_output:
            if input_stream is not None or event_stream is not None:
                raise ValueError("Injected streams cannot redirect process output")
            self.fd = os.dup(1)
            os.dup2(2, 1)
            sys.stdout = sys.stderr

    def send(self, payload):
        wire = (json.dumps(payload, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")
        if self.fd is None:
            if self.events is None:
                raise RuntimeError("No installer UI transport")
            self.events.write(wire)
            self.events.flush()
        else:
            view = memoryview(wire)
            while view:
                sent = os.write(self.fd, view)
                if sent <= 0:
                    raise BrokenPipeError("Graphical installer disconnected")
                view = view[sent:]

    def ask(self, message, *, secret=False, confirmation=None, action=None):
        if not isinstance(message, str) or not message or len(message) > 2048:
            raise ValueError("Invalid installer prompt")
        payload = {"type": "prompt", "message": message, "secure": bool(secret)}
        if confirmation is not None:
            if secret or not isinstance(confirmation, str) or not confirmation or len(confirmation) > 256 or action not in ("Install", "Upgrade", "Replace", "Continue", "Resume Setup", "Create Certificate"):
                raise ValueError("Invalid confirmation contract")
            payload.update(confirmation=confirmation, action=action)
        self.send(payload)
        wire = self.input.readline(MAX_REPLY + 1)
        if not wire or len(wire) > MAX_REPLY or not wire.endswith(b"\n"):
            raise ValueError("Graphical installer input was interrupted or oversized")
        try:
            reply = json.loads(wire)
        except (UnicodeError, ValueError) as error:
            raise ValueError("Invalid graphical installer reply") from error
        if type(reply) is not dict:
            raise ValueError("Invalid graphical installer reply")
        if reply == {"cancel": True}:
            raise ValueError("Installation cancelled")
        if set(reply) != {"value"} or type(reply["value"]) is not str or len(reply["value"]) > 2048:
            raise ValueError("Invalid graphical installer reply")
        if confirmation is not None and reply["value"] != confirmation:
            raise ValueError("Installation cancelled")
        return reply["value"]

    def progress(self, stage):
        if stage not in ("preflight", "authentication", "provisioning", "signing", "installation", "handoff"):
            raise ValueError("Invalid installer stage")
        self.send({"type": "progress", "stage": stage})

    def confirm(self, message, expected, action):
        return self.ask(message, confirmation=expected, action=action)
