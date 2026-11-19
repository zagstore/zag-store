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
- Correction on 18 November, about 13:30 GMT, with no restart. The third probe's request through the app's transport succeeded: HTTP 404, which needs a valid certificate. But the separate `openssl` certificate inspection failed, and the probe counted that as an outage. Availability is now judged only by the transport request (a reply below 500 over the app's validated TLS), and the report recomputes every record that way, including earlier ones. Raw records are unchanged. Inspection failures are recorded with their reason (timeout, verification code or other) and listed separately. Any certificate verification failure in the inspection is flagged for review before a verdict.

## Interim evidence and stage 4 desk review (19 November 2026)

Interim only: the period ends 25 November and no verdict is given before then.

**Probes (`zag-anisette-study.sh report`, day 2 of 7).**
- 52 of 52 probes up (100%). Longest outage 0 h.
- Latency: median 0.84 s, 95th percentile 3.40 s.
- One leaf certificate fingerprint (`FF2FC58B…42E73E`), expiring 4 December.
- Inspection problems, recorded separately:
  - one `fail` at 18 Nov 12:55, the false failure covered by the correction above; the app's transport got HTTP 404 over validated TLS;
  - two `inspection-timeout`s, on 18 Nov 14:28 and 19 Nov 01:42. The transport succeeded both times, although the first took 41 s.
- Probes request only `/robots.txt`. No anisette endpoint has been requested.

**What the probes cannot show.**
- Stage 3 was never approved. It also cannot be done without Apple: v3 provisioning exchanges messages with `gsa.apple.com` (`remote_v3/mod.rs`, `midStartProvisioning` and `midFinishProvisioning`).
- The first anisette data from this provider will therefore come during the first live sign-in. A provider failure there is a stop (`ownerUnrecognised` or `unavailable`); it is not retried.

**What the provider receives (from the code at `027d848e`).**
- Requests to the provider's own host only:
  - `GET /v3/client_info`;
  - the provisioning WebSocket, which carries the anisette keychain identifier (random, per account scope) and the `spim`/`cpim` provisioning messages it relays to Apple;
  - `POST /v3/get_headers`, carrying the identifier and the `adi_pb` provisioning blob.
- Holding `adi_pb`, the provider can generate anisette headers for that anisette identity.
- It never receives the Apple ID, the password, 2FA codes or tokens: those go only through the Apple client, whose allowlist does not include the provider.
- It also sees the device's IP address, and the timing of each sign-in.

**Device serial (fixed policy).**
- The bridge requires one serial: 1–32 ASCII letters or digits (`live.rs`, `valid_serial`).
- The fork stores the serial but **never transmits it**. Its only header, `X-Apple-I-SRL-NO`, is commented out (`anisette/mod.rs:40`).
- The serial is therefore not a correlation identifier in this code.
- Policy: one fixed, made-up value, given privately to the build check. Never the iPhone's real serial or UDID.

**Stage 4 desk review.**
- One web search found no published privacy policy, retention statement or named operator for `ani.sidestore.io`.
- SideStore's documentation describes the service only functionally.
- This is "not found", not "does not exist". The SideStore project is the place to ask.
- Under the approval criteria above, the provider can therefore be offered only as a **community provider with a notice**, not as the silent default.
- Self-hosting an open-source v3 server is the alternative if that is not acceptable.

**Interim assessment for G3 (owner's decision).**
- The availability evidence so far meets the thresholds.
- Compatibility is unproven until the first live sign-in, and the operator's privacy practices are undocumented.
- For a controlled single-account experiment with a dedicated account and a notice, the risk is bounded:
  - the provider never receives credentials;
  - a provider failure is a stop.
- Recommended: decide after the period ends on 25 November, choosing "approve with notice" or self-hosting.
