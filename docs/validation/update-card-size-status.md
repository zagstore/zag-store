# Update card: download size and lifecycle line

## Why the card showed "Download size unavailable"

The card asked the IPA URL for its size with `HEAD`, requiring HTTP 200 and a
`Content-Length`. On 17 Nov 2026 the iPhone (copy A, Beta channel) was showing
production `beta.json` sequence 7, Beta 4, whose `ipaURL`
(`…/releases/download/v1.0.0-beta.4/ZagStore-1.0.0-beta.4.ipa`) returns
**404**: the `v1.0.0-beta.4` release was withdrawn to a draft, and draft assets
are not downloadable. So no size exists to show, and the Update button would
fail at the download too. The lookup itself was correct: the same code returns
the exact size for live assets through GitHub's 301 → 302 redirects (private
test asset 59,528,098 bytes; Beta 3 60,803,467 bytes).

Signed v2 metadata cannot carry the size: validators require the payload's
exact field set (`ZagUpdateMetadataV2.validatePayload`,
`zag-sign-metadata-v2.py`), so adding a field would make every installed copy
reject the manifest. The size comes from HTTP; the download is still verified
against the signed SHA-256.

## Size lookup (`ZagUpdateDownloadSize`)

- `HEAD`, following redirects; 200 with a positive `Content-Length` is the size.
- Otherwise one `GET` with `Range: bytes=0-0`: 206 gives the total after the
  slash in `Content-Range`; a 200 gives `Content-Length`. Only headers are
  read; the task is cancelled before any body is consumed.
- 404 or 410: "Update file unavailable". Network failure, missing length or
  any other status: "Download size unavailable". Nothing is guessed.
- Runs in the card's `.task(id: ipaURL)`, off the main path; 15 s per request;
  a newer release's lookup replaces an older one.
- Formatting: `ByteCountFormatter`, `.file`, as elsewhere in Zag Store.

## Secondary line (`ZagUpdateCardStatus`)

A function of the card control's own `ZagSelfUpdateActionState`, so there is
no second state machine:

| Action state | Line |
|---|---|
| `.idle` | the size (or the missing-size text) |
| `.idle` after a visible failure | `Update failed.` / `Update cancelled.` |
| `.progress` (certificate, download, verify, sign, transfer, handoff) | `Update requested...` |
| `.handedOff` (verified staging 209 or native completion) | `Update successful.` |
| `.awaitingVerification` | `Update not verified.` |

`Update successful.` appears exactly when the control shows the green
`Restart to Complete...` pill (tested for every handoff state). Download,
transfer completion or an unverified callback never produce it.

## Animation (`ZagUpdateCrossfadeText`)

The status line's crossfade under the pill: ease-in fade-out
`ZagUpdateStatusTiming.fadeOut` (0.08 s), unanimated swap while invisible,
ease-out fade-in `fadeIn` (0.13 s), with fade-out arrival tracked by
`ZagAnimationArrival`. Rapid changes coalesce to the newest text; a late
completion never shows an older one (`ZagCrossfadeTextState`). One line,
`.caption`, primary colour as before; the card does not resize. VoiceOver reads
the current text. It is an opacity crossfade only, as the pill's line is under
Reduce Motion.
