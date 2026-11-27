import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone

P = pathlib.Path
S = P("/opt/zagstore/signing-engine")
D = P("/root/zag-deploy/zagstore-deploy-b045845921f6/ops/first-launch-analytics/deploy")

def run(*args):
    subprocess.run(args, check=True)

def digest(path):
    with open(path, "rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError("Unexpected source structure: " + old[:80])
    return text.replace(old, new, 1)

def atomic_write(path, content):
    fd, name = tempfile.mkstemp(dir=path.parent)
    os.close(fd)
    try:
        run("cp", "--preserve=all", str(path), name)
        P(name).write_text(content)
        os.replace(name, path)
    finally:
        P(name).unlink(missing_ok=True)

import argparse
parser = argparse.ArgumentParser()
parser.add_argument("--sha256", required=True)
parser.add_argument("--released", required=True)
args = parser.parse_args()

sha = args.sha256
assert os.geteuid() == 0
assert re.fullmatch(r"[a-f0-9]{64}", sha)
datetime.strptime(args.released, "%Y-%m-%dT%H:%M:%SZ")

ipa = S / "releases" / f"zagstore-{sha}.ipa"
assert digest(ipa) == sha

with zipfile.ZipFile(ipa) as z:
    info = plistlib.loads(
        z.read("Payload/Feather.app/Info.plist")
    )
    assert info["CFBundleIdentifier"] == "app.zagstore.ios"
    version = info["CFBundleShortVersionString"]
    build = int(info["CFBundleVersion"])
    assert build > 0

current = S / "releases/current.json"
record = json.loads(current.read_text())
old_sha = record["sha256"]

def release_order(v, b):
    if not re.fullmatch(r"[0-9]+\\.[0-9]+\\.[0-9]+", v):
        raise RuntimeError("Unsupported release version")
    return tuple(map(int, v.split("."))), int(b)

candidate = release_order(version, build)
installed = release_order(record["version"], record["build"])

if candidate <= installed:
    raise RuntimeError("Release is not newer than installed release")

job = S / "services/byoc_signing_job.py"
main = S / "services/byoc_signing_worker_main.py"

changes = {}

for path in (job, main):
    text = path.read_text()
    changes[path] = replace_once(text, old_sha, sha)

record.update(
    version=version,
    build=str(build),
    sha256=sha,
    filename=ipa.name,
)
changes[current] = json.dumps(record) + "\n"

for site in ("zagstore-preview", "zagstore.app"):
    root = P("/var/www") / site
    staged = root / "zag-approved-ipas" / ipa.name
    assert digest(staged) == sha

    approved = root / "zag-approved-releases.json"
    data = json.loads(approved.read_text())
    data["channels"]["beta"].update(
        version=version,
        build=build,
        sha256=sha,
        ipa_path=str(staged),
        released=args.released,
    )

    plugin = root / (
        "public/wp-content/plugins/"
        "zagstore-byoc-installer/"
        "zagstore-byoc-installer.php"
    )
    text = plugin.read_text()

    if "const ZAG_BYOC_RELEASE_DATES" in text:
        text = replace_once(
            text,
            "$approved[$channel] = ['version' => $version, 'build' => $build];",
            "$approved[$channel] = ['version' => $version, "
            "'build' => $build, 'released' => $entry['released'] ?? null];"
        )

        text, count = re.subn(
            r"const ZAG_BYOC_RELEASE_DATES = \[.*?\n\];",
            "",
            text,
            count=1,
            flags=re.S,
        )
        assert count == 1

        text = replace_once(
            text,
            "function zag_byoc_release_dates(string $version, int $build): string {",
            "function zag_byoc_release_dates(array $release): string {"
        )

        text = replace_once(
            text,
            "$value = ZAG_BYOC_RELEASE_DATES[$version . '+' . $build]['released'] ?? null;",
            "$value = $release['released'] ?? null;"
        )

        text = replace_once(
            text,
            "zag_byoc_release_dates((string) $release['version'], $build)",
            "zag_byoc_release_dates($release)"
        )

        text = replace_once(
            text,
            ". ' Beta 4</strong><small>Build '",
            ". (isset($channels['beta']) ? ' Beta ' . $build : '')"
            " . '</strong><small>Build '"
        )

    changes[plugin] = text
    changes[approved] = json.dumps(data, indent=2) + "\n"

print(f"Prepared {version} Beta {build}")
print(f"Publication date: {args.released}")

for path, content in changes.items():
    if path.suffix == ".py":
        compile(content, str(path), "exec")
    elif path.suffix == ".php":
        with tempfile.NamedTemporaryFile(suffix=".php") as f:
            f.write(content.encode())
            f.flush()
            run("php", "-l", f.name)

def idle():
    run("bash", "-c",
        'source "$1/lib.sh"; signing_idle',
        "bash", str(D))

idle()

backup = P("/root/zag-release-backups") / datetime.now(
    timezone.utc
).strftime("%Y%m%dT%H%M%S%fZ")

backup.mkdir(parents=True, mode=0o700)

for path in changes:
    target = backup / str(path).lstrip("/")
    target.parent.mkdir(parents=True, exist_ok=True)
    run("cp", "--preserve=all", str(path), str(target))

print("Backup:", backup, flush=True)

modified = []
worker_changed = False

try:
    idle()

    for path in (job, main, current):
        modified.append(path)
        atomic_write(path, changes[path])

    worker_changed = True
    run("systemctl", "restart", "zag-byoc-signing.service")
    run("systemctl", "is-active", "zag-byoc-signing.service")

    import time

    for site, host in (
        ("zagstore-preview", "preview.zagstore.app"),
        ("zagstore.app", "zagstore.app"),
    ):
        root = P("/var/www") / site
        for path in changes:
            if path.is_relative_to(root):
                modified.append(path)
                atomic_write(path, changes[path])

        time.sleep(4)

        html = subprocess.check_output([
            "curl", "--fail", "--silent", "--show-error",
            "--max-time", "30",
            f"https://{host}/install/?release-check={sha[:12]}"
        ]).decode()

        expected = f"Zag Store {version} Beta {build}"
        date = datetime.strptime(
            args.released, "%Y-%m-%dT%H:%M:%SZ"
        ).strftime("%Y-%m-%d")

        assert expected in html, f"{host}: version missing"
        assert f'datetime="{date}"' in html, f"{host}: date missing"
        print(f"PASS: {host} version and date")

except BaseException:
    print("Activation failed; restoring backups.", flush=True)
    for path in reversed(modified):
        run("cp", "--preserve=all",
            str(backup / str(path).lstrip("/")), str(path))
    if worker_changed:
        run("systemctl", "restart", "zag-byoc-signing.service")
    raise

print("SUCCESS: Both environments activated.")
