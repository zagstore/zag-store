"""Download artifacts authorized by the app's production v2 verifier."""

import datetime as dt
import json
from pathlib import Path
import re
import subprocess
import time
import urllib.request
from urllib.parse import urlsplit
import zipfile

from desktop import require

MAX_IPA = 512 * 1024**2
RELEASE_PATH = r"/(?:zagorskey|zagstore)/zag-store-releases/releases/download/([A-Za-z0-9._-]+)/[A-Za-z0-9._-]+\.ipa"
ASSET_HOSTS = {"objects.githubusercontent.com", "release-assets.githubusercontent.com"}


def release_tag(value):
    url = urlsplit(value)
    require(url.scheme == "https" and url.netloc == "github.com" and not url.query and not url.fragment,
            "Unexpected official release URL")
    match = re.fullmatch(RELEASE_PATH, url.path)
    require(match, "Unexpected official release path")
    return match[1]


class ReleaseRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        url = urlsplit(newurl)
        require(url.scheme == "https" and url.netloc in ASSET_HOSTS | {"github.com"} and not url.fragment,
                "Unexpected official release redirect")
        if url.netloc == "github.com":
            origin = urlsplit(req.full_url)
            require(origin.netloc == "github.com" and release_tag(newurl) == release_tag(req.full_url)
                    and url.path.split("/releases/download/", 1)[1] == origin.path.split("/releases/download/", 1)[1],
                    "Release redirect changed the selected artifact")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_fresh(release):
    expires = dt.datetime.fromisoformat(release["expires"].replace("Z", "+00:00"))
    require(dt.datetime.now(dt.timezone.utc) < expires, "Published update information has expired")


def discover(repo, cache, expected_tag=None):
    sources = [Path(__file__).with_name("DesktopRelease.swift")]
    sources += [repo / "Feather/Utilities" / f"ZagUpdate{name}.swift"
                for name in ("MetadataV2", "TrustStore", "RollbackStore", "VerifiedPipeline", "V2Discovery")]
    helper = cache.build_swift("release", sources)
    result = subprocess.run([helper], capture_output=True, timeout=40)
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", "replace").strip() or "Signed release discovery failed")
    release = json.loads(result.stdout)
    tag = release_tag(release["url"])
    require(expected_tag is None or tag == expected_tag, f"Signed channel authorizes {tag}, expected {expected_tag}")
    check_fresh(release)
    return release


def acquire(artifact, release, path):
    check_fresh(release)
    release_tag(release["url"])
    opener = urllib.request.build_opener(ReleaseRedirect())
    deadline = time.monotonic() + 600
    with opener.open(release["url"], timeout=30) as response, path.open("xb") as output:
        size = 0
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            size += len(chunk)
            require(time.monotonic() < deadline, "Official asset download timed out")
            require(size <= MAX_IPA, "Official asset exceeded the download bounds")
            output.write(chunk)
    require(size > 0 and artifact.sha(path) == release["sha256"], "Official IPA digest differs from the signed manifest")
    with zipfile.ZipFile(path) as archive:
        relative, info = artifact.main_bundle(archive)
        require(info.get("CFBundleIdentifier") == artifact.ORIGINAL
                and info.get("CFBundleShortVersionString") == release["version"]
                and info.get("CFBundleVersion") == release["build"]
                and info.get("MinimumOSVersion") == release["minimum_os"]
                and str(relative / "embedded.mobileprovision") not in archive.namelist(),
                "Official IPA identity does not match the signed manifest")
    return release
