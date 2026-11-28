"""Read-only, post-validation binding between the macOS signer and native USB.

This JSON is NOT an authorization token. Rust independently checks its
checksum and connected device; Apple's signing/profile and signed-channel
authorization remain checked only by the existing macOS validator.
"""
import os
from pathlib import Path
import re
import stat
import zipfile

def create(signed, release, team, udid, certificate, root, artifact,
           check_authorization, previous=None, *, imported_bundle=None):
    signed = Path(signed)
    if signed.is_symlink():
        raise ValueError("Signed IPA symlink is prohibited")
    info = signed.stat()
    if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 512 * 1024 * 1024:
        raise ValueError("Invalid signed IPA file")
    if not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{8}-[0-9a-fA-F]{16})", udid):
        raise ValueError("Unexpected trusted iPhone identifier")
    options = {}
    if imported_bundle is not None:
        from ipa_preview import mapped_import_bundle
        if previous is not None:
            raise ValueError("Imported upgrades are not supported")
        bundle = mapped_import_bundle(imported_bundle, team)
        options["imported_destination"] = bundle
    else:
        bundle = artifact.mapped_bundle(team)
    # The complete independent profile, certificate and Mach-O validation
    # is mandatory before any preflight plan can be constructed.
    verified = artifact.validate(signed, team, udid, root, expected_signer=certificate, **options)
    if verified.get("bundle_identifier") != bundle or verified.get("build") != release["build"]:
        raise ValueError("Signed IPA identity does not match the release")
    with zipfile.ZipFile(signed) as archive:
        _, payload = artifact.main_bundle(archive)
    if (payload.get("CFBundleIdentifier") != bundle or
        payload.get("CFBundleShortVersionString") != release["version"] or
        payload.get("CFBundleVersion") != release["build"] or
        payload.get("MinimumOSVersion") != release["minimum_os"]):
        raise ValueError("Signed IPA metadata differs from release authorization")
    if previous is not None:
        if (not isinstance(previous, dict) or
            set(previous) != {"version", "build"} or
            not all(isinstance(x, str) for x in previous.values())):
            raise ValueError("Invalid previous destination identity")
    check_authorization(release)
    digest = artifact.sha(signed)
    if imported_bundle is not None and digest != verified.get("sha256"):
        raise ValueError("Signed imported IPA changed after validation")
    if not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise ValueError("Malformed validated IPA checksum")
    return {
        "schema":2 if imported_bundle is not None else 1,
        "ipa_path":str(signed.resolve(strict=True)),
        "ipa_sha256":digest,
        "ipa_bytes":info.st_size,
        "bundle_identifier":bundle,
        "version":release["version"],
        "build":release["build"],
        "minimum_os":release["minimum_os"],
        "device_udid":udid,
        "previous":previous,
    }


def write_private(plan, scratch):
    import json
    path = Path(scratch) / "native-ipa-preflight.json"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(plan, handle, sort_keys=True, separators=(",", ":"))
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return path
