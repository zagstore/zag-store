#!/bin/bash
# Anisette provider reliability study, stages 1-2 only (approved 2026-11-18;
# docs/free-developer-accounts/ANISETTE-STUDY.md). Passive and availability
# probes of the candidate provider, from this Mac, every 30 minutes for 7 days.
#
# Each probe: DNS lookup, TLS handshake checked against the system's trusted
# roots, and one HTTPS request for /robots.txt through the app's transport.
# No anisette endpoint is ever requested (stage 3 is not approved), no Apple
# Account is used, and Apple is never contacted. Kept per probe: time,
# outcome, HTTP status, latency, certificate fingerprint and expiry.
#
#   zag-anisette-study.sh install [host]   compile the probe, schedule it (launchd)
#   zag-anisette-study.sh report           summary; no verdict before day 7
#   zag-anisette-study.sh uninstall        stop probing (data is kept)
#   zag-anisette-study.sh probe            one probe (what launchd runs)
#
# The study lives in ~/Library/Application Support/ZagStore Anisette Study
# because background jobs may not read ~/Documents.
set -euo pipefail
STUDY="$HOME/Library/Application Support/ZagStore Anisette Study"
LABEL=app.zagstore.anisette-study
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$STUDY/probes.jsonl"
DURATION=$((7 * 86400))
INTERVAL=1800

install_study() {
	local host="${1:-ani.sidestore.io}" root
	root="$(cd "$(dirname "$0")/.." && pwd)"
	[ -f "$STUDY/config" ] && { echo "A study already exists in $STUDY; uninstall it first or keep it running."; exit 1; }
	mkdir -p "$STUDY/bin"
	swiftc -warnings-as-errors -parse-as-library -O -target "$(uname -m)-apple-macos13" \
		"$root/Feather/Utilities/FreeAccount/ZagFreeAccountTransport.swift" \
		"$root/scripts/ZagAnisetteStudyProbe.swift" -o "$STUDY/bin/probe"
	cp "$root/scripts/zag-anisette-study.sh" "$STUDY/study.sh"
	printf 'HOST=%s\nSTART=%s\nEND=%s\n' "$host" "$(date +%s)" "$(( $(date +%s) + DURATION ))" > "$STUDY/config"
	mkdir -p "$(dirname "$PLIST")"
	cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$STUDY/study.sh</string><string>probe</string></array>
<key>StartInterval</key><integer>$INTERVAL</integer>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Background</string>
<key>StandardErrorPath</key><string>$STUDY/errors.log</string>
</dict></plist>
PLIST
	launchctl bootstrap "gui/$(id -u)" "$PLIST"
	echo "Study scheduled: $host every $((INTERVAL / 60)) minutes until $(date -r "$(( $(date +%s) + DURATION ))")"
}

probe_once() {
	# shellcheck disable=SC1091
	. "$STUDY/config"
	[ -f "$STUDY/STOPPED" ] && exit 0
	local now; now=$(date +%s)
	if [ "$now" -ge "$END" ]; then
		touch "$STUDY/COMPLETE"
		launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
		exit 0
	fi
	local dns=fail tls=fail fingerprint="" expiry="" http status latency outcome rc=0
	if [ -n "$(dig +short +time=5 +tries=1 "$HOST" A 2>/dev/null | head -1)" ]; then dns=ok; fi
	if [ "$dns" = ok ]; then
		local chain
		# LibreSSL's s_client exits non-zero when its input closes, even after
		# a verified handshake, so the verification result is read instead.
		chain=$(perl -e 'alarm shift; exec @ARGV' 20 openssl s_client -connect "$HOST:443" -servername "$HOST" \
			-CAfile /etc/ssl/cert.pem -verify_return_error </dev/null 2>/dev/null) || rc=$?
		if printf '%s\n' "$chain" | grep -q 'Verify return code: 0 (ok)'; then
			tls=ok
			fingerprint=$(printf '%s\n' "$chain" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g')
			expiry=$(printf '%s\n' "$chain" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
		elif [ "$rc" -eq 142 ]; then
			tls=inspection-timeout
		elif printf '%s\n' "$chain" | grep -q 'Verify return code: [1-9]'; then
			tls="verify-$(printf '%s\n' "$chain" | sed -n 's/.*Verify return code: \([0-9]*\).*/\1/p' | head -1)"
		else
			tls="inspection-failed-$rc"
		fi
	fi
	http=$("$STUDY/bin/probe" "$HOST" 2>/dev/null || true)
	read -r status latency extra <<<"$http"
	if [ "$status" = error ]; then status="error:$latency"; latency=${extra:-0}; fi
	case "$status" in
		error:offline) outcome=local-offline ;;
		[1-4][0-9][0-9]) outcome=up ;;
		*) outcome=down ;;
	esac
	printf '{"t":%s,"host":"%s","outcome":"%s","dns":"%s","tls":"%s","http":"%s","ms":%s,"cert":"%s","notAfter":"%s"}\n' \
		"$now" "$HOST" "$outcome" "$dns" "$tls" "$status" "${latency:-0}" "$fingerprint" "$expiry" >> "$DATA"
	# Stop at once after two rate-limit answers in a row.
	if [ "$(tail -2 "$DATA" | grep -c '"http":"429"')" -eq 2 ]; then
		touch "$STUDY/STOPPED"
		launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	fi
}

