#!/usr/bin/env python3
"""Install official Zag Store releases over trusted macOS USB."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import zipfile

import desktop
import handoff
import releases
import native_preflight
import ui_protocol

ROOT = Path(__file__).resolve().parents[2]
LOCAL_UPGRADE_TEAM = "FTB8PRW638"
spec = importlib.util.spec_from_file_location("artifact_validation", ROOT / "scripts/zag-personal-ota.py")
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


class StandaloneUSB:
    """Native USB adapter; installation is disabled in ordinary builds.

    Only an explicitly opted-in, developer-feature Rust build may install.
    Apple's signing and release checks always happen in the macOS frontend.
    """
    def __init__(self, scratch, executable, *, native_install_dev=False):
        self.scratch = scratch
        self.executable = Path(executable)
        if self.executable.is_symlink() or not self.executable.is_file() or not os.access(self.executable, os.X_OK):
            raise ValueError("Standalone USB helper is missing from Zag Installer")
        mode = self.executable.stat()
        if not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o022:
            raise ValueError("Standalone USB helper has insecure ownership or permissions")
        self.identity = None
        self.device_info = None
        self.native_install_dev = native_install_dev

    def _run(self, mode, team=None):
        if mode == "inventory-team":
            artifact.require(isinstance(team, str) and re.fullmatch(r"[A-Z0-9]{10}", team),
                             "Invalid Personal Team for targeted native inventory")
            command = [str(self.executable), mode, team]
        else:
            artifact.require(team is None and mode in ("status", "inventory"),
                             "Only approved native USB read operations are available")
            command = [str(self.executable), mode]
        try:
            result = subprocess.run(command, capture_output=True, timeout=45, check=False)
        except subprocess.TimeoutExpired as error:
            raise ValueError("Native USB inspection timed out") from error
        artifact.require(result.returncode == 0 and len(result.stdout) <= 65536,
                         "Trusted USB inspection failed. Unlock the iPhone and confirm trust.")
        try:
            record = json.loads(result.stdout)
        except (ValueError, UnicodeError) as error:
            raise ValueError("Native USB helper returned an invalid response") from error
        artifact.require(isinstance(record, dict) and record.get("transport") == "system-usbmuxd"
                         and record.get("trust_verified") is True
                         and record.get("developer_mode") is True,
                         "USB trust or Developer Mode is unavailable")
        udid = record.get("udid")
        artifact.require(isinstance(udid, str) and
                         re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})", udid),
                         "Native USB identity is invalid")
        info = record.get("device")
        artifact.require(isinstance(info, dict) and info.get("DeviceClass") == "iPhone"
                         and isinstance(info.get("ProductType"), str)
                         and info["ProductType"].startswith("iPhone")
                         and isinstance(info.get("ProductVersion"), str),
                         "Native USB device metadata is invalid")
        if self.identity is not None:
            artifact.require(udid.casefold() == self.identity.casefold(),
                             "The trusted USB device changed")
        return udid, info, record

    def usb_device(self):
        udid, info, _ = self._run("status")
        if self.identity is None:
            self.identity = udid
        self.device_info = info
        return udid, udid

    def check_compatibility(self, info):
        artifact.require(self.device_info is not None, "Discover the trusted USB device first")
        artifact.require(version_number(self.device_info["ProductVersion"]) >=
                         version_number(info["MinimumOSVersion"]),
                         "Device iOS version is below the release minimum")
        families = info.get("UIDeviceFamily")
        if families is not None:
            artifact.require(isinstance(families, list) and 1 in families,
                             "Release does not support the connected iPhone")

    def apps(self, identifier):
        artifact.require(self.identity is not None and identifier.casefold() == self.identity.casefold(),
                         "The trusted USB device changed")
        _, _, record = self._run("inventory")
        apps = record.get("zag_apps")
        legacy = record.get("legacy_app")
        if legacy is not None:
            artifact.require(isinstance(legacy, dict)
                             and legacy.get("bundleIdentifier") == "com.cwd43.gu29"
                             and isinstance(legacy.get("version"), str)
                             and isinstance(legacy.get("bundleVersion"), str),
                             "Malformed AppTesters legacy inventory")
            version_number(legacy["version"])
            version_number(legacy["bundleVersion"])
        # Absence is ambiguous even after three successful Apple queries.
        # Never treat it as an unoccupied destination in standalone mode.
        artifact.require(isinstance(apps, list) and len(apps) <= 32,
                         "Native app inventory is missing or too large")
        result = []
        known = set()
        for app in apps:
            artifact.require(isinstance(app, dict), "Invalid native application record")
            bundle = app.get("bundleIdentifier")
            artifact.require(isinstance(bundle, str) and
                             (bundle == artifact.ORIGINAL or
                              re.fullmatch(re.escape(artifact.ORIGINAL) + r"\.[A-Z0-9]{10}", bundle))
                             and bundle not in known,
                             "Unexpected or duplicate application identifier")
            known.add(bundle)
            version = app.get("version")
            build = app.get("bundleVersion")
            artifact.require(isinstance(version, str) and isinstance(build, str),
                             "Native installed app has no version and build")
            version_number(version)
            version_number(build)
            result.append({"bundleIdentifier": bundle, "version": version, "bundleVersion": build})
        if not result:
            raise ValueError(
                "Native USB found no mapped Personal Team Zag Store installation"
                + (" (AppTesters copy detected separately)" if legacy else "")
                + "; destination occupancy is unconfirmed"
            )
        return result

    def destination_app(self, identifier, bundle):
        """Read one exact destination without inferring vacancy from broad scans.

        Empty targeted results are an observation, not proof of vacancy.
        A separate verified signing flow and explicit install confirmation
        remain mandatory before the native installer may modify a device.
        """
        artifact.require(self.identity is not None
                         and identifier.casefold() == self.identity.casefold(),
                         "The trusted USB device changed")
        prefix = artifact.ORIGINAL + "."
        artifact.require(isinstance(bundle, str) and bundle.startswith(prefix)
                         and re.fullmatch(r"[A-Z0-9]{10}", bundle[len(prefix):]),
                         "Only a mapped Personal Team destination can be selected")
        _, _, response = self._run("inventory-team", bundle[len(prefix):])
        artifact.require(response.get("targeted_checked") is True,
                         "Targeted native inventory did not complete")
        apps = response.get("targeted_apps")
        artifact.require(isinstance(apps, list) and len(apps) <= 1,
                         "Targeted destination inventory is missing or ambiguous")
        if not apps:
            return None
        record = apps[0]
        artifact.require(isinstance(record, dict)
                         and record.get("bundleIdentifier") == bundle
                         and isinstance(record.get("version"), str)
                         and isinstance(record.get("bundleVersion"), str),
                         "Unexpected targeted native destination")
        version_number(record["version"])
        version_number(record["bundleVersion"])
        return {"bundleIdentifier":bundle,
                "version":record["version"], "bundleVersion":record["bundleVersion"]}

    def preflight_signed(self, signed, release, team, root, certificate, *,
                         previous=None, check_authorization=releases.check_fresh):
        """Validate Apple signing on macOS, then independently bind IPA/device.

        This method performs ONLY local reads and native USB inventory.
        Its returned report is explicitly not an installation authorization.
        """
        artifact.require(self.identity is not None, "Discover the trusted USB iPhone first")
        self._run("status")
        intent = native_preflight.create(signed, release, team, self.identity,
                                         certificate, root, artifact,
                                         check_authorization, previous=previous)
        intent_file = native_preflight.write_private(intent, self.scratch)
        try:
            try:
                result = subprocess.run([str(self.executable), "preflight", str(intent_file)],
                                        capture_output=True, timeout=95, check=False)
            except subprocess.TimeoutExpired as error:
                raise ValueError("Native IPA preflight timed out") from error
            artifact.require(result.returncode == 0 and len(result.stdout) <= 4096,
                             "Native signed IPA/device preflight failed without device writes")
            try:
                report = json.loads(result.stdout)
            except (ValueError, UnicodeError) as error:
                raise ValueError("Native preflight returned invalid JSON") from error
            expected_state = ("expected_upgrade_detected" if previous is not None
                              else "not_reported_by_inventory")
            artifact.require(
                isinstance(report, dict)
                and report.get("preflight") == "validated_local_digest_and_device"
                and report.get("writes_performed") is False
                and report.get("installation_authorized") is False
                and report.get("bundleIdentifier") == intent["bundle_identifier"]
                and report.get("version") == intent["version"]
                and report.get("build") == intent["build"]
                and report.get("sha256") == intent["ipa_sha256"]
                and report.get("operation") == ("upgrade" if previous is not None else "fresh_install")
                and report.get("destination_state") == expected_state,
                "Native preflight returned an inconsistent installation state")
            return report
        finally:
            intent_file.unlink(missing_ok=True)

    def install_signed_developer(self, identifier, signed, release, team, root, certificate,
                                 *, previous=None, check_authorization=releases.check_fresh,
                                 earlier=None):
        """Developer-feature-only native installation of the exact verified IPA.

        A preflight record is only a checksum/device binding. The authorization
        is the current validated Apple signing result + user approval + pinned
        release check, NOT the mutable JSON record.
        """
        artifact.require(self.native_install_dev is True,
                         "Native USB installation is disabled in the packaged installer")
        artifact.require(self.identity is not None
                         and identifier.casefold() == self.identity.casefold(),
                         "The trusted USB device changed")
        check_authorization(release)
        self._run("status")
        plan = native_preflight.create(signed, release, team, self.identity,
                                       certificate, root, artifact,
                                       check_authorization, previous=previous)
        if earlier is not None:
            artifact.require(
                isinstance(earlier, dict)
                and earlier.get("sha256") == plan["ipa_sha256"]
                and earlier.get("bundleIdentifier") == plan["bundle_identifier"]
                and earlier.get("version") == plan["version"]
                and earlier.get("build") == plan["build"]
                and earlier.get("installation_authorized") is False,
                "Signed IPA changed after the approved native preflight")
        intent_file = native_preflight.write_private(plan, self.scratch)
        try:
            operation = "UPGRADE" if previous is not None else "INSTALL"
            phrase = f"{operation} {plan['bundle_identifier']} ON {self.identity}"
            token = secrets.token_hex(16)
            try:
                response = subprocess.run(
                    [str(self.executable), "install-signed-dev", str(intent_file),
                     token, phrase], capture_output=True, timeout=1800, check=False)
            except subprocess.TimeoutExpired as error:
                raise ValueError("Native developer installation timed out; check device inventory") from error
            artifact.require(response.returncode == 0 and len(response.stdout) <= 4096,
                             "Native developer installation failed; check USB and device inventory")
            try:
                report = json.loads(response.stdout)
            except (ValueError, UnicodeError) as error:
                raise ValueError("Native installation returned invalid JSON") from error
            artifact.require(
                isinstance(report, dict)
                and report.get("mode") == "native-install-dev"
                and report.get("installed") is True
                and report.get("installed_bundle") == plan["bundle_identifier"]
                and report.get("version") == plan["version"]
                and report.get("build") == plan["build"],
                "Native installation completion did not verify expected bundle and build")
            return report
        finally:
            intent_file.unlink(missing_ok=True)

    def install(self, identifier, path):
        raise ValueError("Native USB installation accepts only a verified IPA in an opted-in developer build")

    def launch_app(self, identifier, bundle):
        raise ValueError("Native app launch has not been validated")

    def _handoff(self, operation, identifier, bundle, remote, path):
        artifact.require(operation in ("handoff-read", "handoff-write"),
                         "Unsupported USB handoff operation")
        artifact.require(self.identity is not None
                         and identifier.casefold() == self.identity.casefold(),
                         "The trusted USB device changed")
        artifact.require(re.fullmatch(re.escape(artifact.ORIGINAL) + r"\.[A-Z0-9]{10}", bundle),
                         "Only an exact Personal Team Zag Store bundle can receive signing setup")
        artifact.require(isinstance(path, (str, Path)), "Invalid local handoff path")
        # Check the original trusted iPhone immediately before every I/O operation.
        self._run("status")
        command = [str(self.executable), operation, identifier, bundle,
                   remote, str(Path(path).absolute()), f"HANDOFF {bundle}"]
        try:
            result = subprocess.run(command, capture_output=True, timeout=50, check=False)
        except subprocess.TimeoutExpired as error:
            raise ValueError("Native signing handoff timed out") from error
        artifact.require(result.returncode == 0 and len(result.stdout) <= 4096,
                         "Native signing handoff failed or the app container is inaccessible")
        try:
            receipt = json.loads(result.stdout)
        except (ValueError, UnicodeError) as error:
            raise ValueError("Malformed native signing handoff receipt") from error
        artifact.require(isinstance(receipt, dict) and receipt.get("operation") == operation
                         and receipt.get("bundleIdentifier") == bundle
                         and isinstance(receipt.get("bytes"), int)
                         and 0 < receipt["bytes"] <= 24 * 1024
                         and isinstance(receipt.get("sha256"), str)
                         and re.fullmatch(r"[a-f0-9]{64}", receipt["sha256"]),
                         "Invalid native handoff receipt")
        if operation == "handoff-read":
            artifact.require(Path(path).is_file() and not Path(path).is_symlink()
                             and Path(path).stat().st_size == receipt["bytes"]
                             and hashlib.sha256(Path(path).read_bytes()).hexdigest() == receipt["sha256"],
                             "Private signing request did not match native readback")
        else:
            artifact.require(hashlib.sha256(Path(path).read_bytes()).hexdigest() == receipt["sha256"],
                             "Encrypted signing response did not match native delivery")
        return receipt

    def copy_from_app(self, identifier, bundle, remote, destination):
        return self._handoff("handoff-read", identifier, bundle, remote, destination)

    def copy_to_app(self, identifier, bundle, source, remote):
        return self._handoff("handoff-write", identifier, bundle, remote, source)



class CoreDevice:
    def __init__(self, scratch):
        self.scratch = scratch

    def run(self, stage, *args, timeout=180):
        report = self.scratch / "coredevice.json"
        report.unlink(missing_ok=True)
        result = subprocess.run(
            ["xcrun", "devicectl", *args, "--json-output", str(report)],
            capture_output=True, timeout=timeout,
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


    def launch_app(self, identifier, bundle):
        self.run("Open Signing Setup", "device", "process", "launch", "--device", identifier, bundle, timeout=15)

    def copy_from_app(self, identifier, bundle, remote, destination):
        self.run("Read the iPhone handoff request (prepare it in Zag Store first)", "device", "copy", "from",
                 "--device", identifier, "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                 "--source", remote, "--destination", str(destination), timeout=10)

    def copy_to_app(self, identifier, bundle, source, remote):
        self.run("Deliver private signing setup message", "device", "copy", "to",
                 "--device", identifier, "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                 "--source", str(source), "--destination", remote, timeout=15)


def version_number(value):
    artifact.require(isinstance(value, str) and re.fullmatch(r"[0-9]{1,9}(?:\.[0-9]{1,9}){0,3}", value),
                     "Invalid or unavailable version in device or release metadata")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (4 - len(parts))


def installed_app(device, target, expected):
    if isinstance(device, StandaloneUSB):
        return device.destination_app(target, expected)
    matches = [app for app in device.apps(target) if app.get("bundleIdentifier") == expected]
    artifact.require(len(matches) <= 1, "Destination inventory is ambiguous")
    return matches[0] if matches else None


def check_destination(installed, release, upgrade, *, replace_same_build=False):
    if not upgrade:
        artifact.require(installed is None, "Destination is already installed. Use --upgrade TEAM.")
        return
    artifact.require(installed is not None, "Upgrade destination is not installed")
    current = version_number(installed.get("version")), version_number(installed.get("bundleVersion"))
    candidate = version_number(release["version"]), version_number(release["build"])
    if replace_same_build:
        artifact.require(installed["version"] == release["version"] and installed["bundleVersion"] == release["build"],
                         "Local same-build replacement requires the exact installed version and build")
    else:
        artifact.require(candidate > current, "Signed release is not newer than the installed build")


def confirm_action(approve, message, expected, action):
    channel = getattr(approve, "__self__", None)
    if isinstance(channel, ui_protocol.Channel):
        return channel.confirm(message, expected, action)
    return approve(f"{message} Type {expected}: ")


def validate_and_install(signed, release, team, apple_root, scratch, device, target, udid, approve, certificate,
                         installed=None, check_authorization=releases.check_fresh, *, replace_same_build=False):
    expected = artifact.mapped_bundle(team)
    evidence = artifact.validate(signed, team, udid, apple_root, expected_signer=certificate)
    artifact.require(evidence["bundle_identifier"] == expected and evidence["build"] == release["build"],
                     "Signed artifact differs from the authorized bundle or build")
    staged = scratch / "staged"
    with zipfile.ZipFile(signed) as archive:
        relative, info = artifact.main_bundle(archive)
        artifact.require(info.get("CFBundleShortVersionString") == release["version"]
                         and info.get("MinimumOSVersion") == release["minimum_os"],
                         "Signed artifact differs from the authorized version or minimum OS")
        if not isinstance(device, StandaloneUSB):
            # CoreDevice installs the extracted .app directory; native AFC
            # stages the intact Apple-signed IPA without rewriting its bytes.
            staged.mkdir()
            artifact.extract(archive, staged)
    check_destination(installed, release, installed is not None, replace_same_build=replace_same_build)
    label = f"{expected} {release['version']} ({release['build']})"
    if replace_same_build:
        confirmation = f"REPLACE {expected}"
        operation = "Replace with local same-build candidate"
    else:
        confirmation = f"UPGRADE {expected}" if installed is not None else "INSTALL"
        operation = "Upgrade in place" if installed is not None else "Install as a separate app"
    check_authorization(release)
    native_receipt = None
    prior = None
    if isinstance(device, StandaloneUSB):
        # The signing validator has already passed. Independently verify the
        # exact signed IPA checksum, wired device, minimum iOS, and targeted
        # destination before asking the user to approve any device write.
        prior = ({"version": installed["version"], "build": installed["bundleVersion"]}
                 if installed is not None else None)
        native_receipt = device.preflight_signed(
            signed, release, team, apple_root, certificate,
            previous=prior, check_authorization=check_authorization)
    artifact.require(confirm_action(approve, f"{operation} {label}?", confirmation,
                                     "Replace" if replace_same_build else ("Upgrade" if installed is not None else "Install")) == confirmation,
                     "Installation cancelled")
    artifact.require(device.usb_device() == (target, udid), "The trusted USB device changed")
    device.check_compatibility(info)
    artifact.require(installed_app(device, target, expected) == installed,
                     "Destination inventory changed. Installation cancelled.")
    check_authorization(release)
    if isinstance(device, StandaloneUSB):
        device.install_signed_developer(
            target, signed, release, team, apple_root, certificate,
            previous=prior, check_authorization=check_authorization, earlier=native_receipt)
    else:
        device.install(target, staged / relative)
    observed = installed_app(device, target, expected)
    artifact.require(observed and observed.get("bundleVersion") == release["build"]
                     and observed.get("version") == release["version"],
                     "Installer returned success but inventory did not verify the app and build")
    result = {"installed_bundle": expected, "version": release["version"], "build": release["build"]}
    if replace_same_build:
        result["replaced_same_build"] = True
    return result


def install_release(release, release_helper, apple_root, endpoint, upgrade_team, scratch, device, cache, approve=input,
                    *, defer_setup=False):
    local_source = scratch / "official.ipa"
    releases.acquire(artifact, release, release_helper, local_source)
    return install_verified(release, local_source, apple_root, endpoint, upgrade_team, scratch, device, cache,
                            approve, releases.check_fresh, defer_setup=defer_setup)


def install_verified(release, local_source, apple_root, endpoint, upgrade_team, scratch, device, cache,
                     approve, check_authorization, *, replace_same_build=False, defer_setup=False):
    artifact.require(not replace_same_build or upgrade_team == LOCAL_UPGRADE_TEAM,
                     "Same-build replacement is restricted to the experimental Personal Team copy")
    endpoint = desktop.provider_origin(endpoint) if endpoint else None
    if upgrade_team is not None:
        artifact.mapped_bundle(upgrade_team)
    root = scratch / "apple-root.pem"
    desktop.prepare_profile_root(artifact, ROOT, root, apple_root)

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
        check_destination(installed, release, upgrade, replace_same_build=replace_same_build)

    def choose_team(teams):
        teams = [team for team in teams if isinstance(team["id"], str) and artifact.TEAM.fullmatch(team["id"])
                 and (not upgrade or team["id"] == upgrade_team)]
        artifact.require(teams, "Apple returned no matching Personal Team")
        if len(teams) == 1:
            team = teams[0]["id"]
            print(f"Selected Personal Team: {json.dumps(teams[0]['name'])} ({team})", flush=True)
        else:
            options = "\n".join(f"{index}. {json.dumps(entry['name'])} ({entry['id']})"
                                for index, entry in enumerate(teams, 1))
            choice = approve("Select your Personal Team by number, or Enter to cancel:\n" + options).strip()
            artifact.require(re.fullmatch(r"[0-9]{1,5}", choice) and 1 <= int(choice) <= len(teams),
                             "Team selection cancelled")
            team = teams[int(choice) - 1]["id"]
        artifact.require(device.usb_device() == (target, udid), "The trusted USB device changed")
        current = installed_app(device, target, artifact.mapped_bundle(team))
        check_destination(current, release, upgrade, replace_same_build=replace_same_build)
        artifact.require(current == installed, "Destination inventory changed before provisioning")
        check_authorization(release)
        artifact.require(confirm_action(approve, f"Use {team} as your Personal Team and allow Apple provisioning?", "PROVISION", "Continue")
                         == "PROVISION", "Apple provisioning cancelled")
        return team

    auth, helper, openssl, anisette = cache.installer_tools(ROOT, native=endpoint is None)
    store = desktop.Keychain(helper)
    portal = desktop.Provisioning(endpoint, udid, store, openssl, choose_team, approve, anisette, upgrade, components)
    # Only the separately packaged native development GUI can offer account
    # portability, and only to a fresh, capability-advertising signed release.
    account_bootstrap = (defer_setup and not upgrade and endpoint is None and anisette is not None
                         and info.get("ZagAutomaticSigningSetup") is True
                         and info.get("ZagDesktopAccountBootstrap") is True)
    if account_bootstrap:
        artifact.require(confirm_action(approve,
            "Use the Apple ID from this Mac in the new Zag Store installation? "
            "Only its developer session and signing identity will be transferred privately over USB.",
            "ACCOUNT", "Continue") == "ACCOUNT", "Apple ID transfer cancelled")
        portal.account_bootstrap = True
    team, identity, profiles = portal.run(auth)
    signed = desktop.sign(artifact, app, relative, team, udid, identity, profiles, components, root, helper, scratch)
    result = validate_and_install(signed, release, team, root, scratch, device, target, udid,
                                  approve, identity.certificate, installed, check_authorization,
                                  replace_same_build=replace_same_build)
    try:
        store.write(portal.receipt_item, hashlib.sha256(identity.certificate).hexdigest().encode("ascii"))
        if info.get("ZagAutomaticSigningSetup") is True:
            handoff.save_receipt(store, udid, team, identity.key_item, identity.certificate, result)
    except (OSError, ValueError, subprocess.SubprocessError):
        result["signing_receipt_saved"] = False
    if info.get("ZagAutomaticSigningSetup") is True:
        if defer_setup and not (account_bootstrap and portal.account_credential):
            result["signing_setup"] = "incomplete"
            print("Installation verified. Use Resume Signing Setup when ready; no pairing changes have been requested.", flush=True)
            return result
        print(f"Installed {result['installed_bundle']}. Starting Signing Setup.", flush=True)
        try:
            observed = installed_app(device, target, result["installed_bundle"])
            artifact.require(observed and observed.get("version") == result["version"]
                             and observed.get("bundleVersion") == result["build"], "The installed Personal Team copy changed")
            result.update(handoff.automatic(ROOT, cache, scratch, device, target, udid, team, identity.key_item,
                                            identity.certificate, identity.key, openssl, observed,
                                            account_credential=portal.account_credential if account_bootstrap else None))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"Signing Setup is incomplete. {error if type(error) is ValueError else 'Check USB and retry.'}", file=sys.stderr)
            result["signing_setup"] = "incomplete"
        finally:
            portal.account_credential = None
    return result


def stage_local_candidate(source, candidate, expected_sha, version, build):
    artifact.require(re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha), "Supply a 64-digit SHA-256")
    version_number(version)
    version_number(build)
    digest = hashlib.sha256()
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        artifact.require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= releases.MAX_IPA,
                         "Local candidate must be a nonempty regular IPA within the size limit")
        size = 0
        with candidate.open("xb") as output:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                size += len(chunk)
                artifact.require(size <= releases.MAX_IPA, "Local candidate exceeded the size limit")
                digest.update(chunk)
                output.write(chunk)
    artifact.require(digest.hexdigest() == expected_sha.lower(), "Local candidate SHA-256 does not match")
    with zipfile.ZipFile(candidate) as archive:
        relative, info = artifact.main_bundle(archive)
        artifact.require(info.get("CFBundleIdentifier") == artifact.ORIGINAL
                         and info.get("CFBundleShortVersionString") == version
                         and info.get("CFBundleVersion") == build,
                         "Local candidate bundle identifier, version or build does not match")
        artifact.require(not any(name.startswith(str(relative) + "/") and name.endswith("/embedded.mobileprovision")
                                 for name in archive.namelist()),
                         "Local candidate must not contain a provisioning profile")
        minimum_os = info.get("MinimumOSVersion")
        version_number(minimum_os)
    return {"version": version, "build": build, "minimum_os": minimum_os, "sha256": expected_sha.lower()}


def upgrade_local_candidate(source, sha256, version, build, apple_root, scratch, device, cache, approve=input,
                            *, replace_same_build=False):
    candidate = scratch / "local-candidate.ipa"
    release = stage_local_candidate(source, candidate, sha256, version, build)

    def check_digest(authorized):
        artifact.require(artifact.sha(candidate) == authorized["sha256"], "Local candidate changed after verification")

    return install_verified(release, candidate, apple_root, None, LOCAL_UPGRADE_TEAM,
                            scratch, device, cache, approve, check_digest, replace_same_build=replace_same_build)


def native_gui_helper(args):
    """Only the explicitly opted-in, bundled development GUI may use writes."""
    artifact.require(args.ui_pipe and args.usb_transport == "standalone"
                     and args.mode in ("install", "setup")
                     and not args.native_install_dev and args.native_dev_helper is None,
                     "Native GUI developer mode requires bundled standalone install or setup")
    expected = ROOT / "helpers"
    artifact.require(args.precompiled_helpers == expected and not expected.is_symlink(),
                     "Native GUI developer mode requires its bundled helpers")
    helper = expected / "zag-usb"
    StandaloneUSB(ROOT, helper)  # Check ownership, permissions and executable type.
    result = subprocess.run([str(helper), "capabilities"], capture_output=True, timeout=10)
    artifact.require(result.returncode == 0 and len(result.stdout) <= 4096,
                     "Bundled native USB capability check failed")
    artifact.require(json.loads(result.stdout) == {"native_install_dev": True},
                     "Bundled native USB installation is not enabled")
    return helper


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ui-pipe", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--precompiled-helpers", type=Path, metavar="DIRECTORY",
                        help=argparse.SUPPRESS)
    parser.add_argument("--usb-transport", choices=("coredevice", "standalone"),
                        default="coredevice", help=argparse.SUPPRESS)
    parser.add_argument("--native-install-dev", action="store_true",
                        help=argparse.SUPPRESS)
    parser.add_argument("--native-dev-helper", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--native-gui-dev", action="store_true", help=argparse.SUPPRESS)
    modes = parser.add_subparsers(dest="mode", required=True)
    prepare = modes.add_parser("prepare", help="Download and verify the latest authorized release")
    prepare.add_argument("destination", type=Path)
    install = modes.add_parser("install", help="Provision, sign, validate and install the latest authorized release")
    install.add_argument("--apple-root", type=Path, help="Optional PEM copy of the pinned Apple Root CA")
    install.add_argument("--upgrade", metavar="TEAM", help="Require an existing copy for this Personal Team")
    local = modes.add_parser("upgrade-local-candidate", help="Developer-only upgrade of the experimental Personal Team copy")
    local.add_argument("ipa", type=Path)
    local.add_argument("--sha256", required=True, help="Expected SHA-256 obtained independently of the IPA")
    local.add_argument("--version", required=True)
    local.add_argument("--build", required=True)
    local.add_argument("--replace-same-build", action="store_true",
                       help="Explicitly replace the experimental copy at the exact installed version and build")
    local.add_argument("--apple-root", type=Path, help="Optional PEM copy of the pinned Apple Root CA")
    setup = modes.add_parser("setup", help="Retry automatic signing setup without reinstalling")
    setup.add_argument("--team", required=True)
    recovery = modes.add_parser("handoff", help="Send the existing signing identity to an installed Personal Team copy")
    recovery.add_argument("--team", required=True)
    for mode in (prepare, install):
        mode.add_argument("--expect-tag", help="Require this exact release tag in the signed channel")
    args = parser.parse_args()
    channel = None
    try:
        artifact.require(sys.platform == "darwin", "Use macOS")
        if args.ui_pipe:
            artifact.require(args.mode == "install" or (args.mode == "setup" and args.native_gui_dev),
                             "Graphical transport only supports official installation or native setup recovery")
            channel = ui_protocol.Channel()
            desktop.secret = lambda prompt: channel.ask(prompt, secret=True)
            approve = channel.ask
        else:
            artifact.require(args.mode == "prepare" or sys.stdin.isatty(), "Use interactive macOS Terminal")
            approve = input
        # In standalone preview, no Apple sign-in, certificate issuance, profile
        # registration or download may begin while device writes are disabled.
        developer_native = (
            args.usb_transport == "standalone" and args.native_install_dev
            and args.mode in ("install", "setup") and not args.ui_pipe and sys.stdin.isatty()
        )
        gui_helper = native_gui_helper(args) if args.native_gui_dev else None
        artifact.require(args.usb_transport != "standalone"
                         or args.mode == "prepare" or developer_native or gui_helper is not None,
                         "Native USB installation and signing handoff are not yet enabled")
        artifact.require(not args.native_install_dev or developer_native,
                         "Native developer mode requires interactive standalone install or setup")
        artifact.require(args.native_dev_helper is None or developer_native,
                         "Native developer helper requires interactive standalone install or setup")
        if developer_native:
            helper = args.native_dev_helper
            artifact.require(helper is not None and helper.is_absolute()
                             and not helper.is_symlink() and helper.is_file()
                             and os.access(helper, os.X_OK),
                             "Native developer mode requires an absolute executable --native-dev-helper")
        with desktop.locked_cache(precompiled=args.precompiled_helpers) as cache:
            if args.mode == "prepare":
                release, release_helper = releases.discover(ROOT, cache, args.expect_tag)
                with tempfile.TemporaryDirectory(prefix=".zag-release-", dir=args.destination.parent) as directory:
                    candidate = Path(directory) / "release.ipa"
                    result = releases.acquire(artifact, release, release_helper, candidate)
                    candidate.chmod(0o600)
                    os.link(candidate, args.destination)
            else:
                with tempfile.TemporaryDirectory(prefix="zag-installer-") as directory:
                    scratch = Path(directory)
                    helper_root = (args.precompiled_helpers if args.precompiled_helpers is not None
                                   else ROOT / "tools/zag-installer/native-usb/target/release")
                    device = (CoreDevice(scratch) if args.usb_transport == "coredevice"
                              else StandaloneUSB(scratch, args.native_dev_helper if developer_native else
                                                 (gui_helper if gui_helper is not None else helper_root / "zag-usb"),
                                                 native_install_dev=developer_native or gui_helper is not None))
                    if args.mode in ("handoff", "setup"):
                        artifact.mapped_bundle(args.team)
                        command = handoff.send if args.mode == "handoff" else handoff.retry
                        if gui_helper is not None:
                            bundle = artifact.mapped_bundle(args.team)
                            artifact.require(confirm_action(approve, f"Resume Signing Setup for {bundle}?", "SETUP", "Resume Setup") == "SETUP",
                                             "Signing Setup cancelled")
                        result = command(ROOT, cache, scratch, device, args.team)
                        if gui_helper is not None:
                            result["installed_bundle"] = bundle
                    else:
                        if args.mode == "upgrade-local-candidate":
                            result = upgrade_local_candidate(args.ipa, args.sha256, args.version, args.build,
                                                             args.apple_root, scratch, device, cache,
                                                             replace_same_build=args.replace_same_build)
                        else:
                            release, release_helper = releases.discover(ROOT, cache, args.expect_tag)
                            result = install_release(release, release_helper, args.apple_root, os.environ.get("ZAG_ANISETTE_URL", ""),
                                                     args.upgrade, scratch, device, cache, approve=approve,
                                                     defer_setup=gui_helper is not None)
        if channel is not None:
            channel.send({"type": "finished", "result": result})
        else:
            print(json.dumps(result))
        if result.get("signing_setup") == "incomplete":
            return 1
    except KeyboardInterrupt:
        if channel is not None:
            channel.send({"type": "error", "message": "Zag Installer cancelled."})
        print("Zag Installer cancelled.", file=sys.stderr)
        return 130
    except (OSError, ValueError, KeyError, TypeError, EOFError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        message = str(error) if type(error) is ValueError else type(error).__name__
        if channel is not None:
            channel.send({"type": "error", "message": f"Zag Installer stopped. {message}"})
        print(f"Zag Installer stopped. {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
