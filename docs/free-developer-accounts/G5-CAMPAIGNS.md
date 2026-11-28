# G5 campaign ledger

The administrative record of G5 live-experiment campaigns
(`G5-EXPERIMENT-BUILD-PLAN.md` §5.2, E6). `scripts/zag-g5-build-check.sh`
reads it: it builds only a campaign whose row is `authorised`, whose window
has not passed, and whose number is greater than every `built`, `running` or
closed row. It cannot constrain an IPA that has already been built; the
binary enforces that itself (§5.5).

A campaign is never reused. Each one needs the owner's written authorisation,
naming a new dedicated account by its label only, never its address. The
owner adds and edits the authorisation rows; the build check updates the
build columns.

## Campaigns

No campaign is authorised. The experiment branch builds only with the
placeholder constants, which can never arm.

| ID | Number | Authorisation (quoted) | notBefore (UTC) | notAfter (UTC) | Account label | Provider | Serial policy | Branch SHA | Build nonce | IPA SHA-256 | State |
|----|--------|------------------------|-----------------|----------------|---------------|----------|---------------|------------|-------------|-------------|-------|

## Column rules

- **ID and number:** `G5-C<n>` and `<n>`, sequential from 1.
- **Window:** ISO 8601 UTC, `notAfter` at most 7 days after `notBefore`.
- **Account label:** a letter (`A`, `B`, …), never the account's address.
- **Provider:** either `native` (Option B: the on-device ADI engine,
  ZagAppleAuthMachine — no remote anisette server and no external dependency),
  or the G3 anisette provider's `https` URL (the bridge path). **Serial
  policy:** for a `native` provider, `native` (the on-device ADI identity is
  the device; no external serial). For an `https` provider, `g3Fixed`, with
  the serial given to the build check privately, never here. (`g3PerAccount`
  is refused: the bridge supports one fixed serial.) A `native` campaign does
  not configure the bridge; it gates ZagAppleAuthMachine sign-in through the
  same `ZagLiveExperiment.campaign.authorize(.signIn)` arming check.
- **State:** `authorised`, `built`, `running`, or `closed: <class>`, where
  the class is the report's verdict, or `INCOMPLETE: durability not proven`.
