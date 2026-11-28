#!/usr/bin/env python3
"""Report only method, asset, status, and bytes from one private OTA job's Nginx records."""

import argparse
from collections import Counter
import json
import re
import sys

REQUEST = re.compile(
    r'"(GET|HEAD) /wp-json/zag-byoc/v1/ota/([0-9a-f]{32})/(install|manifest|ipa)'
    r'(?:\?[^ "\r\n]*)? HTTP/[0-9.]+" (\d{3}) (\d+|-) '
)


def audit(lines, job, size):
    counts = Counter()
    for line in lines:
        match = REQUEST.search(line)
        if match and match[2] == job:
            method, _, asset, status, size_text = match.groups()
            counts[method, asset, int(status), int(size_text) if size_text.isdecimal() else None] += 1
    return [
        {"method": method, "asset": asset, "status": status, "body_bytes": body,
         "requests": count, "full_ipa_response": (method, asset, status, body) == ("GET", "ipa", 200, size)}
        for (method, asset, status, body), count in sorted(counts.items(), key=lambda item: str(item[0]))
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job", required=True)
    parser.add_argument("--ipa-size", required=True, type=int)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{32}", args.job) or args.ipa_size <= 0:
        parser.error("Supply the exact job ID and verified IPA byte size")
    print(json.dumps(audit(sys.stdin, args.job, args.ipa_size), indent=2))


if __name__ == "__main__":
    main()
