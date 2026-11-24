# E2 Step B HTTP 503 — offline assessment (2026-11-24)

E2 Step B (Mac-consistent identity) advanced to `srp-complete` and ended on
HTTP 503. No Apple contact in this assessment; both Keychain profiles preserved.

## 1. Did SRP init return a valid challenge? YES (HIGH confidence)

Source-proven, not merely a local state advance. apple-auth's `post()`
(`authentication.cpp:190`) does `require(response.status == 200, …)` **and**
`status(result)` (the `ec` check) on every GrandSlam response *before*
returning. The sequence then (`authentication.cpp:211-231`):

1. init POST → must be HTTP 200, parseable plist, `ec == 0` (no -22410),
2. `require(initial.contains("i"))` iteration count, `0 < i ≤ 1e6`,
3. `srp.complete(email, password, s, B, i, sp)` — consumes salt `s`, server
   ephemeral `B`, iterations, `sp` from the init response to derive `M1`,
4. complete POST `{M1, c:(echoed from init), o:"complete", u, cpd}`.

Our `request_count: 3` (lookup + init + complete) proves **all of steps 1-3
succeeded** — the complete request only exists because init returned a
cryptographically complete, server-signed SRP challenge (`s`, `B`, `i`, `sp`,
`c`) that the client used to compute `M1`. A bad/absent challenge throws at init
→ `request_count` would be 2 (exactly our earlier -22410 case).

## 2. Sanitized evidence for the 503

`{outcome: http-error(503), http_status: 503, stage: srp-complete,
request_count: 3, ec: absent, em: absent}`. The **absence of `ec`/`em` is
expected and confirmatory**: 503 is caught at the HTTP layer
(`authentication.cpp:190`) *before* any plist/`ec` parsing, so there is no
GrandSlam application verdict. This is a transport/edge-layer response, **not a
GrandSlam account/identity `ec` rejection** (contrast -22410, which was a 200
JSON with `ec`).

No internal auto-retry fired: the loop `for attempt < 2` would have re-sent
init+complete (→ `request_count` 5), but the 503 threw and propagated; we
observed exactly one complete. Our transport ceiling (6) was not the limiter.

## 3. Safe 503 metadata (Retry-After / edge classification) — NOT captured

apple-auth discards response headers on non-200 (uses only the status number).
Our transport *did* receive the response header fields but does not persist
them, and no body is read. **So we currently have no Retry-After or edge
classification for this 503.** Retry-After is a standard, non-sensitive header;
capturing it (header only, never the body) is a safe future enhancement.

## 4. Complete-request construction vs upstream / known clients — MATCHES

`{M1, c:(echoed), o:"complete", u, cpd}` with version `1.0.1` is apple-auth's
verbatim construction, which matches documented working clients field-for-field.
We invoke apple-auth's own `aauth_client_login`, so we cannot have diverged. The
only run-specific content is `M1` (from the real password+salt+B) and fresh
anisette in `cpd`. **Not a formatting defect.**

## 5. Is the Mac client-info associated with 503 in public reports? YES — strongly

Credible, *very recent* reports tie **HTTP 503 from GsService2** specifically to
the **`macOS;` token in `X-Mme-Client-Info`**, beginning **2026-11-20** (four
days ago) — exactly our Mac preset `<MacBookPro18,3> <macOS;13.1;22C65> …`:

- [SideStore #1745](https://github.com/SideStore/SideStore/issues/1745) and
  [LiveContainer #1744](https://github.com/LiveContainer/LiveContainer/issues/1744):
  titled "Apple ID sign-in HTTP 503 since 2026-11-20 — GSA edge rejects `macOS;`
  in X-Mme-Client-Info."
- [iPASide #7](https://github.com/pwnapplehat/iPASide/issues/7),
  [SideInstaller #148](https://github.com/FrizzleM/SideInstaller/issues/148) /
  [#153](https://github.com/FrizzleM/SideInstaller/issues/153): the same 503 at
  the GsService2 request, **unfixed by restart, anisette reset, or switching
  anisette servers**, reproduced across machines.

This is an **ecosystem-wide, server-side GSA edge change**, not our bug: the
reference sideloading clients hit the identical wall the same week. One partial
workaround reported was a *remote* anisette server — which our standalone
objective explicitly avoids.

## 6. Transient or persistent identity/compat problem? → PERSISTENT / external

Weighing it:
- *Transient* (weak): a single 503; init succeeded.
- *Persistent* (strong): multiple independent reports this week describe the
  `macOS;`-client-info 503 as persistent, restart/anisette-immune, cross-machine
  — matching our symptom and our exact client-info token.

Verdict: the 503 is **very likely the ecosystem-wide GSA-edge rejection of the
`macOS;` client-info that began 2026-11-20** — persistent and *external*, not a
transient blip and not specific to our account or our code. One honest caveat:
the public reports place the 503 at the *initial* request, whereas ours passed
init (200) and 503'd at *complete*; the edge may apply the rule by step or
probabilistically. The association is nonetheless too specific to dismiss.

## 7. Verdict + smallest justified next experiment

**An unchanged retry is NOT justified.** It would most likely reproduce the 503
(the reports say restart/anisette changes don't help) and spend an authorization
for no new information.

What our two experiments jointly establish:
- iPhone client-info + Mac algorithm → **-22410 at init** (identity/client-info
  mismatch — our bug, now understood).
- Mac client-info (`macOS;`) + Mac algorithm → **init clears, 503 at complete**
  (external GSA-edge change against `macOS;`, 2026-11-20 — not our bug).

Every apple-auth preset we can provision currently hits one wall or the other,
and the `macOS;` wall is **Apple-side and shared by the whole ecosystem right
now**. So the highest-value next step is **not** another blind sign-in:

- **Correct first (offline, no Apple):** add safe response-header capture to the
  transport — `Retry-After` and edge status/classification header *names and
  values only, never the body* — and persist the per-request HTTP status list
  (we already have it in the transport log) to the sign-in report.
- **Then, only if you still want confirmation — one bounded attempt**, ceiling
  **3 requests**, **no auto-retry**, unchanged identity/credentials, purely to
  record the 503's `Retry-After`/edge signature. Expected: no `Retry-After` +
  immediate 503 ⇒ confirms the persistent edge rejection; a `Retry-After` or a
  200 ⇒ revises toward transient.
- **Otherwise, hold and monitor** SideStore #1745 / LiveContainer #1744 for the
  community's fix (which client-info the GSA edge now accepts), then adapt the
  preset once — rather than guessing against a moving Apple-side target.

Both Keychain profiles remain intact. PR #63 / #64 draft; production unchanged.
