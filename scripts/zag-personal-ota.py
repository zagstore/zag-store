#!/usr/bin/env python3
"""Operator-only Personal Team OTA preflight and preview publication."""

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from urllib.parse import parse_qs, urlsplit, urlencode

APPLE_ROOT = "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024"
ORIGINAL = "app.zagstore.ios"
PROBE = "app.zagstore.ota-probe"
APPTESTERS_BUNDLE = "com.cwd43.gu29"
PREVIEW = "preview.zagstore.app"
DELIVERY = Path("/var/www/zagstore-preview/zag-ota-jobs")
SERVICES = Path("/opt/zagstore/signing-engine/services")
SECRET = Path("/opt/zagstore/signing-engine/private-secrets/ota-secret")
TEAM = re.compile(r"[A-Z0-9]{10}")
SHA = re.compile(r"[a-f0-9]{64}")
JOB = re.compile(r"[a-f0-9]{32}")
DEVELOPMENT = "1.2.840.113635.100.6.1.2"
THIN_MAGICS = {bytes.fromhex(magic) for magic in ("feedface", "cefaedfe", "feedfacf", "cffaedfe")}
FAT_MAGICS = {
    bytes.fromhex(magic): (order, wide) for magic, order, wide in (
        ("cafebabe", ">", False), ("bebafeca", "<", False),
        ("cafebabf", ">", True), ("bfbafeca", "<", True),
    )
}
SAFE_STDERR = re.compile(
    r"CSSMERR_[A-Z0-9_]+|errSec[A-Za-z0-9_]+|"
    r"In architecture: [a-zA-Z0-9_]+|"
    r"invalid requirement specification|No such file or directory|"
    r"code object is not signed at all|code or signature modified|"
    r"a sealed resource is missing or invalid|binary contains an invalid entitlements blob",
    re.IGNORECASE,
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(*args, stage=None, component=None):
    result = subprocess.run(args, capture_output=True, check=False, timeout=120)
    tool = Path(args[0]).name
    if result.returncode:
        context = stage or tool
        if component is not None:
            safe_path = re.sub(r"[^A-Za-z0-9._ /-]", "_", str(component))[:240]
            context += f" [{safe_path}]"
        details = list(dict.fromkeys(SAFE_STDERR.findall(result.stderr.decode("utf-8", "replace"))))[:8]
        summary = "; ".join(details) if details else "unrecognised output redacted" if result.stderr else "empty"
        raise ValueError(f"{context}: {tool} exited {result.returncode}; stderr: {summary}")
    return result.stdout


def is_macho(path):
    with path.open("rb") as stream:
        header = stream.read(8)
        magic = header[:4]
        if magic in THIN_MAGICS:
            return True
        if magic not in FAT_MAGICS or len(header) != 8:
            return False
        order, wide = FAT_MAGICS[magic]
        count, = struct.unpack(order + "I", header[4:])
        if not 1 <= count <= 64:
            return False
        layout = order + ("IIQQII" if wide else "IIIII")
        width = struct.calcsize(layout)
        table = stream.read(count * width)
        if len(table) != count * width:
            return False
        file_size = path.stat().st_size
        for i in range(count):
            _, _, offset, size, *_ = struct.unpack_from(layout, table, i * width)
            if offset < 8 + len(table) or size < 4 or offset + size > file_size:
                return False
            stream.seek(offset)
            if stream.read(4) not in THIN_MAGICS:
                return False
        return True


def verify_development_certificate(component, relative):
    requirement = f"anchor apple generic and certificate leaf[field.{DEVELOPMENT}] exists"
    command("codesign", "--verify", "--strict", "-R=" + requirement, str(component),
            stage="Apple Development certificate requirement", component=relative)


def read_signed_entitlements(component, relative):
    signed_xml = command("codesign", "--display", "--entitlements", ":-", str(component),
                         stage="Read signed entitlements", component=relative)
    require(signed_xml, f"Read signed entitlements [{relative}]: codesign returned no signed XML")
    return plistlib.loads(signed_xml)


def main_bundle(archive):
    names = [i for i in archive.infolist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", i.filename)]
    require(len(names) == 1 and names[0].file_size <= 1024 * 1024, "Expected exactly one app")
    metadata = plistlib.loads(archive.read(names[0]))
    return PurePosixPath(names[0].filename).parent, metadata


def mapped_bundle(team, probe=False):
    require(TEAM.fullmatch(team), "Invalid expected team")
    return (PROBE if probe else ORIGINAL) + "." + team


def verify_identity(metadata, team, probe=False):
    expected = mapped_bundle(team, probe)
    identifier = metadata.get("CFBundleIdentifier")
    # Match ZagBundleIdentifierMapping. The installed AppTesters identifier
    # and all alternative identifiers are refused here.
    require(identifier != APPTESTERS_BUNDLE, "Refusing the existing AppTesters bundle identifier")
    require(identifier == expected, "IPA does not match the exact mapped experiment identifier")
    if probe:
        require(metadata.get("CFBundleExecutable") == "OTAProbe"
                and metadata.get("CFBundleShortVersionString") == "1.0"
                and metadata.get("CFBundleVersion") == "1", "Unexpected probe build metadata")
    build = metadata.get("CFBundleVersion")
    require(isinstance(build, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build), "Invalid signed build")
    return identifier, build


def extract(archive, destination):
    entries = archive.infolist()
    require(len(entries) <= 100_000 and sum(e.file_size for e in entries) <= 2 * 1024**3, "Archive exceeds staging bounds")
    seen = set()
    for item in entries:
        raw = item.filename
        relative = PurePosixPath(raw)
        mode = item.external_attr >> 16
        kind = stat.S_IFMT(mode)
        require(raw and raw == item.orig_filename and "\\" not in raw and not relative.is_absolute()
                and all(p not in ("", ".", "..") for p in raw.rstrip("/").split("/"))
                and kind in (0, stat.S_IFREG, stat.S_IFDIR), "Unsafe IPA entry")
        key = str(relative).casefold()
        require(key not in seen, "Duplicate IPA entry")
        seen.add(key)
    for item in entries:
        path = destination / item.filename
        if item.is_dir():
            path.mkdir(parents=True, exist_ok=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(item) as source, path.open("xb") as target:
                shutil.copyfileobj(source, target)
            # Match unzip's ordinary file modes. Keep the top-level scratch
            # directory private and do not restore set-id or sticky bits.
            archived_permissions = (item.external_attr >> 16) & 0o777
            path.chmod(archived_permissions or 0o644)
    for item in reversed(entries):
        if item.is_dir() and (permissions := (item.external_attr >> 16) & 0o777):
            (destination / item.filename).chmod(permissions)


def grants(signed, profile):
    if isinstance(signed, str) and isinstance(profile, str):
        return signed == profile or (profile.endswith("*") and "*" not in profile[:-1] and signed.startswith(profile[:-1]))
    if type(signed) is list and type(profile) is list:
        return all(any(grants(value, allowed) for allowed in profile) for value in signed)
    if type(signed) is dict and type(profile) is dict:
        return all(key in profile and grants(value, profile[key]) for key, value in signed.items())
    return type(signed) is type(profile) and signed == profile


def validate_profile(profile, entitlements, signer, team, identifier, udid, now):
    require(profile.get("TeamIdentifier") == [team], "Profile team mismatch")
    require(isinstance(profile.get("ProvisionedDevices"), list) and any(
        isinstance(device, str) and device.casefold() == udid.casefold() for device in profile["ProvisionedDevices"]),
        "Profile does not cover the expected device")
    require(profile.get("ProvisionsAllDevices") is not True, "Enterprise profile refused")
    expires = profile.get("ExpirationDate")
    if isinstance(expires, dt.datetime) and expires.tzinfo is None:
        expires = expires.replace(tzinfo=dt.timezone.utc)
    require(isinstance(expires, dt.datetime) and expires > now, "Expired profile")
    require(signer in profile.get("DeveloperCertificates", []), "Profile does not grant the signing certificate")
    require(entitlements.get("application-identifier") == team + "." + identifier and
            entitlements.get("com.apple.developer.team-identifier") == team and
            entitlements.get("get-task-allow") is True, "Development app entitlements mismatch")
    require(grants(entitlements, profile.get("Entitlements")), "Signed entitlements exceed the profile")
    return expires


def validate(ipa, team, udid, root, probe=False, expected_signer=None, *, imported_destination=None):
    if imported_destination is not None:
        require(not probe and expected_signer is not None and TEAM.fullmatch(team)
                and re.fullmatch(r"app\.zloader\.imported\.[a-f0-9]{32}\." + team, imported_destination),
                "Invalid imported validation scope")
    require(sys.platform == "darwin", "Run full artifact validation on macOS")
    pinned = command("openssl", "x509", "-in", str(root), "-outform", "DER")
    require(hashlib.sha256(pinned).hexdigest() == APPLE_ROOT, "Unexpected profile trust anchor")
    require(ipa.is_file() and not ipa.is_symlink() and 0 < ipa.stat().st_size <= 512 * 1024 * 1024,
            "IPA is outside the private publisher's size policy")
    original_digest = sha(ipa)
    now = dt.datetime.now(dt.timezone.utc)
    with tempfile.TemporaryDirectory(prefix="zag-personal-ota-") as scratch:
        directory = Path(scratch)
        with zipfile.ZipFile(ipa) as archive:
            relative, metadata = main_bundle(archive)
            if imported_destination is None:
                bundle, build = verify_identity(metadata, team, probe)
            else:
                bundle = metadata.get("CFBundleIdentifier")
                build = metadata.get("CFBundleVersion")
                require(bundle == imported_destination and isinstance(build, str)
                        and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build), "Imported signed identity mismatch")
            extract(archive, directory)
        app = directory / relative
        command("codesign", "--verify", "--deep", "--strict", str(app),
                stage="Verify signed bundle and nested code", component=relative)
        for file in sorted(app.rglob("*")):
            if file.is_file() and is_macho(file):
                command("codesign", "--verify", "--strict", str(file),
                        stage="Verify Mach-O executable", component=file.relative_to(directory))
        expiry = []
        components = [app] + sorted(p for p in app.rglob("*") if p.is_dir() and p.suffix in (".appex", ".app"))
        if imported_destination is not None:
            require(len(components) == 1 and not any(app.rglob("*.xpc")), "Unexpected imported nested application")
        if probe:
            require(len(components) == 1 and not any(app.rglob("*.framework")), "Unexpected nested probe code")
        for index, component in enumerate(components):
            info = plistlib.loads((component / "Info.plist").read_bytes())
            identifier = info.get("CFBundleIdentifier")
            require(identifier == bundle or (isinstance(identifier, str) and identifier.startswith(bundle + ".")),
                    "Unexpected signed component identifier")
            component_path = component.relative_to(directory)
            verify_development_certificate(component, component_path)
            prefix = directory / f"certificate-{index}-"
            command("codesign", "--display", "--extract-certificates=" + str(prefix), str(component),
                    stage="Extract signing certificate", component=component_path)
            leaf = Path(str(prefix) + "0")
            require(leaf.is_file(), f"Extract signing certificate [{component_path}]: codesign returned no leaf")
            signer = leaf.read_bytes()
            if index == 0:
                require(expected_signer is None or signer == expected_signer, "Signed IPA does not use the selected certificate")
                primary_signer = signer
            require(signer == primary_signer, "Component signer differs from the main app")
            expiry_line = command("openssl", "x509", "-inform", "DER", "-in", str(prefix) + "0", "-noout", "-enddate")
            certificate_expiry = dt.datetime.strptime(expiry_line.decode().strip().split("=", 1)[1],
                                                      "%b %d %H:%M:%S %Y GMT").replace(tzinfo=dt.timezone.utc)
            require(certificate_expiry > now, "Expired signing certificate")
            profile = plistlib.loads(command("openssl", "smime", "-verify", "-inform", "DER", "-purpose", "any",
                                              "-CAfile", str(root), "-no-CApath",
                                              "-in", str(component / "embedded.mobileprovision")))
            entitlements = read_signed_entitlements(component, component_path)
            expiry.append(min(certificate_expiry, validate_profile(profile, entitlements, signer, team, identifier, udid, now)))
        require(sha(ipa) == original_digest, "IPA changed during verification")
    return {"sha256": original_digest, "bundle_identifier": bundle, "build": build,
            "effective_expiration": min(expiry).isoformat(), "components": len(components)}


def check_manifest(data, job, bundle, build):
    manifest = plistlib.loads(data)
    item, = manifest["items"]
    asset, = item["assets"]
    metadata = item["metadata"]
    url = urlsplit(asset["url"])
    require(asset["kind"] == "software-package" and metadata["bundle-identifier"] == bundle
            and metadata["bundle-version"] == build and metadata["kind"] == "software" and url.scheme == "https" and url.netloc == PREVIEW
            and url.path == f"/wp-json/zag-byoc/v1/ota/{job}/ipa" and url.query.startswith("token="),
            "Existing publisher emitted an unexpected OTA manifest")


def publish(args):
    require(os.geteuid() == 0 and SHA.fullmatch(args.sha256), "Root and a verified SHA-256 are required")
    require(args.ipa.is_file() and not args.ipa.is_symlink(), "Expected a regular signed IPA")
    expiry = dt.datetime.fromisoformat(args.effective_expiration)
    require(expiry.tzinfo is not None and expiry > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=10),
            "The verified artifact expires before the preview link would")
    require(args.secret_file.resolve() == SECRET and not args.secret_file.is_symlink(),
            "Unexpected private preview secret path")
    require(not args.delivery.is_symlink() and args.delivery.resolve() == DELIVERY and args.delivery.is_dir(),
            "Unexpected private preview delivery directory")
    require(args.services.resolve() == SERVICES, "Unexpected services directory")
    sys.path.insert(0, str(args.services))
    from byoc_private_byoc_delivery import HOST, publish as existing_publish, delivery_lock
    require(HOST == PREVIEW, "Existing publisher does not target preview")
    job = os.urandom(16).hex()
    with tempfile.TemporaryDirectory(prefix="zag-personal-quarantine-") as quarantine:
        source = Path(quarantine) / (job + ".signed.ipa")
        shutil.copyfile(args.ipa, source)
        require(sha(source) == args.sha256, "Upload digest differs from the verified IPA")
        with zipfile.ZipFile(source) as archive:
            _, metadata = main_bundle(archive)
            bundle, build = verify_identity(metadata, args.team, getattr(args, "probe", False))
        result = existing_publish(job_id=job, quarantine_dir=quarantine, delivery_dir=args.delivery,
                                  secret_file=args.secret_file, uid=args.uid, gid=args.gid, ttl=600)
        try:
            require(result["sha256"] == args.sha256, "Published IPA digest mismatch")
            check_manifest((args.delivery / (job + ".plist")).read_bytes(), job, bundle, build)
            manifest_url, = parse_qs(urlsplit(result["install_url"]).query)["url"]
            manifest = urlsplit(manifest_url)
            token, = parse_qs(manifest.query)["token"]
            require(manifest.scheme == "https" and manifest.netloc == PREVIEW and
                    manifest.path == f"/wp-json/zag-byoc/v1/ota/{job}/manifest", "Invalid install link")
            result["safari_url"] = f"https://{PREVIEW}/wp-json/zag-byoc/v1/ota/{job}/install?" + urlencode({"token": token})
        except BaseException:
            with delivery_lock(args.delivery):
                for suffix in (".json", ".plist", ".signed.ipa"):
                    (args.delivery / (job + suffix)).unlink(missing_ok=True)
            raise
    return result


def expired_jobs(expected_sha, team, start, end):
    expected_bundle = mapped_bundle(team)
    require(SHA.fullmatch(expected_sha) and start.tzinfo and end.tzinfo
            and dt.timedelta() < end - start <= dt.timedelta(days=1),
            "Provide an exact digest and a publication window of at most one day")
    require(DELIVERY.is_dir() and not DELIVERY.is_symlink(), "Invalid preview delivery directory")
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    matches = []
    for path in DELIVERY.glob("*.json"):
        if not JOB.fullmatch(path.stem) or not path.is_file() or path.is_symlink():
            continue
        try:
            record = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(record, dict):
            continue
        expires = record.get("expires_at")
        if (record.get("job_id") == path.stem and record.get("sha256") == expected_sha
                and record.get("bundle_id") == expected_bundle and type(expires) is int
                and start.timestamp() <= expires - 600 <= end.timestamp() and expires <= now):
            matches.append({"job": path.stem, "expires_at": dt.datetime.fromtimestamp(
                expires, dt.timezone.utc).isoformat()})
    return sorted(matches, key=lambda match: (match["expires_at"], match["job"]))


def cleanup(job, expected_sha, team, probe=False):
    expected_bundle = mapped_bundle(team, probe)
    require(os.geteuid() == 0 and JOB.fullmatch(job) and SHA.fullmatch(expected_sha), "Invalid cleanup request")
    require(DELIVERY.is_dir() and not DELIVERY.is_symlink(), "Invalid preview delivery directory")
    sys.path.insert(0, str(SERVICES))
    from byoc_private_byoc_delivery import delivery_lock
    with delivery_lock(DELIVERY):
        record_path = DELIVERY / (job + ".json")
        require(record_path.is_file() and not record_path.is_symlink(), "Delivery record unavailable")
        record = json.loads(record_path.read_text())
        require(record["job_id"] == job and record["sha256"] == expected_sha
                and record["bundle_id"] == expected_bundle,
                "Delivery record does not match the experiment")
        for suffix in (".json", ".plist", ".signed.ipa"):
            (DELIVERY / (job + suffix)).unlink(missing_ok=True)
    return {"removed": job}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    modes = cli.add_subparsers(dest="mode", required=True)
    for mode in ("validate", "publish"):
        parser = modes.add_parser(mode)
        parser.add_argument("--ipa", type=Path, required=True)
        parser.add_argument("--team", required=True)
        parser.add_argument("--probe", action="store_true", help="Use the isolated minimal probe identifier")
        if mode == "validate":
            parser.add_argument("--udid", required=True)
            parser.add_argument("--apple-root", type=Path, required=True)
        else:
            parser.add_argument("--sha256", required=True)
            parser.add_argument("--effective-expiration", required=True)
            parser.add_argument("--services", type=Path, required=True)
            parser.add_argument("--delivery", type=Path, required=True)
            parser.add_argument("--secret-file", type=Path, required=True)
            parser.add_argument("--uid", type=int, required=True)
            parser.add_argument("--gid", type=int, required=True)
    clean = modes.add_parser("cleanup")
    clean.add_argument("--job", required=True)
    clean.add_argument("--sha256", required=True)
    clean.add_argument("--team", required=True)
    clean.add_argument("--probe", action="store_true")
    listing = modes.add_parser("expired-jobs", help="List matching expired Zag Store experiment records without tokens")
    listing.add_argument("--sha256", required=True)
    listing.add_argument("--team", required=True)
    listing.add_argument("--start", type=dt.datetime.fromisoformat, required=True)
    listing.add_argument("--end", type=dt.datetime.fromisoformat, required=True)
    args = cli.parse_args()
    try:
        if args.mode == "validate":
            result = validate(args.ipa, args.team, args.udid, args.apple_root, args.probe)
        elif args.mode == "publish":
            result = publish(args)
        elif args.mode == "expired-jobs":
            result = expired_jobs(args.sha256, args.team, args.start, args.end)
        else:
            result = cleanup(args.job, args.sha256, args.team, args.probe)
        print(json.dumps(result))
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"OTA preflight stopped: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
