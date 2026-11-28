# GrandSlam -22410 — offline compatibility assessment (2026-11-24)

`-22410` reproduced twice; attempt 2 (enhanced harness) pinned it to **SRP init,
before the password proof** (`request_count: 2` = lookup + init), with Apple's
own message `This action could not be completed. Try again.` No Apple contact in
this assessment; the existing provisioned profile is untouched.

## Comparison of our SRP init against known working clients

**Request structure (item 1).** apple-auth's init body (`authentication.cpp`)
is `{Header:{Version:"1.0.1"}, Request:{A2k:<SRP A>, o:"init",
ps:["s2k","s2k_fo"], u:<email>, cpd:<client_data>}}`, over
`.../grandslam/GsService2`. This matches the documented working clients
(pyicloud / omnisette / SideStore): same `o`, `ps`, `A2k`, version, and `cpd`
block. Account identifier `u` is the email verbatim (no normalization). **No
formatting divergence** — and we call apple-auth's own construction, so our
transport cannot change it. (Confidence this is *not* the cause: HIGH.)

**iPhone client-info (item 2).** Preset `<iPhone15,2> <iPhone OS;17.4;21E219>
<com.apple.AuthKit/1 (com.apple.akd/1.0)>`. The triplet is internally plausible
(iPhone 14 Pro, iOS 17.4 = build 21E219, akd). **But** it is paired with the
**Mac** ADI algorithm (next point), and for a Mac-algorithm profile apple-auth
sets `X-Apple-I-MD-LU` to `base64(device_id)` rather than a SHA-256 hash — an
iPhone-labelled environment carrying Mac-style identity material.

**Provisioned identity vs auth identity (item 3).** The *same* client/profile
generates anisette for both provisioning and sign-in, so there is **no
intra-session mismatch** between the provisioned ADI identity and the identity
presented at auth. Any mismatch is between our synthetic identity and what
Apple's interactive sign-in expects — not between our own two phases.

**apple-auth Mac-algorithm vs known working clients (item 4).**
`provisioning_platform()` maps **iphone → `ProfilePlatform::mac`**: we present
iPhone client-info but run the **Mac** ADI algorithm. Known working free-account
clients obtain anisette from a *genuine* ADI (a real Mac, or an anisette server
running Apple's real ADI), and present a *consistent* environment (SideStore et
al. present as Mac with Mac client-info). apple-auth is a clean-room
reimplementation. Machine **provisioning** parity is proven; interactive
**sign-in** parity is not, and that is exactly the gate that failed.

**Documented association of -22410 (item 5).** Credible public implementations
tie this exact code + message to **anisette state**, in the GrandSlam login:
iloader #1252 / #1285 ("Auth error -22410: This action could not be completed.
Try again."), fixed most often by **resetting anisette** (even without changing
account) or using a **different anisette server**; SideStore #1263's sibling
message is "possible environment mismatch." Not an Apple document, but
consistent community evidence pointing at the anisette/identity environment, not
credentials, formatting or account bans.

## Ranked hypotheses

**H1 — our clean-room Mac anisette/identity is not accepted for interactive
sign-in (environment mismatch). MEDIUM-HIGH.**
Evidence: rejection at init where `cpd` carries the anisette; the exact code +
message are documented as an anisette-state / environment-mismatch error fixed
by resetting anisette or using a working anisette server; our environment is a
hybrid (iPhone client-info + Mac algorithm + base64 `MD-LU`); provisioning is a
weaker gate than interactive sign-in. Sub-causes, not yet separable:
(a) client-info ↔ algorithm inconsistency; (b) clean-room anisette not
bit-compatible with genuine ADI for interactive auth; (c) the particular
provisioned state needs a reset.

**H2 — test-account eligibility/state. MEDIUM-LOW.**
Evidence: a few community reports resolved -22410 by switching accounts; init is
where account eligibility is gated. But the dominant community fix was anisette,
not account, so this is secondary.

**H3 — request formatting / protocol / account-id encoding. LOW.**
Evidence: apple-auth's init matches documented working clients field-for-field
and we use its construction verbatim. Effectively ruled out.

## Minimal experiments that distinguish them

All offline-prepared, each needing explicit per-run authorization; none modifies
the existing working profile (new profiles use a separate Keychain scope).

- **E1 (tests H1c, cheapest live step):** provision a **fresh** anisette
  identity under a *new* scope (the existing one untouched) and sign in once.
  Mirrors the community "reset anisette" fix. Proceeds past init ⇒ stale state;
  still -22410 ⇒ the clean-room anisette is systematically not accepted (H1a/b).
- **E2 (tests H1a):** provision+sign-in as a **consistent Mac identity**
  (`DevicePlatform::mac` → Mac client-info + Mac algorithm + SHA-256 `MD-LU`),
  the pairing genuine Mac clients use. Proceeds ⇒ the iPhone/Mac hybrid was the
  problem; still -22410 ⇒ deeper anisette incompatibility (H1b).
- **E3 (tests H2, no reprovision):** a **different known-good** test account on
  the existing profile. Proceeds ⇒ account-specific; still -22410 ⇒ not the
  account.
- **E4 (decisive for H1b, heaviest — reintroduces an external component for
  diagnosis only):** one controlled comparison signing in with anisette from a
  *genuine* anisette source vs our on-device anisette, same account. Genuine
  passes and ours fails ⇒ the clean-room anisette is the gap. Only if E1-E3 are
  inconclusive and you accept a temporary external anisette purely to diagnose.

**Recommended order: E3 → E1 → E2**, stopping as soon as one proceeds past init.
E3 is the cheapest discriminator (no reprovision) and rules the account in or
out; E1/E2 then localize the anisette/environment cause. No change to the
working ADI provisioning is justified yet — the evidence points at the
*interactive-sign-in acceptance* of our anisette environment, which these
experiments isolate before any code change.
