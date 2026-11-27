#!/usr/bin/env python3
"""Extract shareable installer error codes from a local iPhone .logarchive."""

import argparse
import json
import re
import subprocess
from pathlib import Path

PROCESSES = ("appstored", "appstoreagent", "installd", "installcoordinationd", "itunesstored")
ERROR = re.compile(
    r"\b(ASDErrorDomain|MIInstallerErrorDomain|IXUserPresentableErrorDomain|IXErrorDomain|"
    r"MIContainerManagerErrorDomain|NSURLErrorDomain|NSPOSIXErrorDomain|"
    r"LSApplicationWorkspaceErrorDomain|ApplicationVerificationFailed|MIFreeProfileValidatedAppTracker)\b"
    r"(?:\s*(?:Code\s*=\s*|[:=]\s*)(-?\d{1,10}|0x[0-9a-fA-F]{1,8})\b)?"
)
BUNDLE = re.compile(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")


def extract(records, bundle):
    marker = re.compile(r"(?<![\w.-])" + re.escape(bundle) + r"(?![\w.-])")
    counts = {}
    for record in records:
        process = Path(record.get("processImagePath") or "").name
        if process not in PROCESSES:
            continue
        message = record.get("eventMessage") or ""
        scope = "bundle-linked" if marker.search(message) else "same-window"
        matches = set(ERROR.findall(message))
        folded = message.casefold()
        if "maximum number" in folded and any(
            marker in folded for marker in ("free developer profile", "free development profile")
        ):
            matches.add(("FreeProfileLimitMessage", ""))
        for error in matches:
            key = (scope, process, *error)
            counts[key] = counts.get(key, 0) + 1
    return [
        {"scope": scope, "process": process, "domain": domain,
         "code": int(code, 16 if code.startswith("0x") else 10) if code else None, "events": count}
        for (scope, process, domain, code), count in sorted(counts.items())
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--start", required=True, help="Mac local time, YYYY-MM-DD HH:MM:SS")
    parser.add_argument("--end", required=True, help="Mac local time, YYYY-MM-DD HH:MM:SS")
    parser.add_argument("--bundle", required=True)
    args = parser.parse_args()
    if not args.archive.is_dir() or args.archive.suffix != ".logarchive" or not BUNDLE.fullmatch(args.bundle):
        parser.error("Provide an extracted .logarchive directory and exact bundle identifier")
    predicate = " OR ".join(f'process == "{process}"' for process in PROCESSES)
    try:
        result = subprocess.run(
            ["/usr/bin/log", "show", "--archive", str(args.archive.resolve()), "--start", args.start,
             "--end", args.end, "--info", "--debug", "--style", "json", "--predicate", predicate],
            capture_output=True, check=True, timeout=120,
        )
        print(json.dumps(extract(json.loads(result.stdout), args.bundle), indent=2))
    except (OSError, subprocess.SubprocessError, ValueError):
        parser.exit(1, "Unable to read the archive in the specified time window. Check its path and timestamps.\n")


if __name__ == "__main__":
    main()