report() {
	[ -f "$STUDY/config" ] || { echo "No study installed."; exit 1; }
	python3 -I - "$STUDY" <<'PY'
import json, statistics, sys, time, pathlib
study = pathlib.Path(sys.argv[1])
config = dict(line.split("=", 1) for line in (study / "config").read_text().split())
start, end = int(config["START"]), int(config["END"])
path = study / "probes.jsonl"
probes = [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []
now = time.time()
# Up = a reply below 500 to the request made through the app's transport,
# which rejects invalid certificates. Recomputed here for every record, so
# records written before 18 Nov 13:3x (when a failed separate certificate
# inspection was wrongly counted as down) are judged the same way.
for p in probes:
    if p["outcome"] != "local-offline":
        p["outcome"] = "up" if p["http"][:1] in "1234" and p["http"].isdigit() else "down"
counted = [p for p in probes if p["outcome"] != "local-offline"]
up = [p for p in counted if p["outcome"] == "up"]
expected = int((min(now, end) - start) // 1800) + 1
print(f"Provider:     {config['HOST']}")
print(f"Period:       {time.strftime('%d %b %H:%M', time.localtime(start))} - {time.strftime('%d %b %H:%M', time.localtime(end))}")
print(f"Probes:       {len(probes)} of about {expected} so far ({len(probes) - len(counted)} skipped: this Mac offline)")
if counted:
    availability = 100 * len(up) / len(counted)
    print(f"Availability: {availability:.2f}% ({len(up)}/{len(counted)})   threshold >= 99%")
    longest, run_start = 0, None
    for p in counted + [{"t": now, "outcome": "up"}]:
        if p["outcome"] != "up":
            run_start = run_start or p["t"]
        elif run_start:
            longest, run_start = max(longest, p["t"] - run_start), None
    print(f"Longest outage: {longest / 3600:.1f} h   threshold <= 2 h")
    ms = sorted(p["ms"] for p in up)
    if ms:
        p95 = ms[min(len(ms) - 1, int(round(0.95 * (len(ms) - 1))))]
        print(f"Latency:      median {statistics.median(ms) / 1000:.2f} s, p95 {p95 / 1000:.2f} s   thresholds < 1.5 s, < 5 s")
    certs = sorted({p["cert"] for p in counted if p["cert"]})
    inspections = {}
    for p in counted:
        if p["tls"] != "ok": inspections[p["tls"]] = inspections.get(p["tls"], 0) + 1
    print(f"Certificates: {len(certs)} distinct leaf fingerprint(s); separate inspection problems: {inspections or 'none'}")
    if any(p["tls"].startswith("verify-") for p in counted):
        print("WARNING:      a certificate failed verification in the separate inspection; review before any verdict")
    expiries = sorted({p["notAfter"] for p in counted if p["notAfter"]})
    if expiries: print(f"Cert expiry:  {', '.join(expiries)}")
    failures = {}
    for p in counted:
        if p["outcome"] != "up": failures[p["http"]] = failures.get(p["http"], 0) + 1
    if failures: print(f"Failures:     {failures}")
if (study / "STOPPED").exists():
    print("Status:       STOPPED after repeated rate limiting; no verdict.")
elif now < end:
    print(f"Status:       IN PROGRESS, day {int((now - start) // 86400) + 1} of 7. No verdict until the period ends.")
else:
    coverage = len(probes) / max(expected, 1)
    print(f"Status:       COMPLETE (coverage {coverage:.0%}). Compare the figures with the thresholds; "
          "stage 4 (privacy review) is still required before approval.")
PY
}

uninstall_study() {
	launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	rm -f "$PLIST"
	echo "Probing stopped. Data kept in $STUDY"
}

case "${1:-}" in
	install) install_study "${2:-}" ;;
	probe) probe_once ;;
	report) report ;;
	uninstall) uninstall_study ;;
	*) sed -n '2,17p' "$0"; exit 2 ;;
esac
