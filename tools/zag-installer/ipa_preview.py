"""Read-only IPA preview; never extract or execute archive members."""
import base64
import json
import plistlib
import re
import stat
import struct
import sys
import unicodedata
import zipfile
from pathlib import Path

MAX_IPA = 512 * 1024 * 1024
MAX_PLIST = 1024 * 1024
MAX_ICON = 256 * 1024

def clean(value, limit=120):
    if not isinstance(value, str):
        return ""
    return "".join(c for c in value if not unicodedata.category(c).startswith("C")).strip()[:limit]

def bounded_read(archive, info, limit):
    if not 0 < info.file_size <= limit or info.flag_bits & 1:
        raise ValueError("Unsupported archive member")
    with archive.open(info) as stream:
        data = stream.read(limit + 1)
    if len(data) != info.file_size or len(data) > limit:
        raise ValueError("Invalid archive member length")
    return data

def inspect(path):
    path = Path(path)
    meta = path.stat()
    if path.suffix.lower() != ".ipa" or not stat.S_ISREG(meta.st_mode) or not 0 < meta.st_size <= MAX_IPA:
        raise ValueError("Invalid IPA")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 100000:
            raise ValueError("Too many archive members")
        plists = [item for item in entries if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", item.filename)]
        if len(plists) != 1:
            raise ValueError("Expected exactly one main application")
        info = plistlib.loads(bounded_read(archive, plists[0], MAX_PLIST))
        if not isinstance(info, dict):
            raise ValueError("Invalid metadata")
        bundle = info.get("CFBundleIdentifier")
        if not isinstance(bundle, str) or len(bundle) > 255 or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle):
            raise ValueError("Invalid bundle identifier")
        name = clean(info.get("CFBundleDisplayName")) or clean(info.get("CFBundleName")) or bundle
        result = {"name": name, "bundle": bundle, "version": clean(info.get("CFBundleShortVersionString"), 64),
                  "build": clean(info.get("CFBundleVersion"), 64)}
        icons = info.get("CFBundleIcons")
        primary = icons.get("CFBundlePrimaryIcon") if isinstance(icons, dict) else None
        names = primary.get("CFBundleIconFiles") if isinstance(primary, dict) else None
        if not isinstance(names, list):
            names = info.get("CFBundleIconFiles", [])
        if not isinstance(names, list):
            names = []
        prefix = plists[0].filename.rsplit("/", 1)[0] + "/"
        candidates = set()
        for item in names[:32]:
            if isinstance(item, str) and re.fullmatch(r"[A-Za-z0-9_.@~-]{1,128}", item):
                stem = item[:-4] if item.endswith(".png") else item
                candidates.update(prefix + stem + suffix for suffix in (".png", "@2x.png", "@3x.png"))
        matches = [item for item in entries if item.filename in candidates and item.file_size <= MAX_ICON]
        for member in sorted(matches, key=lambda item: item.file_size, reverse=True)[:8]:
            if sum(item.filename == member.filename for item in matches) != 1:
                continue
            try:
                data = bounded_read(archive, member, MAX_ICON)
                if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
                    continue
                width, height = struct.unpack(">II", data[16:24])
                if 0 < width <= 512 and 0 < height <= 512:
                    result["icon"] = base64.b64encode(data).decode("ascii")
                    break
            except (ValueError, OSError, RuntimeError, struct.error, zipfile.BadZipFile):
                continue
        return result


def stage_for_signing(source, destination, artifact):
    """Snapshot an explicitly selected IPA; reject protected identities and unsupported layouts.
    No portal requests, signing or device writes occur here.
    """
    import os
    import hashlib
    source, destination = Path(source), Path(destination)
    digest = hashlib.sha256()
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        meta = os.fstat(stream.fileno())
        if not stat.S_ISREG(meta.st_mode) or not 0 < meta.st_size <= MAX_IPA:
            raise ValueError("Invalid IPA source")
        size = 0
        with destination.open("xb") as output:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                size += len(chunk)
                if size > MAX_IPA:
                    raise ValueError("IPA exceeds staging limit")
                digest.update(chunk)
                output.write(chunk)
    destination.chmod(0o600)
    preview = inspect(destination)
    original = preview["bundle"]
    protected = ("app.zagstore.ios", "com.cwd43.gu29")
    if any(original.casefold() == value or original.casefold().startswith(value + ".") for value in protected):
        raise ValueError("Protected Zag Store identity")
    with zipfile.ZipFile(destination) as archive:
        entries = archive.infolist()
        if len(entries) > 100000 or sum(e.file_size for e in entries) > 2 * 1024**3:
            raise ValueError("Archive exceeds staging bounds")
        relative, info = artifact.main_bundle(archive)
        if info.get("CFBundleIdentifier") != original:
            raise ValueError("Application identity changed")
        for item in entries:
            if item.flag_bits & 1:
                raise ValueError("Encrypted ZIP member")
        # First installation scope: one main application, no extensions or nested apps.
        # Reject instead of silently removing capabilities.
        prefix = str(relative) + "/"
        for item in entries:
            if item.filename.startswith(prefix):
                parts = item.filename[len(prefix):].split("/")
                if any(part.endswith((".appex", ".app", ".xpc")) for part in parts):
                    raise ValueError("Nested applications and extensions are not supported yet")
        folder = destination.parent / "imported-unsigned"
        folder.mkdir(mode=0o700)
        artifact.extract(archive, folder)
    return {"metadata": preview, "sha256": digest.hexdigest(), "app": folder / relative,
            "relative": relative, "info": info}

def mapped_import_bundle(original, team):
    """Separate namespace from official Zag Store; deterministic per app and team."""
    import hashlib
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Invalid Personal Team")
    if not isinstance(original, str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", original):
        raise ValueError("Invalid bundle identifier")
    if any(original.casefold() == value or original.casefold().startswith(value + ".")
           for value in ("app.zagstore.ios", "com.cwd43.gu29")):
        raise ValueError("Protected Zag Store identity")
    return "app.zloader.imported." + hashlib.sha256(original.casefold().encode("ascii")).hexdigest()[:32] + "." + team


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Expected IPA path")
        print(json.dumps(inspect(sys.argv[1]), ensure_ascii=True))
    except Exception:
        sys.exit(1)
