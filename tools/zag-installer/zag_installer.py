#!/usr/bin/env python3
"""Install official Zag Store releases over trusted macOS USB."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

import desktop
import releases

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("artifact_validation", ROOT / "scripts/zag-personal-ota.py")
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


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
        self.device_info = device
        return device["identifier"], udid

    def check_compatibility(self, info):
        os_version = self.device_info.get("deviceProperties", {}).get("osVersionNumber")
        artifact.require(version_number(os_version) >= version_number(info["MinimumOSVersion"]),
                         "Device iOS version is below the release minimum")
        families = info.get("UIDeviceFamily")
        if families is not None:
            product = self.device_info.get("hardwareProperties", {}).get("productType", "")
            family = 1 if product.startswith(("iPhone", "iPod")) else 2 if product.startswith("iPad") else None
            artifact.require(isinstance(families, list) and family is not None and family in families,
                             "Release does not support the connected device family")

    def apps(self, identifier):
        return self.run("Installed app inventory", "device", "info", "apps", "--device", identifier,
                        "--include-all-apps")["apps"]

    def install(self, identifier, path):
        self.run("Installation", "device", "install", "app", "--device", identifier, str(path))


def version_number(value):
    artifact.require(isinstance(value, str) and re.fullmatch(r"[0-9]{1,9}(?:\.[0-9]{1,9}){0,3}", value),
                     "Invalid or unavailable version in device or release metadata")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (4 - len(parts))


def installed_app(device, target, expected):
    matches = [app for app in device.apps(target) if app.get("bundleIdentifier") == expected]
    artifact.require(len(matches) <= 1, "Destination inventory is ambiguous")
    return matches[0] if matches else None


def check_destination(installed, release, upgrade):
    if not upgrade:
        artifact.require(installed is None, "Destination is already installed. Use --upgrade TEAM.")
        return
    artifact.require(installed is not None, "Upgrade destination is not installed")
    current = version_number(installed.get("version")), version_number(installed.get("bundleVersion"))
    candidate = version_number(release["version"]), version_number(release["build"])
    artifact.require(candidate > current, "Signed release is not newer than the installed build")


def validate_and_install(signed, release, team, apple_root, scratch, device, target, udid, approve, certificate, installed=None):
    expected = artifact.mapped_bundle(team)
    evidence = artifact.validate(signed, team, udid, apple_root, expected_signer=certificate)
    artifact.require(evidence["bundle_identifier"] == expected and evidence["build"] == release["build"],
                     "Signed artifact differs from the authorized bundle or build")
    staged = scratch / "staged"
    staged.mkdir()
    with zipfile.ZipFile(signed) as archive:
        relative, info = artifact.main_bundle(archive)
        artifact.require(info.get("CFBundleShortVersionString") == release["version"]
                         and info.get("MinimumOSVersion") == release["minimum_os"],
                         "Signed artifact differs from the authorized version or minimum OS")
        artifact.extract(archive, staged)
    check_destination(installed, release, installed is not None)
    label = f"{expected} {release['version']} ({release['build']})"
    confirmation = f"UPGRADE {expected}" if installed is not None else "INSTALL"
    operation = "Upgrade in place" if installed is not None else "Install as a separate app"
    releases.check_fresh(release)
    artifact.require(approve(f"{operation} {label}? Type {confirmation}: ") == confirmation,
                     "Installation cancelled")
    artifact.require(device.usb_device() == (target, udid), "The trusted USB device changed")
    device.check_compatibility(info)
    artifact.require(installed_app(device, target, expected) == installed,
                     "Destination inventory changed. Installation cancelled.")
    releases.check_fresh(release)
    device.install(target, staged / relative)
    observed = installed_app(device, target, expected)
    artifact.require(observed and observed.get("bundleVersion") == release["build"]
                     and observed.get("version") == release["version"],
                     "Installer returned success but inventory did not verify the app and build")
    return {"installed_bundle": expected, "version": release["version"], "build": release["build"]}


def install_release(release, apple_root, endpoint, upgrade_team, scratch, device, cache, approve=input):
    endpoint = desktop.provider_origin(endpoint) if endpoint else None
    if upgrade_team is not None:
        artifact.mapped_bundle(upgrade_team)
    local_source = scratch / "official.ipa"
    releases.acquire(artifact, release, local_source)
    root = scratch / "apple-root.pem"
    artifact.require(apple_root.is_file() and 0 < apple_root.stat().st_size < 65536, "Invalid Apple root PEM")
    shutil.copyfile(apple_root, root)
    desktop.verify_root(artifact, root)

    unsigned = scratch / "unsigned"
    unsigned.mkdir()
    with zipfile.ZipFile(local_source) as archive:
        relative, info = artifact.main_bundle(archive)
        artifact.extract(archive, unsigned)
    app = unsigned / relative
    components = desktop.signing_components(app, artifact.ORIGINAL)
    target, udid = device.usb_device()
    device.check_compatibility(info)
    upgrade = upgrade_team is not None
    installed = None
    if upgrade:
        installed = installed_app(device, target, artifact.mapped_bundle(upgrade_team))
        check_destination(installed, release, upgrade)

    def choose_team(teams):
        teams = [team for team in teams if isinstance(team["id"], str) and artifact.TEAM.fullmatch(team["id"])
                 and (not upgrade or team["id"] == upgrade_team)]
        artifact.require(teams, "Apple returned no matching Personal Team")
        for index, team in enumerate(teams, 1):
            print(f"  {index}. {json.dumps(team['name'])} ({team['id']})")
        choice = approve("Select your Personal Team by number, or Enter to cancel: ").strip()
        artifact.require(re.fullmatch(r"[0-9]{1,5}", choice) and 1 <= int(choice) <= len(teams),
                         "Team selection cancelled")
        team = teams[int(choice) - 1]["id"]
        artifact.require(device.usb_device() == (target, udid), "The trusted USB device changed")
        current = installed_app(device, target, artifact.mapped_bundle(team))
        check_destination(current, release, upgrade)
        artifact.require(current == installed, "Destination inventory changed before provisioning")
        releases.check_fresh(release)
        artifact.require(approve(f"Use {team} as your Personal Team and allow Apple provisioning? Type PROVISION: ")
                         == "PROVISION", "Apple provisioning cancelled")
        return team

    auth, helper, openssl, anisette = cache.installer_tools(ROOT, native=endpoint is None)
    store = desktop.Keychain(helper)
    portal = desktop.Provisioning(endpoint, udid, store, openssl, choose_team, approve, anisette, upgrade, components)
    team, identity, profiles = portal.run(auth)
    signed = desktop.sign(artifact, app, relative, team, udid, identity, profiles, components, root, helper, scratch)
    result = validate_and_install(signed, release, team, root, scratch, device, target, udid, approve, identity.certificate, installed)
    try:
        store.write(portal.receipt_item, hashlib.sha256(identity.certificate).hexdigest().encode("ascii"))
    except (OSError, ValueError, subprocess.SubprocessError):
        result["signing_receipt_saved"] = False
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    prepare = modes.add_parser("prepare", help="Download and verify the latest authorized release")
    prepare.add_argument("destination", type=Path)
    install = modes.add_parser("install", help="Provision, sign, validate and install the latest authorized release")
    install.add_argument("--apple-root", type=Path, required=True)
    install.add_argument("--upgrade", metavar="TEAM", help="Require an existing copy for this Personal Team")
    for mode in (prepare, install):
        mode.add_argument("--expect-tag", help="Require this exact release tag in the signed channel")
    args = parser.parse_args()
    try:
        artifact.require(sys.platform == "darwin", "Use macOS Terminal")
        artifact.require(args.mode != "install" or sys.stdin.isatty(), "Use interactive macOS Terminal")
        with desktop.locked_cache() as cache:
            release = releases.discover(ROOT, cache, args.expect_tag)
            if args.mode == "prepare":
                with tempfile.TemporaryDirectory(prefix=".zag-release-", dir=args.destination.parent) as directory:
                    candidate = Path(directory) / "release.ipa"
                    result = releases.acquire(artifact, release, candidate)
                    candidate.chmod(0o600)
                    os.link(candidate, args.destination)
            else:
                with tempfile.TemporaryDirectory(prefix="zag-installer-") as directory:
                    scratch = Path(directory)
                    result = install_release(release, args.apple_root, os.environ.get("ZAG_ANISETTE_URL", ""),
                                             args.upgrade, scratch, CoreDevice(scratch), cache)
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
