# Software Update header and stable changelog refinement

Reference originals: `Screenshot 2026-11-16 at 9.33.10 am.png` (Apple) and
`Screenshot 2026-11-16 at 9.33.26 am.png` (Zag Store). Both are 1290 × 2796 pixels
at @3x. The chat previews are not used for measurement.

| Download-size glyph bounds | Apple | Zag Store before correction |
|---|---:|---:|
| Scan rectangle, X | 320..<660 | 340..<600 |
| Scan rectangle, Y | 890..<950 | 1020..<1085 |
| Visible glyph Y, inclusive | 900...932 | 1033...1070 |
| Ink height | 33 px | 38 px |
| Ink height at @3x | 11 pt | 12.67 pt |

The scan uses sRGB-decoded pixels with all three colour channels above 180 and
near-neutral colour. `scripts/measure-zag-update-header.swift` reproduces the
bounds from the originals. These are glyph bounds, not font em sizes.

The existing label uses regular `.subheadline` (15pt at the standard Dynamic Type
size). Its measured height ratio is 33/38; 15 × 33/38 ≈ 13pt, matching the native
`.caption` style. The corrected size label uses regular `.caption`, and the channel
uses smaller `.caption2` with secondary system-grey styling. Both scale natively.
The title remains `.headline` and Build remains `.subheadline`.

The old header's `HStack(alignment: .center, spacing: 14)` centred the two-line text
stack inside the 60pt icon height. The correction is structural `.top` alignment;
there are no offsets, new insets or changed icon dimensions. The existing 4pt text
stack spacing and single-line title/build layout remain. The third line reads the
existing selected preference and appears only for `beta`/`nightly`; Stable omits it.

## Expansion cause and correction

The old collapsed state used one `Text(document.preview)` that omitted headings
and combined paragraphs/list items. Expansion replaced it with a differently
formatted `VStack` and reintroduced a release title above the intro. `withAnimation`
then interpolated these incompatible layouts; measurement updates added another
opportunity for layout changes.

The corrected inline document omits only an exact duplicate release-identity
heading already represented by the card header. Other headings and release-note
content remain in order. The first attributed block stays mounted at one stable
position and width in both states. Its native line limit changes between four and
unlimited; later blocks appear below it. There is no preview/full-view swap.

Expansion and measurement updates use nonanimated transactions, and text blocks
opt out of interpolation. This intentionally chooses an immediate, stable layout
update over a decorative transition. There is no clipping mask, fixed text height,
opacity workaround, delay or nested scroll view. Full-content measurement and the
four-native-line fitting threshold remain in place, including short-note behavior.

The 16pt section gap, icon, button, Learn More action and more/less styling are
unchanged. iPhone confirmation remains necessary for optical header matching and
repeated expansion/collapse at normal and accessibility text sizes.
