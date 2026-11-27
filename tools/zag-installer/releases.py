"""Download artifacts authorized by the app's production v2 verifier."""

import datetime as dt
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit
import zipfile

from desktop import require

MAX_IPA = 512 * 1024**2
RELEASE_PATH = r"/(?:zagorskey|zagstore)/zag-store-releases/releases/download/([A-Za-z0-9._-]+)/[A-Za-z0-9._-]+\.ipa"


def release_tag(value):
    url = urlsplit(value)
    require(url.scheme == "https" and url.netloc == "github.com" and not url.query and not url.fragment,
            "Unexpected official release URL")
    match = re.fullmatch(RELEASE_PATH, url.path)
    require(match, "Unexpected official release path")
    return match[1]


def check_fresh(release):
    expires = dt.datetime.fromisoformat(release["expires"].replace("Z", "+00:00"))
    require(dt.datetime.now(dt.timezone.utc) < expires, "Published update information has expired")


def run_helper(args, timeout, stage):
    try:
        result = subprocess.run(args, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ValueError(f"{stage} timed out. Check your connection and retry.") from error
    if result.returncode:
        message = None
        if result.returncode == 1 and len(result.stderr) <= 1024:
            try:
                message = json.loads(result.stderr).get("message")
            except (ValueError, AttributeError):
                pass
        raise ValueError(message if isinstance(message, str) else f"{stage} failed")
    return result.stdout


def discover(repo, cache, expected_tag=None):
    sources = [Path(__file__).with_name(name) for name in ("DesktopRelease.swift", "DesktopNetwork.swift")]
    sources += [repo / "Feather/Utilities" / f"ZagUpdate{name}.swift"
                for name in ("MetadataV2", "TrustStore", "RollbackStore", "VerifiedPipeline", "V2Discovery")]
    helper = cache.build_swift("release", sources)
    release = json.loads(run_helper([helper], 40, "Signed release discovery"))
    tag = release_tag(release["url"])
    require(expected_tag is None or tag == expected_tag, f"Signed channel authorizes {tag}, expected {expected_tag}")
    check_fresh(release)
    return release, helper


def acquire(artifact, release, helper, path):
    check_fresh(release)
    release_tag(release["url"])
    with path.open("xb"):
        pass
    run_helper([helper, "asset", release["url"], path], 615, "Official IPA download")
    require(0 < path.stat().st_size <= MAX_IPA and artifact.sha(path) == release["sha256"],
            "Official IPA digest differs from the signed manifest")
    with zipfile.ZipFile(path) as archive:
        relative, info = artifact.main_bundle(archive)
        require(info.get("CFBundleIdentifier") == artifact.ORIGINAL
                and info.get("CFBundleShortVersionString") == release["version"]
                and info.get("CFBundleVersion") == release["build"]
                and info.get("MinimumOSVersion") == release["minimum_os"]
                and str(relative / "embedded.mobileprovision") not in archive.namelist(),
                "Official IPA identity does not match the signed manifest")
    return release
