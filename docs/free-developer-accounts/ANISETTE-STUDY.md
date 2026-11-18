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

## Remaining decisions for you

1. Approve stages 1–2 (passive and availability probes from your Mac).
2. Separately decide on stage 3 (bounded live anisette requests with a disposable identity).
3. Confirm the proposed criteria, or set your own.
