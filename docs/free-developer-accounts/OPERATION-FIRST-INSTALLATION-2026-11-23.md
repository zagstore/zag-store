# Operation First Installation — provider matrix, −29003 diagnosis, review packages, execution plan (2026-11-23)

Integration HEAD `08acff87` (`feature/native-adi-provider-review`); `main`
untouched. This document eliminates the research unknowns blocking a credible
free-account install on a real iPhone. It performs no live Apple operation,
approves no gate, and grants no authorization. Legal and security conclusions
are flagged for qualified independent review.

---

## 1. Anisette provider decision matrix (item 2)

The remote `remote_v3` client (`AppleAuthCore/zag-isideload`, MIT upstream) needs
a *server*. "Publicly available source" is **not** permission to deploy, and an
endpoint answering HTTP is **not** evidence of usability. License/maintenance
below are from the GitHub API on 2026-11-23; dependency/privacy from the
`ANISETTE-STUDY.md` stage-4 desk review and the sources cited.

| Candidate | Repo / status | License (authoritative) | Apple proprietary deps | v3-client compatible | Privacy/security | Reliability evidence | Usable in a controlled test w/o unresolved legal deps? |
|---|---|---|---|---|---|---|---|
| **SideStore omnisette-server** | [`SideStore/omnisette-server`](https://github.com/SideStore/omnisette-server), last push 2026-04-17; README says "essentially replaced by" Dadoum's server | **NONE** (no LICENSE file) | Yes — loads `libCoreADI.so`/`libstoreservicescore.so` from Apple Music Android APK at runtime | Yes (v3 `/v3/*`) | Depends on deployment; omnisette crate is MPL-2.0 but the server wrapper is unlicensed | Superseded; little current evidence | **No** — no deploy grant; Apple-libs question |
| **Dadoum anisette-v3-server** | [`Dadoum/anisette-v3-server`](https://github.com/Dadoum/anisette-v3-server), last push 2026-09-23 (most actively maintained server) | **NONE** (no LICENSE file) | Yes — same Apple Android libs; also provisions a v1 machine with Apple on first start | Yes (matches our client's sequence per PR #44) | Published form logs the client anisette identifier and full v1 headers; serves an unauthenticated v1 `/` that provisions on demand (desk-review §blockers) | Studied instance below threshold (see §7) | **No** — no deploy grant; Apple-libs question; privacy defects to contain |
| **Dadoum/Provision (ADI lib)** | [`Dadoum/Provision`](https://github.com/Dadoum/Provision), last push 2025-06-23 | **LGPL-2.0** (GitHub: NOASSERTION; `COPYING-LGPLv2` present) | Yes — wraps Apple's ADI libs | Library, not a server | n/a | n/a | Library licence is usable; still needs Apple libs |
| **SideStore apple-private-apis (omnisette crate)** | [`SideStore/apple-private-apis`](https://github.com/SideStore/apple-private-apis), last push 2024-11-14 | **MPL-2.0** | The crate itself contacts anisette servers; local-ADI feature would need Apple libs | This is the lineage our client derives from | File-level copyleft | n/a (client lib) | Client side only — **yes**, licence-clear |
| **SideStore/anisette-servers (list)** | [`SideStore/anisette-servers`](https://github.com/SideStore/anisette-servers), last push 2026-10-25 | **AGPL-3.0** | n/a (a config/list of public servers) | n/a | Public third-party operators; unknown retention | Third-party uptime varies | **No** for *relying* on a third-party operator for a credential-bearing flow without an agreement |
| **First-party Zag anisette service** | Not built | Would be Zag's own (GPL-3.0 repo) | **Still needs Apple's Android ADI libs** unless an independent ADI is implemented (see §3) | By construction | Controlled by us: discard stdout, proxy only `/v3/*`, DNS-only TLS | n/a | **Only if** the Apple-libs question (B) is resolved, or an independent ADI exists |

**Conclusion.** No currently available server is usable in a controlled test
without an unresolved legal dependency: the two deployable v3 servers carry **no
license at all** (no grant to deploy or modify), and *every* option depends on
Apple's extracted Android ADI libraries, whose use is an Apple-terms question,
not a copyright one. The client side is clean (MIT + MPL-2.0).

---

## 2. Native ADI −29003: evidence-based diagnosis (item 3)

**Verified facts (our implementation + captured evidence):**
- Our one live native-ADI attempt failed at `finishMachineProvisioning` with
  **HTTP 401** (PR #44).
- Our exchange shows **no protocol defect**: method, endpoints, headers, plist
  bodies, the native Start/End sequence and the worker hex framing match the
  `zag-isideload` client, Dadoum/Provision templates and anisette-v3-server
  (PR #44, with reference fixtures).
- Our configuration ran the Apple Music **Android** CoreADI libraries while
  advertising the upstream **macOS** identity — a configuration mismatch that is
  a fact about our setup.
- **We did not capture an Apple `ec` for our own 401**: it predates PR #44's
  `ec` capture. So **we never directly observed −29003 ourselves.**

**Hypotheses (not confirmed by Apple):**
- That the 401 is caused by the Android-ADI-vs-macOS-identity mismatch is the
  **leading hypothesis**, supported by *public reports* (SideStore/SideStore#1745,
  2026-11-22; Dadoum/anisette-v3-server#61/#62, 2026-11-11/12) that Android-ADI
  v3 servers fail `finishMachineProvisioning` with `−29003 "possible environment
  mismatch"` while Mac/Windows-ADI pass, and Android ADI gets `−80045` at
  sign-in. These are community observations, not an Apple statement.
- A separate `503` for `macOS;` client info (iloader v2.4.2, 2026-11-20) is a
  reported sign-in edge block, distinct from the 401/−29003.

**What this does and does not establish.** It is established that our protocol
is correct and that our run used an inconsistent ADI/identity pairing. It is
*not* established — by our evidence — that −29003 is the specific cause of our
401, because we never captured that code. The responsible reading: the mismatch
is the most likely cause given consistent third-party evidence, and the fix
direction is to stop presenting an inconsistent ADI/identity configuration as
ready (PR #46's guard), not to "defeat" a 401.

**Independent, appropriately licensed ADI alternative?** Not established. Every
known path (Android CoreADI, Windows `CoreADI64.dll`, macOS ADI) relies on
Apple's proprietary libraries. A clean-room independent ADI implementation is
not known to exist and would be a major undertaking of uncertain legality under
Apple's terms. **We do not have a technically and legally viable ADI alternative
that avoids Apple's extracted libraries; this is documented, not worked around.**

---

## 3. Recommended legally defensible architecture

Given §1–§2, the only architecture with a clean *copyright* position today is:
- **Client:** our `remote_v3` client (MIT/MPL-2.0, pending the G2.A review).
- **Server:** a provider whose operator has granted deployment/use in writing,
  **or** a first-party server — but either still hits the **Apple-terms**
  question on the ADI libraries (item B below), which is unresolved.

So the defensible *interim* position is: **do not self-host or rely on an
unlicensed server for a credential-bearing flow.** A first live test is
architecturally ready on the client side but is **blocked** until (a) a licensed
or permissioned server exists and (b) the Apple-terms question is answered by
qualified counsel. Native/Android ADI is not recommended as the first route.

---

## 4. G2 independent legal-review package (item 4)

Two separate questions; neither is answered here.

**A. Copyright / open-source licensing (code we retain or deploy).**
- Retained client `zag-isideload`: MIT upstream (nab138/isideload); portions
  with MPL-2.0 provenance pending review (`auth/apple_account.rs`,
  `auth/grandslam.rs`, `anisette/remote_v3/{mod,state}.rs` — long identical
  token runs vs omnisette / apple-private-apis); `dev/*` MIT. Zag's own code is
  GPL-3.0. Evidence + reproduction: `G2-LICENCE-REVIEW.md`,
  `scripts/zag-g2-reproduce.sh`, `scripts/zag_g2_similarity.py`.
- Server: both deployable v3 servers (`SideStore/omnisette-server`,
  `Dadoum/anisette-v3-server`) carry **no license** → no grant to deploy or
  modify. `Dadoum/Provision` is LGPL-2.0.
- **MPL/GPL compatibility:** MPL-2.0 is file-level copyleft and is generally
  compatible with a GPL-3.0 larger work under MPL §3.3; a reviewer must confirm
  the retained MPL files keep their notices and that the combination is
  distributed consistently.

**Precise questions for qualified counsel (copyright):**
1. Are the MPL-2.0-provenance files correctly attributed and compliant as used
   in a GPL-3.0 project (notices, source availability)? (G2 decision A)
2. For `dev/*` and `auth/*` MIT-attributed files, is attribution sufficient and
   the MIT/GPL combination clean? (decisions B, C)
3. May an unlicensed server be deployed at all, or is written permission from
   its author mandatory? (the server gap)
4. Does bundling `apple_root.cer` raise any issue? (decision D)

**B. Apple service terms (not copyright).**
- Every server requires `libCoreADI.so` + `libstoreservicescore.so` extracted
  from the Apple Music Android APK, loaded at runtime (not redistributed, but
  **downloaded from Apple**). Some servers also provision a v1 machine with
  Apple on first start.
- **Questions for counsel (Apple terms):** May those libraries be extracted and
  run server-side for this purpose under Apple's licence/terms? Does doing so
  differ between (i) purely local experimentation on the owner's own device,
  (ii) self-hosting for the owner only, and (iii) hosting for others / public
  distribution? These three contexts must be answered separately.

**Do not mark G2 approved.** It requires the independent reviewer to record
decisions A–D and counsel to answer B.

---

## 5. G4 security-review package + current-code findings (item 5)

Inspected the integrated code at `08acff87` against the `G4-SECURITY-REVIEW.md`
priority list. This is a preparation, not the independent review.

| Area | Current state (inspected) | Finding |
|---|---|---|
| Credential / 2FA confidentiality | Passwords/codes arrive as bytes in zeroising buffers, never stored, never logged (`zag-apple-bridge` lib header; data-flow §1) | No demonstrable defect |
| Session token storage / isolation | Returned to Swift for the device-only Keychain; `KeychainStorage` account-scoped (`{scope}/{key}`) | No demonstrable defect |
| Provider trust / network restrictions | `net_policy` refuses all traffic without `live-network`; HTTPS + allow-listed host | No demonstrable defect |
| Per-account anisette state | PR #54 isolates state by provider + effective client identity; fail-closed; marker-before-state | **Hardened** this sprint; no defect |
| Certificate / private-key handling | Keychain-resident key (`ZAG_ZSIGN_STRICT`); L1/L2 decisions still open (`SIGNING-KEY-SECURITY.md`) | No new defect; L1/L2 remain owner decisions |
| Test-build isolation | Gates `#if`-closed in every shipping config; bridge linked only under `ZAG_APPLE_BRIDGE` (no config sets it) | Verified closed at `08acff87` |
| Logging / diagnostics | PR #55 `ProvisioningDiagnostic` is enums/ints only; a test asserts no message text serialises; **no logging added** in the merged Rust changes | No demonstrable defect |
| Failure recovery | Provisioning failures fail-closed; `-45061` reset path fixed (anisette study/logging spec) | No new defect |

**Demonstrable defects found: none** in the merged changes. No speculative
rewrite is warranted. Open items for the independent reviewer: the
`G4-SECURITY-REVIEW.md` §11 checklist (29 items) and §10 questions (anisette
host pinning; shared vs per-account device state). **Do not self-certify G4.**

---

## 6. First-installation execution plan (item 6)

One owner-controlled iPhone on **iOS 27**; the existing implementations; every
release gate disabled. Full procedure: `LIVE-VALIDATION-PROCEDURE.md`;
build/config: `LIVE-TEST-READINESS-2026-11-23.md` §Phase 5.

**Preconditions (all required, none granted here):** G2.A review + a licensed or
permissioned server + the G2.B Apple-terms answer; G3 provider chosen after the
25 Nov study; G4 independent review; owner's G1/G5/G6 approvals; explicit
authorization of the run.

**Isolated test configuration (compilation conditions only; Release untouched):**
`ZAG_APPLE_BRIDGE` + `ZAG_ZSIGN_STRICT` + `ZAG_LIVE_EXPERIMENT` (`!DEBUG`);
bridge built `--features live`; campaign armed with the owner-chosen provider
URL + device serial.

**Sequence (stop on first failure; capture only `FailureKind` +
`ProvisioningDiagnostic`):**
1. Sign in to the dedicated free account on device; complete 2FA.
2. Anisette provisioning via the approved provider.
3. Persist the session to the device Keychain; confirm it survives relaunch.
4. Discover the free team.
5. Register the device.
6. Register the App ID; create the development certificate (watch the
   free-account certificate budget).
7. Fetch the provisioning profile.
8. Sign the IPA (`ZagStrictComponentSigning`).
9. Install over RPPairing (needs pairing + LocalDevVPN).
10. Read back the installed profile; verify against `ZagInstallExpectation`.

**Preflight:** gates read `false` in Release; test build carries the markers;
provider URL + serial set; device paired + Developer Mode on; account is the
dedicated one. **Rollback:** stop at the first failure; uninstall the test app
(separate bundle/account); delete the test build + DerivedData (shipping schemes
untouched); note any portal objects created against free-account limits and
revoke the test certificate if needed; tear down provider access; re-confirm
Release gates `false`.

---

## 7. Provider study status (item 7)

Preserved unchanged: end date **25 Nov 2026 11:54 GMT**, passive probes only,
existing rate limits, **no compatibility (stage 3) run**, no Apple contact.
Day-5 interim (2026-11-23, read-only `report`): availability **83.44%**
(126/151), longest outage **7.8 h**, **25× HTTP 502**, latency median 0.50 s /
p95 3.40 s, one leaf cert (expires 4 Dec). **IN PROGRESS — no verdict before the
period ends.** On current evidence the candidate is below the ≥99% / ≤2 h
thresholds. Final availability/latency/outage/TLS evidence to be collected when
the study concludes on 25 Nov.

---

## 8. Go / no-go for a controlled live test

**NO-GO at 2026-11-23.** The client and the on-device pipeline are ready and
offline-validated, but the external blockers are not cleared:
- **G2** open — no licensed/permissioned server; Apple-terms question on the ADI
  libraries unanswered (needs counsel).
- **G3** open — study ends 25 Nov; current candidate below threshold; no
  licensed documented provider identified.
- **G4** open — independent security review not done.
- No independent, legally clean ADI alternative to Apple's libraries exists.

**Exact remaining prerequisites (owner / independent reviewers):**
1. G2.A independent licence review (decisions A–D) **and** G2.B counsel answer on
   Apple's libraries across the three usage contexts.
2. A **licensed or permissioned** anisette server, or a first-party one once B is
   answered.
3. G3: the 25 Nov study verdict + stage-4 privacy decisions; choose provider URL
   + device serial.
4. G4: independent security review; §10 decisions.
5. G1/G5/G6 owner approvals; dedicated account ready.
6. Owner's explicit authorization of the single run.
