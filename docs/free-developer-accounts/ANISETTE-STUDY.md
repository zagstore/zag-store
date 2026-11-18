# Anisette provider reliability study (plan, not started)

Purpose: decide whether the candidate recommended provider (`ZagAnisetteProviderCatalogue.recommended`, currently `pending`) can be approved as the default, using evidence rather than reputation. Nothing here runs until you approve it. It is independent of the debug sign-in screen, which uses simulated anisette only.

## Principles

- **No Apple Account.** The study never signs in, never sends credentials and never contacts Apple directly.
- **No real device identity.** Probes run from the Mac, not from an iPhone. Any step that needs a client identity uses a disposable one created for the study and deleted at the end; it is never linked to you or to a device you use.
- **Minimal data kept.** Each probe records only: time, provider, outcome category, HTTP status, latency, TLS certificate chain validity, leaf certificate fingerprint and expiry. Response values are never written to disk or logs; at most a count and a pass/fail from `ZagAnisetteData(validating:)`.
- **Polite load.** One probe every 30 minutes per provider (about 336 per week), with no retries inside a probe. The study stops at once if a provider asks clients to back off or returns rate-limit errors twice in a row.
- **System TLS only.** The probe uses the same `ZagHTTPTransport` and `ZagTransportPolicy` as the app: HTTPS only, allow-listed host, no trust overrides.

## Stages

| Stage | What runs | Needs approval for |
|---|---|---|
| 1. Passive checks (1 day) | TLS chain, certificate expiry, DNS, reachability of the provider's public status or information page. No anisette data requested. | Running a scheduled probe from your Mac |
| 2. Availability (7 days) | Stage 1 every 30 minutes, at different times of day, plus latency percentiles | — (same approval) |
| 3. Compatibility (bounded) | With a disposable client identity: up to 20 requests over the 7 days, each checked only by `ZagAnisetteData(validating:)`; values discarded immediately | Live anisette requests, separately. This requires temporarily enabling the live provider in a test-only build or harness, never in the app's release configuration |
| 4. Privacy review (desk) | The provider's published retention, logging and operator information; whether the project documents what the server stores per client | — |

## Approval criteria (proposed)

- Availability of at least 99% over 7 days, with no outage longer than 2 hours.
- Median latency under 1.5 s and 95th percentile under 5 s.
- A valid public certificate chain throughout, with no unexplained certificate changes.
- 100% of stage 3 responses pass validation.
- A documented operator and no known retention of client data beyond what the service needs. If this is unclear, the provider can still be offered, but as "community provider" with a clear notice instead of as the silent default.

## Outputs

- A short report, in this folder: per-stage results, the probe log (with the minimal fields only), and a recommendation (approve, approve with notice, or reject).
- If approved, a one-line change of `evaluation` from `pending` to `approved`, in its own commit.
- If rejected, an alternative: another public provider (same study), or the documented path to a first-party provider.

## Decisions (18 November 2026)

1. Stages 1–2: **approved**, with the privacy and rate limits above.
2. Stage 3: **not approved**.
3. Criteria: the proposed availability and latency thresholds are confirmed.

## Running (stages 1–2, approved 18 November 2026)

Stage 3 is **not** approved and nothing in the tooling requests anisette data.

- Tooling: `scripts/zag-anisette-study.sh` (install, report, uninstall) and `scripts/ZagAnisetteStudyProbe.swift` (one HTTPS request through the app's `ZagURLSessionTransport`).
- Each probe: a DNS lookup; a TLS handshake verified against the system's trusted roots (`Verify return code: 0`), recording the leaf fingerprint and expiry; and one request for `/robots.txt`, a path that is not an anisette endpoint. Any HTTP reply below 500 over a verified connection counts as up. A probe made while this Mac is offline is skipped, not counted as an outage.
- Schedule: a launchd agent (`app.zagstore.anisette-study`) every 30 minutes for 7 days, then it stops itself. It also stops after two rate-limit (HTTP 429) replies in a row. Data: `~/Library/Application Support/ZagStore Anisette Study/probes.jsonl`. Probes missed while the Mac sleeps show as reduced coverage in the report.
- Period: 18 November 11:54 to 25 November 11:54 GMT, provider `ani.sidestore.io`. The first attempt at 11:53 recorded a false TLS failure: LibreSSL's `s_client` exits non-zero even after a verified handshake. That record was discarded, the check now reads the verification result, and it was confirmed to reject an expired certificate. The period then restarted.
- `scripts/zag-anisette-study.sh report` prints the figures against the thresholds and gives no verdict before the period ends. A certificate renewal during the week is expected (the current leaf expires 4 December) and is not by itself a failure.
