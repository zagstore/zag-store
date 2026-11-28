import contextlib
import hashlib
import io
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

P = pathlib.Path
SOURCE = P(__file__).with_name(
    "zag-activate-release.py"
).read_text()

class ActivationTests(unittest.TestCase):

    def exercise(self, failure=None, version="1.0.0", build=6):
        with tempfile.TemporaryDirectory() as directory:
            root = P(directory)
            engine = root / "engine"
            releases = engine / "releases"
            services = engine / "services"
            releases.mkdir(parents=True)
            services.mkdir()

            old_sha = "a" * 64
            candidate = root / "candidate.ipa"

            with zipfile.ZipFile(candidate, "w") as z:
                z.writestr(
                    "Payload/Feather.app/Info.plist",
                    plistlib.dumps({
                        "CFBundleIdentifier": "app.zagstore.ios",
                        "CFBundleShortVersionString": version,
                        "CFBundleVersion": str(build),
                    })
                )

            sha = hashlib.sha256(candidate.read_bytes()).hexdigest()
            filename = f"zagstore-{sha}.ipa"
            shutil.copyfile(candidate, releases / filename)

            current = releases / "current.json"
            current.write_text(json.dumps({
                "version": "1.0.0",
                "build": "5",
                "sha256": old_sha,
                "filename": f"zagstore-{old_sha}.ipa",
            }))

            tracked = [current]

            for name in (
                "byoc_signing_job.py",
                "byoc_signing_worker_main.py",
            ):
                path = services / name
                path.write_text(f"TRUSTED_SOURCE = '{old_sha}'\n")
                tracked.append(path)

            for site in ("zagstore-preview", "zagstore.app"):
                site_root = root / "www" / site
                staged = site_root / "zag-approved-ipas"
                staged.mkdir(parents=True)
                shutil.copyfile(candidate, staged / filename)

                approved = site_root / "zag-approved-releases.json"
                approved.write_text(json.dumps({
                    "channels": {
                        "beta": {
                            "version": "1.0.0",
                            "build": 5,
                            "sha256": old_sha,
                            "released": "2026-11-27T14:13:06Z",
                        }
                    }
                }))

                plugin = site_root / (
                    "public/wp-content/plugins/"
                    "zagstore-byoc-installer/"
                    "zagstore-byoc-installer.php"
                )
                plugin.parent.mkdir(parents=True)
                plugin.write_text("<?php /* Dynamic release fixture */\n")

                tracked.extend([approved, plugin])

            before = {p: p.read_bytes() for p in tracked}
            operations = []

            source = SOURCE.replace(
                'P("/opt/zagstore/signing-engine")',
                f"P({str(engine)!r})"
            ).replace(
                'P("/var/www")',
                f"P({str(root / 'www')!r})"
            ).replace(
                'P("/root/zag-release-backups")',
                f"P({str(root / 'backups')!r})"
            )

            def fake_run(*args, **kwargs):
                command = list(args[0])
                operations.append(command)

                if command[0] == "cp":
                    shutil.copy2(command[-2], command[-1])

                if (
                    failure == "restart"
                    and command[:2] == ["systemctl", "restart"]
                    and sum(
                        c[:2] == ["systemctl", "restart"]
                        for c in operations
                    ) == 1
                ):
                    raise subprocess.CalledProcessError(1, command)

                if failure == "busy" and command[0] == "bash":
                    raise subprocess.CalledProcessError(1, command)

                return subprocess.CompletedProcess(command, 0)

            def fake_output(command, **kwargs):
                operations.append(command)
                url = command[-1]

                if failure == "preview" and "preview." in url:
                    raise subprocess.CalledProcessError(1, command)

                if failure == "production" and "preview." not in url:
                    raise subprocess.CalledProcessError(1, command)

                return (
                    f'Zag Store {version} Beta {build} '
                    '<time datetime="2026-11-28">'
                ).encode()

            argv = [
                "zag-activate-release",
                "--sha256", sha,
                "--released", "2026-11-28T12:00:00Z",
            ]

            with (
                patch.object(sys, "argv", argv),
                patch("os.geteuid", return_value=0),
                patch("subprocess.run", side_effect=fake_run),
                patch("subprocess.check_output", side_effect=fake_output),
                patch("time.sleep"),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                if failure:
                    with self.assertRaises(Exception):
                        exec(compile(source, "activation", "exec"), {})
                else:
                    exec(compile(source, "activation", "exec"), {})

            if failure:
                for path, content in before.items():
                    self.assertEqual(path.read_bytes(), content, str(path))
            else:
                self.assertEqual(
                    json.loads(current.read_text())["sha256"], sha
                )

                for path in tracked:
                    if path.name == "zag-approved-releases.json":
                        beta = json.loads(
                            path.read_text()
                        )["channels"]["beta"]
                        self.assertEqual(beta["sha256"], sha)
                        self.assertEqual(beta["build"], build)

                    if path.suffix == ".php":
                        self.assertEqual(path.read_bytes(), before[path])

            if failure in ("busy", "downgrade"):
                self.assertFalse(any(
                    c[:2] == ["systemctl", "restart"]
                    for c in operations
                ))

    def test_successful_activation(self):
        self.exercise()

    def test_preview_failure_rollback(self):
        self.exercise(failure="preview")

    def test_production_failure_rollback(self):
        self.exercise(failure="production")

    def test_worker_restart_failure_rollback(self):
        self.exercise(failure="restart")

    def test_busy_signing_worker(self):
        self.exercise(failure="busy")

    def test_downgrade_rejected(self):
        self.exercise(failure="downgrade", build=4)

    def test_new_version_build_reset(self):
        self.exercise(version="1.1.0", build=1)

    def test_remote_staging_path(self):
        source = P(__file__).with_name(
            "zag-release-unified.py"
        ).read_text()

        import ast
        patterns = [
            node.value for node in ast.walk(ast.parse(source))
            if isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and node.value.startswith("/tmp/zag-release")
            and "[A-Za-z0-9]" in node.value
        ]

        self.assertEqual(len(patterns), 1)
        self.assertIsNotNone(re.fullmatch(
            patterns[0], "/tmp/zag-release.AbCd1234"
        ))
        self.assertIsNone(re.fullmatch(
            patterns[0], "/tmp/zag-release/AbCd1234"
        ))

if __name__ == "__main__":
    unittest.main(verbosity=2)
