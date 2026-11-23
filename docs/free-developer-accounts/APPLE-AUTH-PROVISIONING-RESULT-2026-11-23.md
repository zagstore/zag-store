# Supervised apple-auth provisioning — RESULT (2026-11-23)

Owner-authorized, one attempt, on the stock iPhone 15 Pro Max (iOS 27). Executed
exactly the plan in `APPLE-AUTH-PROVISIONING-EXPERIMENT-PLAN.md`. Stopped at
finish per the plan; no sign-in, 2FA, portal, certificate or device registration.

## Outcome: Apple accepted the finish

Sanitized on-device result:

```json
{"library":"0.1.3","platform":"iphone","serial":"absent",
 "requests":3,
 "request_log":["GET gsa.apple.com -> 200 (25619B)",
                "POST gsa.apple.com -> 200 (1109B)",
                "POST gsa.apple.com -> 200 (1460B)"],
 "stage":"finish-provisioning","status":0,
 "provisioned":true,"anisette_headers_available":true}
```

All three machine-provisioning requests returned HTTP 200:

1. `lookup` → 200
2. `midStartProvisioning` → 200 (Apple issued the `spim`)
3. `midFinishProvisioning` → **200 (Apple accepted apple-auth's `cpim`)**

The ADI profile provisioned, and anisette headers (`X-Apple-I-MD` /
`X-Apple-I-MD-M`) are now derivable on-device.

## What this establishes (and what it does not)

**Establishes — a genuine Apple-side success, not an offline test:** Apple's
provisioning service accepts apple-auth's **Mac-algorithm ADI** presented
directly from a stock iPhone, computed in portable C++ with a fresh
machine identity (random `device_id`/`local_user_hash`/`hardware_hash`, serial
absent) — **no Android CoreADI, no Unicorn, no external anisette server, no Mac
or Linux at runtime.** The `midFinishProvisioning` step returned 200 where the
Linux Android-CoreADI runtime returned HTTP 401 / −29003.

**Therefore the −29003 barrier was not fundamental to "an independent ADI."** It
tracked the Android-CoreADI / client-identity class, consistent with the
SideStore report that Mac-backed providers succeed. The hypothesis is now
supported by first-party evidence: swapping to the Mac-algorithm ADI cleared the
finish rejection.

**Does NOT yet establish** full standalone free-account signing. Only machine
provisioning (account-independent) is proven. Still untested and unauthorised:
Apple Account sign-in using these on-device anisette headers (the separate
−80045 class risk), developer-portal operations, certificate issuance, device
registration and the IPA install. Each is a distinct, separately-gated step.

No credential, token, developer-account device slot or certificate was created
or consumed. The provisioned machine profile persists in the app's container.

## Next (no further action without direction)

The standalone, Android-free, server-free, on-device anisette route is now
**viable**, so Phase C (`APPLE-AUTH-IOS-PROTOTYPE-2026-11-23.md` §3) becomes the
implementation plan: integrate apple-auth's core+client behind the existing
`ZagAnisetteProvider.onDevice` kind and feed its headers to the existing
`zag-apple-bridge` / `zag-isideload` sign-in and signing pipeline — which would
be the next thing to prove, under separate authorization, against a test
account. Not started here.

PR #63 remains draft. `main`, production signing, BYOC, AppTesters and Zag
Companion (PR #61) untouched.
