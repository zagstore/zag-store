#!/usr/bin/env python3
"""Capture an existing OTA incident from a paired iPhone without another install."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

PROBE = "app.zagstore.ota-probe.FTB8PRW638"


def collect(args, output):
    prefix = ["xcrun", "devicectl", "device"]
    if not args.archive:
        probe = subprocess.run(prefix + ["sysdiagnose", "--help"], check=True, capture_output=True, text=True)
        help_text = probe.stdout + probe.stderr
        if "--device" not in help_text or "--destination" not in help_text:
            raise ValueError("This Xcode does not expose device sysdiagnose with --device and --destination.")
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
        return args.archive
    archives = [args.archive] if args.archive else list(output.rglob("*.tar.gz"))
    if len(archives) != 1:
        raise ValueError("Expected one sysdiagnose tar.gz. Use --archive to select an existing capture.")
    extracted = output / "extracted"
    with tarfile.open(archives[0], "r:*") as archive:
        logs = [item for item in archive if "system_logs.logarchive" in Path(item.name).parts]
        if not logs:
            raise ValueError("The capture contains no system_logs.logarchive.")
        archive.extractall(extracted, members=logs, filter="data")
    matches = list(extracted.rglob("system_logs.logarchive"))
    if len(matches) != 1:
        raise ValueError("Expected one system_logs.logarchive in the capture.")
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="Paired device name or CoreDevice identifier")
    parser.add_argument("--archive", type=Path, help="Existing sysdiagnose tar.gz or extracted .logarchive")
    parser.add_argument("--start", required=True, help="Incident start in Mac local time, YYYY-MM-DD HH:MM:SS")
    parser.add_argument("--end", required=True, help="Incident end in Mac local time, YYYY-MM-DD HH:MM:SS")
    parser.add_argument("--bundle", default=PROBE)
    args = parser.parse_args()
    if not args.device and not args.archive:
        parser.error("Supply --device or --archive")
    if not hasattr(tarfile, "data_filter"):
        parser.error("Use Python 3.12 or newer for safe archive extraction")
    os.umask(0o077)
    output = Path(tempfile.mkdtemp(prefix="zag-ota-diagnostics-", dir=Path.home() / "Downloads"))
    print(f"Private diagnostic files: {output}", flush=True)
    try:
        archive = collect(args, output)
        with (output / "shareable-codes.json").open("w") as report:
            subprocess.run([sys.executable, str(Path(__file__).with_name("zag-ota-diagnostics.py")),
                            str(archive), "--start", args.start, "--end", args.end, "--bundle", args.bundle],
                           stdout=report, check=True)
    except (OSError, subprocess.SubprocessError, ValueError, tarfile.TarError):
        parser.exit(1, "Collection did not complete. Review the private output directory or supply --archive.\n")
    print((output / "shareable-codes.json").read_text(), end="")


if __name__ == "__main__":
    main()
