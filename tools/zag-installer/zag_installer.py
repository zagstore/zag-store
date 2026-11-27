#!/usr/bin/env python3
"""Verify, sign and install Zag Store Beta 3 over trusted macOS USB."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from urllib.parse import urlsplit
import zipfile

import desktop

SOURCE = (
    "https://github.com/zagstore/zag-store-releases/releases/download/"
    "v1.0.0-beta.3/ZagStore-1.0.0-beta.3.ipa"
)
SOURCE_DIGEST = "da743f30f32723ab2bb16051734caa109fd75d1fdaa292cdcb70c968d582f741"
SOURCE_SIZE = 60_803_467
SIGNED_TEST_DIGEST = "f48c3ea820c50b9f866a4eb987ab4d15e062499ce6e065c0ef0ac31c59c4d3d9"
SOURCE_HOSTS = {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("artifact_validation", ROOT / "scripts/zag-personal-ota.py")
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


def verify_source(path):
    artifact.require(path.stat().st_size == SOURCE_SIZE and artifact.sha(path) == SOURCE_DIGEST,
                     "Source does not match the pinned official Beta 3 asset")
    with zipfile.ZipFile(path) as archive:
        _, info = artifact.main_bundle(archive)
    artifact.require(info.get("CFBundleIdentifier") == artifact.ORIGINAL
                     and info.get("CFBundleShortVersionString") == "1.0.0"
                     and info.get("CFBundleVersion") == "3", "Unexpected official release metadata")
    return {"bundle": artifact.ORIGINAL, "version": "1.0.0", "build": "3", "sha256": SOURCE_DIGEST}


class ReleaseRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        url = urlsplit(newurl)
        artifact.require(url.scheme == "https" and url.hostname in SOURCE_HOSTS
                         and url.username is None and url.password is None and url.port in (None, 443),
                         "Unexpected official release redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def acquire_source(path):
    if path.exists():
        return verify_source(path)
    with tempfile.TemporaryDirectory(prefix=".zag-source-", dir=path.parent) as scratch:
        candidate = Path(scratch) / "release.ipa"
        opener = urllib.request.build_opener(ReleaseRedirect())
        with opener.open(SOURCE, timeout=20) as response, candidate.open("xb") as output:
            size = 0
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                size += len(chunk)
                artifact.require(size <= SOURCE_SIZE, "Official asset exceeded the pinned size")
                output.write(chunk)
        result = verify_source(candidate)
        candidate.chmod(0o600)
        os.link(candidate, path)
        return result


class CoreDevice:
    def __init__(self, scratch):
        self.scratch = scratch

    def run(self, stage, *args):
        report = self.scratch / "coredevice.json"
        report.unlink(missing_ok=True)
        result = subprocess.run(
            ["xcrun", "devicectl", *args, "--json-output", str(report)],
            capture_output=True, timeout=180,
        )
        if result.returncode:
            raise ValueError(f"{stage}: CoreDevice exited {result.returncode}. Check USB trust and Developer Mode.")
        try:
            data = json.loads(report.read_bytes())
            return data["result"]
        except (OSError, ValueError, KeyError) as error:
            raise ValueError(f"{stage}: CoreDevice did not return a usable structured result") from error

    def usb_device(self):
        result = self.run("USB discovery", "list", "devices")
        wired = [device for device in result["devices"]
                 if device.get("connectionProperties", {}).get("transportType") == "wired"]
        artifact.require(len(wired) == 1, "Connect and trust exactly one iPhone or iPad over USB")
        device = wired[0]
        connection = device["connectionProperties"]
        hardware = device.get("hardwareProperties", {})
        udid = hardware.get("udid", "")
        artifact.require(connection.get("pairingState") == "paired" and
                         hardware.get("platform") == "iOS" and
                         re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})", udid)
                         and device.get("identifier"), "USB device trust or hardware identity is unavailable")
        return device["identifier"], udid

    def apps(self, identifier):
        return self.run("Installed app inventory", "device", "info", "apps", "--device", identifier,
                        "--include-all-apps")["apps"]

    def install(self, identifier, path):
        self.run("Installation", "device", "install", "app", "--device", identifier, str(path))


def destination_present(device, target, expected):
    return any(app.get("bundleIdentifier") == expected for app in device.apps(target))


def validate_and_install(signed, team, apple_root, scratch, device, target, udid, approve,
                         replacing=False):
    expected = artifact.mapped_bundle(team)
    evidence = artifact.validate(signed, team, udid, apple_root)
    artifact.require(evidence["bundle_identifier"] == expected and evidence["build"] == "3",
                     "Expected the distinct team-mapped Zag Store build 3")
    staged = scratch / "staged"
    staged.mkdir()
    with zipfile.ZipFile(signed) as archive:
        relative, info = artifact.main_bundle(archive)
        artifact.require(info.get("CFBundleShortVersionString") == "1.0.0", "Unexpected signed Zag Store version")
        artifact.extract(archive, staged)
    confirmation = f"REPLACE {expected}" if replacing else "INSTALL"
    prompt = (f"Replace the existing {expected}? Type {confirmation}: " if replacing
              else f"Install {expected} as a separate app? Type INSTALL to approve: ")
    artifact.require(approve(prompt) == confirmation, "Installation cancelled")
    artifact.require(device.usb_device() == (target, udid), "The trusted USB device changed")
    artifact.require(destination_present(device, target, expected) == replacing,
                     "Destination inventory changed. Installation cancelled.")
    device.install(target, staged / relative)
    apps = device.apps(target)
    artifact.require(any(app.get("bundleIdentifier") == expected and app.get("bundleVersion") == "3"
                         and app.get("version") == "1.0.0" for app in apps),
                     "Installer returned success but inventory did not verify the app and build")
    return {"installed_bundle": expected, "version": "1.0.0", "build": "3"}


def install_signed(source, team, apple_root, scratch, device, approve=input):
    target, udid = device.usb_device()
    expected = artifact.mapped_bundle(team)
    artifact.require(not destination_present(device, target, expected),
                     "Destination is already installed. install-signed only performs fresh installs.")
    signed = scratch / "signed.ipa"
    artifact.require(source.is_file() and 0 < source.stat().st_size <= 512 * 1024**2, "Invalid signed IPA")
    shutil.copyfile(source, signed)
    artifact.require(artifact.sha(signed) == SIGNED_TEST_DIGEST,
                     "Signed IPA does not match the verified Beta 3 prototype artifact")
    return validate_and_install(signed, team, apple_root, scratch, device, target, udid, approve)


def install_unsigned(source, apple_root, endpoint, replace_team, scratch, device, approve=input):
    endpoint = desktop.provider_origin(endpoint) if endpoint else None
    if replace_team is not None:
        artifact.mapped_bundle(replace_team)
    local_source = scratch / "official.ipa"
    artifact.require(source.is_file() and source.stat().st_size == SOURCE_SIZE, "Invalid official Beta 3 IPA")
    shutil.copyfile(source, local_source)
    verify_source(local_source)
    root = scratch / "apple-root.pem"
    artifact.require(apple_root.is_file() and 0 < apple_root.stat().st_size < 65536, "Invalid Apple root PEM")
    shutil.copyfile(apple_root, root)
    desktop.verify_root(artifact, root)

    unsigned = scratch / "unsigned"
    unsigned.mkdir()
    with zipfile.ZipFile(local_source) as archive:
        relative, _ = artifact.main_bundle(archive)
        artifact.extract(archive, unsigned)
    app = unsigned / relative
    artifact.require(not any(path.is_dir() and path.suffix in (".app", ".appex", ".xpc")
                             for path in app.rglob("*")),
                     "Expected the single-app official Beta 3 layout")
    target, udid = device.usb_device()
    replacing = False

    def choose_team(teams):
        nonlocal replacing
        teams = [team for team in teams if isinstance(team["id"], str) and artifact.TEAM.fullmatch(team["id"])]
        artifact.require(teams, "Apple returned no selectable teams")
        for index, team in enumerate(teams, 1):
            # JSON escaping prevents names supplied by the account from changing Terminal state.
            print(f"  {index}. {json.dumps(team['name'])} ({team['id']})")
        choice = approve("Select your Personal Team by number, or Enter to cancel: ").strip()
        artifact.require(re.fullmatch(r"[0-9]{1,5}", choice) and 1 <= int(choice) <= len(teams),
                         "Team selection cancelled")
        team = teams[int(choice) - 1]["id"]
        expected = artifact.mapped_bundle(team)
        artifact.require(device.usb_device() == (target, udid), "The trusted USB device changed")
        replacing = destination_present(device, target, expected)
        artifact.require(not replacing or replace_team == team, "Destination is already installed")
        artifact.require(replace_team is None or (replace_team == team and replacing),
                         "Requested replacement team and occupied destination must match")
        artifact.require(approve(f"Use {team} as your Personal Team and allow Apple provisioning? Type PROVISION: ")
                         == "PROVISION", "Apple provisioning cancelled")
        return team

    with desktop.tools_for_install(ROOT, native=endpoint is None) as (auth, helper, openssl, anisette):
        portal = desktop.Provisioning(endpoint, udid, desktop.Keychain(helper), openssl, choose_team, approve, anisette)
        team, identity, profile = portal.run(auth)
        signed = desktop.sign(artifact, app, relative, team, udid, identity, profile, root, helper, scratch)
        return validate_and_install(signed, team, root, scratch, device, target, udid, approve, replacing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    prepare = modes.add_parser("prepare", help="Verify or download the exact official unsigned Beta 3 asset")
    prepare.add_argument("source", type=Path)
    install = modes.add_parser("install-signed", help="Install a previously signed team-mapped Beta 3 over trusted USB")
    install.add_argument("signed", type=Path)
    install.add_argument("--team", required=True)
    install.add_argument("--apple-root", type=Path, required=True)
    unsigned = modes.add_parser("install", help="Provision, sign, validate and install official Beta 3")
    unsigned.add_argument("source", type=Path)
    unsigned.add_argument("--apple-root", type=Path, required=True)
    unsigned.add_argument("--replace", metavar="TEAM", help="Allow an explicit replacement prompt for this team")
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            result = acquire_source(args.source)
        else:
            artifact.require(sys.platform == "darwin" and sys.stdin.isatty(), "Use interactive macOS Terminal")
            with tempfile.TemporaryDirectory(prefix="zag-installer-") as scratch:
                scratch = Path(scratch)
                if args.mode == "install":
                    result = install_unsigned(args.source, args.apple_root, os.environ.get("ZAG_ANISETTE_URL", ""),
                                              args.replace, scratch, CoreDevice(scratch))
                else:
                    result = install_signed(args.signed, args.team, args.apple_root, scratch, CoreDevice(scratch))
        print(json.dumps(result))
    except KeyboardInterrupt:
        print("Zag Installer cancelled.", file=sys.stderr)
        return 130
    except (OSError, ValueError, KeyError, TypeError, EOFError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        message = str(error) if type(error) is ValueError else type(error).__name__
        print(f"Zag Installer stopped. {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
