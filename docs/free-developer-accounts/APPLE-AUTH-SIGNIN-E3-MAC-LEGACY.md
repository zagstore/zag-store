# E3 — legacy `Mac OS X;` client-info identity (OFFLINE PREP, NOT RUN)

Applies the independently-confirmed fix for the 2026-11-20 GSA-edge 503 (see
`APPLE-AUTH-SIGNIN-503-ASSESSMENT.md`): present the legacy `Mac OS X;` client-info
that the edge accepts, instead of `macOS;` which it rejects. Isolated in a new
`mac-legacy-experiment` Keychain scope; the `device` and `mac-experiment`
profiles are untouched. No Apple contact in this prep.

## Provenance and differences (requirement 3)

**Provenance.** The client-info and User-Agent are the independently-confirmed
working values from [SideStore #1745](https://github.com/SideStore/SideStore/issues/1745)
/ [LiveContainer #1744](https://github.com/LiveContainer/LiveContainer/issues/1744)
(ref [#1752](https://github.com/SideStore/SideStore/issues/1752)):

```
X-MMe-Client-Info: <MacBookPro13,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>
User-Agent:        akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0
```

**Differences from our `.mac` preset** (`<MacBookPro18,3> <macOS;13.1;22C65>`,
UA `akd/1.0`): the OS token `macOS;` → `Mac OS X;` (the whole point), a different
model/version string, and the legacy akd User-Agent. **Unchanged:** the ADI
algorithm, the identity derivation (`.macLegacy` shares `.mac`'s
`ProfilePlatform::mac`), the SRP implementation, provisioning, Keychain
protections, transport restrictions and no-retry behavior.

## How it is applied — supported override, not a vendored patch

apple-auth already exposes a first-class client-info / User-Agent override:
`aauth_client_config.headers_json` → `ClientOptions.headers`, merged **last** by
`apply_device_headers` (`client_support.cpp`) — and `merge_headers` overwrites,
so the override wins. `apply_device_headers` runs in **every** header path:
anisette (`client.cpp:429`), **provisioning** (`store.cpp:491/581/632/637`) and
auth (`login → headers()`, `client.cpp:588`). So the legacy client-info is used
**consistently** across provisioning, anisette and GrandSlam authentication
(requirement 4) from a single point — `ZagAppleAuthPlatform.macLegacy`
supplying `headers_json` in `ZagAppleAuthMachine.withClient`.

**Deviation from the brief (items 2 and 9), flagged for your call.** The brief
asked for a vendored apple-auth patch + xcframework rebuild. I did **not** patch
or rebuild, because:

- The override is strictly narrower and reproducible, and modifies **no** preset
  (requirement 5) — the `macOS;` token is hard-coded in `client.cpp`
  `device_headers`, so a patch would either edit the existing Mac preset
  (forbidden) or add a new `DevicePlatform` touching ~8 switch sites, risking the
  proven Mac identity.
- A new vendored preset would **not** reach the provisioning path, which calls
  `describe_device(DevicePlatform::mac)` (the standard Mac descriptor) — only the
  `apply_device_headers` override covers provisioning, anisette and auth alike.
- The same experimental xcframework is reused unchanged; what Apple sees on the
  wire (the legacy `Mac OS X;` client-info + UA) is identical either way, so the
  experiment's validity is unaffected.

If you want binary-level provenance instead, I can add a vendored patch (a
`mac-legacy` descriptor + `device_headers`/provisioning edits) and rebuild — say
so and I will.

## Isolation, consistency and diagnostics

- New scope `mac-legacy-experiment`; `.macLegacy` uses the Mac algorithm and the
  same scope for provisioning, anisette and sign-in (one machine instance → one
  platform, no cross-phase drift).
- Offline assertion `clientInfoConsistent(headers, .macLegacy)` requires the
  anisette `X-MMe-Client-Info` to contain `Mac OS X` (not `macOS`); it runs in
  the provider path, the provision report and the sign-in report.
- The per-request `http_trace` (stage, status, allowlisted `Retry-After`) is
  included in both the provisioning and sign-in reports.

## Offline validation (no Apple contact) — done

- Host tests (all pass): `.macLegacy` OS token, scope label, shared Mac
  algorithm, the full consistency matrix (legacy vs mac vs iphone), the override
  values and legacy User-Agent, plus the existing http-trace/sanitizer suite.
- Compiles **and links** `arm64-apple-ios`; the legacy strings are embedded.
- On-device offline run (`ZAG_RUN_MACLEGACY_SELFCHECK`, transport refused):
  `{platform:"mac-legacy", scope:"mac-legacy-experiment", outcome:"not-provisioned",
  request_count:0, credential:"present", iphone_baseline:10/consistent,
  mac_experiment:10/consistent}` — the legacy scope starts empty, both existing
  profiles intact, zero Apple contact. (The live legacy `Mac OS X;` header is
  asserted at Step A via `client_info_consistent`.)

## Proposed Step A — provisioning (awaiting separate authorization)

1. Launch `ZAG_RUN_MACLEGACY_PROVISION=1`. apple-auth provisions a fresh Mac
   identity in the `mac-legacy-experiment` scope, presenting the legacy client-info.
2. **Request ceiling: 3** (lookup → midStartProvisioning → midFinishProvisioning),
   no retry, no fallback, `*.apple.com` HTTPS only.
3. **Expected output** (`zag_maclegacy_provision.json`): `result: "provisioned"`,
   `request_count: 3`, `http_statuses: [200,200,200]`, `http_trace` per stage,
   `anisette_header_count: 10`, **`client_info_consistent: true`** (proves the
   legacy `Mac OS X;` token is live on-device), `offline_header_count: 10`.
4. **Preservation checks:** `iphone_baseline_header_count: 10` + consistent and
   `mac_experiment_header_count: 10` + consistent — both prior profiles unchanged.

No sign-in (Step B) and no authentication are performed at Step A. Step B needs
its own separate authorization. Objective unchanged: fully standalone on-device
auth — no Android libraries, no Mac companion, no remote anisette server; only
the client-info token is corrected to what Apple's edge currently accepts.

---

## E3 Step B result (2026-11-24) — 503 resolved; SRP authenticated; 2FA gate

One supervised live sign-in on the legacy identity (harness commit 9f38e21c):

```json
{ "outcome": "rejected(4)", "stage": "srp-complete", "request_count": 3,
  "http_trace": [{"lookup":200},{"srp-init":200},{"srp-complete":200}],
  "client_info_consistent": true, "ec": absent, "em": absent, "retry_after": absent,
  "iphone_baseline": "10/consistent", "mac_experiment": "10/consistent",
  "profile_intact_header_count": 10 }
```

**Interpretation (HIGH confidence, source-grounded).**
- **503 resolved:** `srp-complete` returned HTTP 200 (the `macOS;` identity got
  503 here). The legacy `Mac OS X;` client-info was the whole cause.
- **SRP authenticated end-to-end, standalone:** reaching a 4th request requires
  (`authentication.cpp:229-245`) `proof.verify(M2)` to pass (mutual SRP proof →
  correct credentials), the session `spd` to decrypt, and
  `grandslam_account_state` to run. A non-2FA login returns at request 3 with
  `AAUTH_OK`; the only path to a 4th request is **account_state ≠ authenticated
  → 2FA**. So our on-device clean-room Mac anisette is accepted for interactive
  GrandSlam sign-in with no remote anisette server.
- **`rejected(4)` is a label artifact:** `4 == AAUTH_NETWORK_ERROR`
  (`c_api.h:34`), not an Apple `ec`. The account requires 2FA; apple-auth's 2FA
  initiation (the 4th request — SMS/trusted-device *config* fetch) was refused by
  the hard 3-request ceiling, surfacing as a network error. **No SMS/push sent,
  no code submitted** (refused at config fetch, before any delivery). Our
  fallback classifier maps "non-OK status + Apple reached" to `rejected(code)`,
  hence `rejected(4)`.

**Proposed follow-ups (each needs separate authorization):**
1. *Offline, diagnostic-only:* refine the classifier so a post-`srp-complete`
   `AAUTH_NETWORK_ERROR` after three 200s is reported as
   `two-factor-required (ceiling reached)` rather than `rejected(4)`, for an
   unambiguous record. No protocol change.
2. *Decision (not code):* whether to allow one 2FA-completion attempt — which
   necessarily exceeds 3 requests, submits a code and triggers delivery — or to
   stop here, having proven standalone authentication works up to the 2FA gate.
