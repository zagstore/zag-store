#!/usr/bin/env python3
"""Capture an existing OTA incident from a paired iPhone without another install."""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import tempfile

PROBE = "app.zagstore.ota-probe.FTB8PRW638"


LOG_NAMES = ("system_logs.logarchive", "system_logs_full.logarchive")


class CollectionError(Exception):
    """A safe, stage-specific diagnostic message."""


def extract_logs(source, output):
    destination = output / "extracted"
    try:
        stat = source.stat()
        identity = [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns]
    except OSError as error:
        raise CollectionError(f"Archive discovery: {type(error).__name__}. Check the capture path and read permissions.") from None
    candidates = [destination / name for name in LOG_NAMES]
    if destination.exists() or destination.is_symlink():
        available = [path for path in candidates if path.is_dir() and not path.is_symlink()]
        if len(available) == 1 and not destination.is_symlink():
            try:
                if json.loads((destination / "source.json").read_text()) == identity:
                    return available[0]
            except (OSError, ValueError):
                pass
        raise CollectionError("Archive reuse: expected one completed system log archive. Choose a new --output directory.")

    try:
        with tempfile.TemporaryDirectory(prefix=".extract-", dir=output) as scratch:
            selected = set()
            files = set()
            with tarfile.open(source, "r|*") as archive:
                for member in archive:
                    path = PurePosixPath(member.name)
                    parts = path.parts
                    index = next((i for i, part in enumerate(parts) if part in LOG_NAMES), None)
                    if index is None:
                        continue
                    if path.is_absolute() or ".." in parts or not (member.isdir() or member.isfile()):
                        raise CollectionError("Archive extraction: unsafe path or entry type in the system log archive.")
                    relative = PurePosixPath(*parts[index:])
                    selected.add(parts[:index + 1])
                    if len(selected) != 1:
                        raise CollectionError("Archive extraction: multiple system log archives. Supply one extracted .logarchive.")
                    if member.isfile():
                        if len(relative.parts) < 2 or relative in files:
                            raise CollectionError("Archive extraction: duplicate file or invalid log archive root.")
                        files.add(relative)
                        member.name = str(relative)
                        archive.extract(member, scratch, filter="data")
            if not files:
                raise CollectionError("Archive discovery: no system_logs.logarchive or system_logs_full.logarchive found.")
            (Path(scratch) / "source.json").write_text(json.dumps(identity))
            Path(scratch).rename(destination)
    except (tarfile.TarError, OSError, EOFError) as error:
        raise CollectionError(
            f"Archive extraction: {type(error).__name__}. Check archive readability, integrity and available disk space."
        ) from None
    return destination / next(iter(selected))[-1]


def collect(args, output):
    prefix = ["xcrun", "devicectl", "device"]
    if not args.archive:
        probe = subprocess.run(prefix + ["sysdiagnose", "--help"], check=True, capture_output=True, text=True)
        help_text = probe.stdout + probe.stderr
        if "--device" not in help_text or "--destination" not in help_text:
            raise CollectionError("Device capture: Xcode does not expose sysdiagnose with --device and --destination.")
        command = prefix + ["sysdiagnose", "--device", args.device, "--destination", str(output)]
        if "--gather-full-logs" in help_text:
            command.append("--gather-full-logs")
        with (output / "capture.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)
    if args.device:
        with (output / "inventory.log").open("w") as log:
            status = subprocess.run(prefix + ["info", "apps", "--device", args.device, "--include-all-apps",
                                              "--json-output", str(output / "apps.json")],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=120)
        if status.returncode:
            print("Installed-app inventory unavailable. See private inventory.log.", file=sys.stderr)
    if args.archive and args.archive.is_dir():
        if args.archive.suffix == ".logarchive":
            return args.archive
        archives = list(args.archive.glob("*.tar.gz"))
    else:
        archives = [args.archive] if args.archive else list(output.glob("*.tar.gz"))
    if len(archives) != 1:
        raise CollectionError("Archive discovery: expected one sysdiagnose tar.gz. Supply its path with --archive.")
    return extract_logs(archives[0], output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="Paired device name or CoreDevice identifier")
    parser.add_argument("--archive", type=Path, help="Existing capture directory, sysdiagnose tar.gz, or extracted .logarchive")
    parser.add_argument("--output", type=Path, help="Private output directory to create or resume")
    parser.add_argument("--start", required=True, help="Incident start in Mac local time, YYYY-MM-DD HH:MM:SS")
    parser.add_argument("--end", required=True, help="Incident end in Mac local time, YYYY-MM-DD HH:MM:SS")
    parser.add_argument("--bundle", default=PROBE)
    args = parser.parse_args()
    if not args.device and not args.archive:
        parser.error("Supply --device or --archive")
    if not hasattr(tarfile, "data_filter"):
        parser.error("Use Python 3.12 or newer for safe archive extraction")
    os.umask(0o077)
    try:
        output = args.output or Path(tempfile.mkdtemp(prefix="zag-ota-diagnostics-", dir=Path.home() / "Downloads"))
        output.mkdir(mode=0o700, exist_ok=True)
        if output.is_symlink() or output.stat().st_mode & 0o077:
            raise CollectionError("Output preparation: choose a private directory with mode 0700.")
    except (OSError, CollectionError) as error:
        parser.exit(1, (str(error) if isinstance(error, CollectionError) else
                         f"Output preparation: {type(error).__name__}. Choose a writable directory.") + "\n")
    print(f"Private diagnostic files: {output}", flush=True)
    try:
        archive = collect(args, output)
        with tempfile.NamedTemporaryFile(mode="w", dir=output, delete_on_close=False) as report:
            subprocess.run([sys.executable, str(Path(__file__).with_name("zag-ota-diagnostics.py")),
                            str(archive), "--start", args.start, "--end", args.end, "--bundle", args.bundle],
                           stdout=report, check=True)
            Path(report.name).replace(output / "shareable-codes.json")
    except CollectionError as error:
        parser.exit(1, str(error) + "\n")
    except subprocess.CalledProcessError as error:
        parser.exit(1, f"Capture or log analysis failed with exit {error.returncode}. "
                    "Review the stage message or private capture.log. Resume with --archive and --output.\n")
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        parser.exit(1, f"Capture or log analysis: {type(error).__name__}. Review private capture.log "
                    "or resume from the archive with --archive and --output.\n")
    print((output / "shareable-codes.json").read_text(), end="")


if __name__ == "__main__":
    main()
