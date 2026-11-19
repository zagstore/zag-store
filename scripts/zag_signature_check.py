"""Independent check of an iOS app signature, for
scripts/test-zag-zsign-real-certificate.sh.

For the app's executable and each framework binary: every code page hash in
every CodeDirectory, the special slots (Info.plist, sealed resources,
requirements, entitlements), the identifier and team, and the CMS signed
attributes that bind the CodeDirectories (CDHashes). Then each sealed
resource in _CodeSignature/CodeResources against the file on disk. The CMS
signature itself is checked with OpenSSL by the caller, from the files this
writes (<out>/<n>.cms, <out>/<n>.cd0).

Usage: zag_signature_check.py <app> <team> <out-dir>
Prints PASS/FAIL lines; exits 1 on any failure.
"""
import base64
import hashlib
import os
import plistlib
import struct
import sys

app, team, out = sys.argv[1], sys.argv[2], sys.argv[3]
failures = []


def fail(message):
    failures.append(message)
    print("FAIL:", message)


def code_signature(binary):
    data = open(binary, "rb").read()
    if struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        raise ValueError("not a thin 64-bit Mach-O")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == 0x1D:
            start, length = struct.unpack_from("<II", data, offset + 8)
            return data, data[start:start + length]
        offset += size
    raise ValueError("no LC_CODE_SIGNATURE")


def der_items(data, offset, end):
    """Yields (tag, content_start, content_end) for DER items in data[offset:end]."""
    while offset < end:
        tag = data[offset]
        length = data[offset + 1]
        offset += 2
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(data[offset:offset + count], "big")
            offset += count
        yield tag, offset, offset + length
        offset += length


def signed_attribute(cms, oid_der):
    """Every value of a signed attribute, located by its encoded OID, as
    (tag, content) pairs."""
    at = cms.find(oid_der)
    if at < 0:
        return None
    after = at + len(oid_der)
    for tag, start, end in der_items(cms, after, len(cms)):
        if tag == 0x31:
            return [(inner_tag, cms[inner_start:inner_end]) for inner_tag, inner_start, inner_end in der_items(cms, start, end)]
        break
    return None


DIGEST_OIDS = {bytes.fromhex("2b0e03021a"): 1, bytes.fromhex("608648016503040201"): 2}


CDHASHES_OID = bytes.fromhex("06092a864886f763640901")   # 1.2.840.113635.100.9.1
CDHASHES2_OID = bytes.fromhex("06092a864886f763640902")  # 1.2.840.113635.100.9.2


