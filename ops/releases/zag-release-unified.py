#!/usr/bin/env python3

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import re
import shlex
import subprocess
import tempfile
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

ROOT = pathlib.Path(__file__).resolve().parents[2]
REPO = "zagstore/zag-store-releases"
KEY_ID = "zag-v2-2026-b"
PUBLIC_KEY = bytes.fromhex(
    "97d3cdfae45c59280ad546bcd48f43bdb20b503cadc1d7c018b4a45893b3109b"
)

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def run(*args):
    subprocess.run(args, check=True)

def output(*args):
    return subprocess.check_output(args)

def digest(path):
    with open(path, "rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def version_tuple(version):
    require(
        re.fullmatch(r"\d+\.\d+\.\d+", version),
        "Unsupported version format"
    )
    return tuple(map(int, version.split(".")))

parser = argparse.ArgumentParser()
parser.add_argument("channel", choices=["beta"])
parser.add_argument("--dry-run", action="store_true")
args = parser.parse_args()

spec = importlib.util.spec_from_file_location(
    "zag_signing",
    ROOT / "scripts/zag-sign-metadata-v2.py"
)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)

print("=== SIGNED RELEASE METADATA ===", flush=True)

raw = output(
    "gh", "api",
    f"repos/{REPO}/contents/releases/v2/{args.channel}.json",
    "--header", "Accept: application/vnd.github.raw+json"
)

envelope = signing.strict_json(raw)

require(envelope["keyId"] == KEY_ID, "Untrusted signing key")

payload = signing.verify(
    envelope,
    Ed25519PublicKey.from_public_bytes(PUBLIC_KEY),
    args.channel
)

now = dt.datetime.now(dt.timezone.utc)
issued = dt.datetime.fromisoformat(
    payload["publishedAt"].replace("Z", "+00:00")
)

require(issued <= now + dt.timedelta(minutes=5),
        "Manifest publication is in the future")

version = payload["version"]
build = int(payload["build"])
sha = payload["sha256"]

version_tuple(version)
require(build > 0, "Invalid build")

tag = f"v{version}-beta.{build}"
filename = f"ZagStore-{version}-beta.{build}.ipa"

expected_url = (
    "https://github.com/zagorskey/zag-store-releases/"
    f"releases/download/{tag}/{filename}"
)

require(payload["ipaURL"] == expected_url,
        "Unexpected signed asset URL")

print("PASS: Ed25519 signature")
print("PASS: Channel, lifetime and release identity")

release = json.loads(output(
    "gh", "api",
    f"repos/{REPO}/releases/tags/{tag}"
))

require(not release["draft"], "Release is still a draft")
require(release["prerelease"], "Expected beta prerelease")
require(release["tag_name"] == tag, "Tag mismatch")

released = release["published_at"]
dt.datetime.strptime(released, "%Y-%m-%dT%H:%M:%SZ")

assets = [
    a for a in release["assets"]
    if a["name"] == filename
]

require(len(assets) == 1, "Expected exactly one IPA asset")

asset = assets[0]

require(asset["state"] == "uploaded", "Asset not ready")
require(asset.get("digest") == f"sha256:{sha}",
        "GitHub asset digest mismatch")

print(f"PASS: GitHub release {tag}")
print(f"Original publication: {released}")
print(f"SHA-256: {sha}")

with tempfile.TemporaryDirectory(prefix="zag-release-") as tmp:
    ipa = pathlib.Path(tmp) / filename

    print("=== DOWNLOAD AND VERIFY IPA ===", flush=True)

    run(
        "gh", "release", "download", tag,
        "--repo", REPO,
        "--pattern", filename,
        "--dir", tmp
    )

    require(ipa.stat().st_size == asset["size"],
            "IPA size mismatch")
    require(digest(ipa) == sha, "IPA checksum mismatch")

    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()

        require(len(names) == len(set(names)),
                "Duplicate ZIP entries")

        apps = {
            n.split("/")[1]
            for n in names
            if n.startswith("Payload/")
            and len(n.split("/")) > 2
            and n.split("/")[1].endswith(".app")
        }

        require(apps == {"Feather.app"},
                "Unexpected application layout")

        info = plistlib.loads(
            z.read("Payload/Feather.app/Info.plist")
        )

        require(
            info["CFBundleIdentifier"] == payload["appId"],
            "Bundle identifier mismatch"
        )

        require(
            info["CFBundleShortVersionString"] == version,
            "IPA version mismatch"
        )

        require(
            str(info["CFBundleVersion"]) == payload["build"],
            "IPA build mismatch"
        )

        require(
            info["MinimumOSVersion"] == payload["minimumIOSVersion"],
            "Minimum iOS mismatch"
        )

        require(
            not any(n.endswith("/embedded.mobileprovision")
                    for n in names),
            "IPA contains a provisioning profile"
        )

        require(
            not any(n.endswith("/ZagInstallAttribution.json")
                    for n in names),
            "IPA contains installation attribution"
        )

        executable = z.read(
            "Payload/Feather.app/" + info["CFBundleExecutable"]
        )

        require(
            b"ZAG-FIRST-LAUNCH-TEST-BUILD-NOT-FOR-RELEASE"
            not in executable,
            "Test executable rejected"
        )

        require(
            b"https://zagstore.app/api/zag/v1/first-launch"
            in executable,
            "Production attribution endpoint missing"
        )

    print("PASS: IPA checksum and application identity")

    print("=== SERVER RELEASE STATE ===", flush=True)

    current = json.loads(output(
        "ssh", "zagstore",
        "cat /opt/zagstore/signing-engine/releases/current.json"
    ))

    current_version = (
        version_tuple(current["version"]),
        int(current["build"])
    )

    candidate_version = (version_tuple(version), build)

    require(candidate_version >= current_version,
            "Release downgrade rejected")

    if candidate_version == current_version:
        require(current["sha256"] == sha,
                "Same-version binary replacement rejected")

    if args.dry_run:
        print("SUCCESS: Dry run passed. No server changes.")
        raise SystemExit(0)

    if current["sha256"] == sha:
        print("Release already active in signing engine.")
        print("Checking both public installation pages.")

        for host in (
            "preview.zagstore.app",
            "zagstore.app"
        ):
            html = output(
                "curl", "--fail", "--silent", "--show-error",
                "--max-time", "30",
                f"https://{host}/install/?release-check={sha[:12]}"
            ).decode()

            require(
                f"Zag Store {version} Beta {build}" in html,
                f"{host}: release label mismatch"
            )

            require(
                f'datetime="{released[:10]}"' in html,
                f"{host}: release date mismatch"
            )

            print(f"PASS: {host}")

        print("SUCCESS: Already deployed. No service restart.")
        raise SystemExit(0)

    print("=== SERVER STAGING AND ACTIVATION ===", flush=True)

    remote = output(
        "ssh", "zagstore",
        "mktemp -d /tmp/zag-release.XXXXXXXX"
    ).decode().strip()

    require(
        re.fullmatch(r"/tmp/zag-release\.[A-Za-z0-9]+", remote),
        "Unexpected remote staging path"
    )

    try:
        run("scp", str(ipa), f"zagstore:{remote}/release.ipa")

        command = [
            "sudo", "python3",
            "/usr/local/sbin/zag-stage-release",
            "--ipa", remote + "/release.ipa",
            "--sha256", sha,
            "--released", released
        ]

        run("ssh", "-tt", "zagstore", shlex.join(command))

    finally:
        run("ssh", "zagstore",
            "rm -rf -- " + shlex.quote(remote))

    print("SUCCESS: Unified release deployment completed.")
