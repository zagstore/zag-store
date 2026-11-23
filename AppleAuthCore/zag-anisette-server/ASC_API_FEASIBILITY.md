# App Store Connect API provisioning in Zag Store's BYOC architecture

**Technical feasibility assessment. Nothing here is implemented, and nothing
should be until the owner decides.** This is the follow-up promised in
`WINDOWS_NATIVE_BACKEND.md` ("App Store Connect API — the officially
supported alternative"). It assumes that document's licensing assessment,
which is preliminary and pending counsel.

## What ASC API would and would not change

Zag Store's current free-account signing (`docs/free-developer-accounts/`,
`Feather/Utilities/FreeAccount/`) works like SideStore:
- the user brings their own Apple Account (BYOC);
- the app signs in to GrandSlam (SRP-6a) and calls the portal at
  `developerservices2.apple.com/services/QH65B2/` to list teams, register a
  device, submit a development CSR, add an App ID and download a team
  provisioning profile;
- **every one of those calls carries anisette headers**, which is the only
  reason the anisette server (and this whole CoreADI effort) exists;
- a free team's profiles last 7 days, so the flow re-runs on a refresh.

The **App Store Connect API** is a different road to the same provisioning
resources:
- host `api.appstoreconnect.apple.com`, REST + JSON;
- authenticated by a **JWT (ES256)** signed with an API-key private key
  (`.p8`), not by an Apple-Account password and **not with anisette**;
- endpoints `/v1/bundleIds`, `/v1/certificates`, `/v1/devices`,
  `/v1/profiles`;
- governed by the **Apple Developer Program License Agreement**, so it needs
  no reverse engineering and no Apple DLL.

**Consequences for integration:**
- It would slot in as a **new, parallel `ZagSigningMethod`**, independent of
  the GrandSlam/anisette path. It does not modify or depend on the anisette
  server, CoreADI, the device VPN or `minimuxer`.
- It **cannot** reuse the free-account sign-in: ASC API acts on **paid**
  Apple Developer Program accounts only.
- It therefore **does not replace** free-account anisette authentication; it
  is a second product aimed at paid-account users. The free path, if it is
  ever cleared, stays the only option for free Apple IDs.

**Feasibility, at a glance:** the ASC API integration itself is
*low-to-moderate technical risk* (ordinary REST + JWT + CSR handling, no
emulation, no private endpoints). The hard parts are not technical — they
are the credential-custody model and the paid-account requirement.

## The three credential models

The question that decides the whole design is *whose developer identity signs
the app, and who holds the private material.* Three models, with their
permissions, security requirements and limitations.

### Model 1 — Developer-owned API credentials (operator's own one account)

Zag Store holds **one** paid Developer Program account and one ASC API key,
and signs every user's app under the operator's team.

- **Permissions:** the operator's key, with an Admin or App Manager role, can
  create bundle IDs, certificates, devices and profiles for the operator's
  team. No per-user Apple Account is needed.
- **Security requirements:**
  - The ASC API `.p8` private key and the signing-certificate private keys
    are the crown jewels: anyone holding them can sign code as the operator.
    They must live in an HSM or a sealed secret store, never on a device, with
    short-lived JWTs (Apple caps token lifetime at 20 minutes), rotation and
    audit.
  - A single compromise forges signed apps for the entire user base.
- **Limitations:**
  - Apple's per-team caps are shared across all users: **100 registered
    devices per device type per membership year**, and limited certificate
    counts. This does not scale to a public user base.
  - Distributing an operator-signed build to arbitrary third parties is Ad
    Hoc (≤100 devices) or Enterprise in-house distribution; the **Developer
    Enterprise Program forbids distribution outside the organisation**.
    This model most likely breaches the ADP/DEP terms for a public service —
    a question for counsel, not a technical one.
  - **Verdict:** usable only for a closed, small group (e.g. the operator's
    own devices or a test cohort), not for multi-user.

### Model 2 — User-owned developer accounts (each user's own paid account)

Each user supplies their **own** paid Developer Program account and their own
ASC API key; Zag Store provisions within that user's team. This is the
closest ASC analogue to today's BYOC.

- **Permissions:** each user's key provisions only within their own team and
  against their own device/certificate caps. The operator never signs as
  itself.
- **Security requirements:**
  - The per-user `.p8` key, issuer ID and key ID are sensitive per-user
    secrets. Best is for the key **never to leave the user's device** and for
    signing/JWT minting to happen locally; if any server involvement is
    unavoidable, per-user isolation, encryption at rest, scoping and instant
    revocation are mandatory.
  - Blast radius is one user per key, not the whole base.
- **Limitations:**
  - Requires every user to **buy a $99/year membership** and generate an API
    key — high friction, and a different audience from free-account users.
  - **Serves no free accounts at all.**
  - **Verdict:** the cleanest licence and security fit (each user acts under
    their own ADP agreement), but a paid-only, higher-friction product.

### Model 3 — Operator-managed signing identities (operator as custodian)

The operator centrally holds and manages signing identities — either its own
team at scale, or each user's credentials held on the user's behalf.

- **Permissions:** whatever the held identities grant. If under the
  operator's team, this is Model 1 at scale; if holding users' keys, it is
  Model 2 centralised.
- **Security requirements:**
  - The operator becomes the custodian of signing private keys and/or API
    keys for many tenants: the **highest blast radius of the three**. A
    breach forges signed apps across tenants.
  - Requires HSM-backed storage, strict per-tenant isolation, short-lived
    derived material, key rotation, full audit, and a clear deletion and
    revocation story.
- **Limitations:**
  - Central custody is the largest security and compliance liability and the
    biggest operational burden.
  - Acting as an agent that signs/distributes under **others'** developer
    identities raises ADP questions (agency, redistribution) that need
    counsel.
  - Still **cannot do free accounts.**
  - **Verdict:** highest risk; justified only if a product genuinely needs
    managed signing and the legal and HSM groundwork is in place.

### Summary

| Model | Who holds keys | Scales to many users | Free accounts | Main risk |
| --- | --- | --- | --- | --- |
| 1 Developer-owned | Operator (1 account) | No (device/cert caps; ADP/DEP distribution limits) | No | Licence breach for public use; single-point key compromise |
| 2 User-owned | Each user (ideally on-device) | Yes, but paid + high friction | No | Per-user secret handling |
| 3 Operator-managed | Operator (many tenants) | Yes | No | Custodial blast radius; agency/ADP questions |

## Cross-cutting limitations of any ASC API path

- **Paid-only.** Every model needs paid Developer Program membership; none
  reaches free Apple IDs, so none replaces the current free-account design.
- **Caps.** 100 devices per device type per membership year; limited
  certificate counts; API rate limits.
- **Not anisette.** ASC API is a separate auth world (JWT key), so it neither
  benefits from nor fixes the anisette/CoreADI licensing problem — it
  sidesteps it by not using those components at all.

## Recommended next step (no implementation)

If the owner wants a path that is operable today, **Model 2** (user-owned
paid accounts, keys kept on-device) is the strongest candidate: it fits the
existing BYOC shape, keeps each user within their own licence, and has the
smallest security surface. It would be a **new paid-account signing method
alongside** the free-account path, not a replacement.

Before any code: decide the target model, confirm the ADP terms for that
model with counsel (Model 1 and 3 especially), and specify where key material
lives. Only then scope an implementation.