def check_binary(name, binary, bundle, index):
    try:
        data, blob = code_signature(binary)
    except ValueError as error:
        fail(f"{name}: {error}")
        return
    count = struct.unpack_from(">I", blob, 8)[0]
    blobs = {}
    for i in range(count):
        kind, offset = struct.unpack_from(">II", blob, 12 + 8 * i)
        length = struct.unpack_from(">I", blob, offset + 4)[0]
        blobs[kind] = blob[offset:offset + length]
    directories = [blobs[k] for k in (0, 0x1000, 0x1001, 0x1002) if k in blobs]
    if not directories or 0x10000 not in blobs:
        fail(f"{name}: no CodeDirectory or no CMS signature")
        return
    info = open(os.path.join(bundle, "Info.plist"), "rb").read()
    resources_path = os.path.join(bundle, "_CodeSignature", "CodeResources")
    resources = open(resources_path, "rb").read() if os.path.exists(resources_path) else None
    sources = {1: info, 2: blobs.get(2), 3: resources, 5: blobs.get(5), 7: blobs.get(7)}
    cdhashes = []
    for directory in directories:
        (_, _, version, _, hash_offset, ident_offset, n_special, n_code, code_limit,
         hash_size, hash_type, _, page_shift) = struct.unpack_from(">IIIIIIIIIBBBB", directory, 0)
        algorithm = {1: hashlib.sha1, 2: hashlib.sha256}.get(hash_type)
        if algorithm is None:
            fail(f"{name}: unsupported hash type {hash_type}")
            return
        identifier = directory[ident_offset:directory.index(b"\0", ident_offset)].decode()
        team_offset = struct.unpack_from(">I", directory, 0x30)[0] if version >= 0x20200 else 0
        cd_team = directory[team_offset:directory.index(b"\0", team_offset)].decode() if team_offset else None
        if cd_team != team:
            fail(f"{name}: CodeDirectory team {cd_team}, expected the profile's")
        page = 1 << page_shift
        bad_pages = [p for p in range(n_code)
                     if algorithm(data[p * page:min((p + 1) * page, code_limit)]).digest()[:hash_size]
                     != directory[hash_offset + p * hash_size:hash_offset + (p + 1) * hash_size]]
        if bad_pages:
            fail(f"{name}: {len(bad_pages)} code pages do not match their hashes")
        for slot in range(1, n_special + 1):
            stored = directory[hash_offset - slot * hash_size:hash_offset - (slot - 1) * hash_size]
            if not any(stored):
                continue
            source = sources.get(slot)
            if source is None or algorithm(source).digest()[:hash_size] != stored:
                fail(f"{name}: special slot -{slot} does not match")
        cdhashes.append((hash_type, algorithm(directory).digest()))
        if index == 0 and directory is directories[0]:
            print(f"INFO: {name}: identifier {identifier}")
    cms = blobs[0x10000][8:]
    v1 = signed_attribute(cms, CDHASHES_OID)
    if v1 is None:
        fail(f"{name}: CMS has no CDHashes attribute")
    else:
        listed = [bytes(h) for h in plistlib.loads(v1[0][1])["cdhashes"]]
        expected = [digest[:20] for _, digest in cdhashes]
        if listed != expected:
            fail(f"{name}: CMS CDHashes do not match the CodeDirectories")
    v2 = signed_attribute(cms, CDHASHES2_OID)
    if v2 is None:
        fail(f"{name}: CMS has no CDHashes2 attribute")
    else:
        # One (digest, full hash) per CodeDirectory, as codesign writes them.
        entries = set()
        for _, content in v2:
            parts = list(der_items(content, 0, len(content)))
            if len(parts) == 2 and parts[0][0] == 0x06 and parts[1][0] == 0x04:
                entries.add((DIGEST_OIDS.get(content[parts[0][1]:parts[0][2]]), content[parts[1][1]:parts[1][2]]))
        if entries != set(cdhashes):
            fail(f"{name}: CMS CDHashes2 does not list exactly this binary's CodeDirectories")
    if 5 in blobs:
        open(os.path.join(out, f"{index}.entitlements"), "wb").write(blobs[5][8:])
    open(os.path.join(out, f"{index}.cms"), "wb").write(cms)
    open(os.path.join(out, f"{index}.cd0"), "wb").write(directories[0])
    open(os.path.join(out, f"{index}.name"), "w").write(name)


def check_seal(name, bundle):
    path = os.path.join(bundle, "_CodeSignature", "CodeResources")
    if not os.path.exists(path):
        fail(f"{name}: no sealed resources")
        return
    files = plistlib.load(open(path, "rb")).get("files2", {})
    sealed = 0
    for relative, entry in files.items():
        if not isinstance(entry, dict):
            continue
        target = os.path.join(bundle, relative)
        if "symlink" in entry:
            continue
        expected = entry.get("hash2")
        if expected is None:
            continue
        if not os.path.isfile(target):
            fail(f"{name}: sealed file missing: {relative}")
            continue
        if hashlib.sha256(open(target, "rb").read()).digest() != bytes(expected):
            fail(f"{name}: sealed file changed: {relative}")
        sealed += 1
    print(f"INFO: {name}: {sealed} sealed files match")


os.makedirs(out, exist_ok=True)
info = plistlib.load(open(os.path.join(app, "Info.plist"), "rb"))
targets = [("app", os.path.join(app, info["CFBundleExecutable"]), app)]
frameworks = os.path.join(app, "Frameworks")
if os.path.isdir(frameworks):
    for entry in sorted(os.listdir(frameworks)):
        path = os.path.join(frameworks, entry)
        if entry.endswith(".framework"):
            framework_info = plistlib.load(open(os.path.join(path, "Info.plist"), "rb"))
            targets.append((entry, os.path.join(path, framework_info["CFBundleExecutable"]), path))
        elif entry.endswith(".dylib"):
            fail(f"{entry}: loose libraries are not covered by this check")
for index, (name, binary, bundle) in enumerate(targets):
    check_binary(name, binary, bundle, index)
    check_seal(name, bundle)
if failures:
    sys.exit(1)
print(f"PASS: page hashes, special slots, CDHashes and sealed resources for {len(targets)} signed binaries")
