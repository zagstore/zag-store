#!/usr/bin/env python3

import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

P = pathlib.Path
S = P("/opt/zagstore/signing-engine")

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def digest(path):
    with open(path, "rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def run(*args):
    subprocess.run(args, check=True)

parser = argparse.ArgumentParser()
parser.add_argument("--ipa", required=True, type=P)
parser.add_argument("--sha256", required=True)
parser.add_argument("--released", required=True)
args = parser.parse_args()

require(os.geteuid() == 0, "Root required")
require(re.fullmatch(r"[a-f0-9]{64}", args.sha256),
        "Invalid checksum")

sha = args.sha256

with open("/run/lock/zag-release-deployment.lock", "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    require(digest(args.ipa) == sha,
            "Incoming IPA checksum mismatch")

    filename = f"zagstore-{sha}.ipa"

    destinations = [
        (S / "releases" / filename, "zag-byoc-worker", "640"),
        (P("/var/www/zagstore-preview/zag-approved-ipas") / filename,
         "root", "644"),
        (P("/var/www/zagstore.app/zag-approved-ipas") / filename,
         "root", "644"),
    ]

    for dest, group, mode in destinations:
        if dest.exists():
            require(not dest.is_symlink(), "Symlink rejected")
            require(digest(dest) == sha, "Existing IPA mismatch")
        else:
            fd, name = tempfile.mkstemp(
                prefix=".zag-stage-", dir=dest.parent
            )
            os.close(fd)

            try:
                run("install", "-o", "root", "-g", group,
                    "-m", mode, str(args.ipa), name)

                require(digest(name) == sha,
                        "Staged IPA checksum mismatch")

                os.link(name, dest)
            finally:
                P(name).unlink(missing_ok=True)

        print("PASS: Staged", dest, flush=True)

    sys.path.insert(0, str(S / "services"))
    from byoc_ipa_inspection import inspect_ipa

    inspect_ipa(
        str(destinations[0][0]),
        "app.zagstore.ios",
        expected_sha256=sha,
        require_profile=False
    )

    print("PASS: Server IPA inspection", flush=True)

    current = json.loads(
        (S / "releases/current.json").read_text()
    )

    if current["sha256"] == sha:
        print("Already active. No signing service restart.")
        sys.exit(0)

    run(
        sys.executable,
        "/usr/local/sbin/zag-activate-release",
        "--sha256", sha,
        "--released", args.released
    )
