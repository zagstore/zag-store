# Software Update section spacing reference

Measured from the original PNGs supplied on 16 November 2026, before this correction:

| Measurement | Apple Software Update | Zag Store Update |
|---|---:|---:|
| Filename | Screenshot 2026-11-16 at 1.52.32 am.png | Screenshot 2026-11-16 at 2.17.43 am.png |
| Dimensions | 1290 × 2796 px | 1290 × 2796 px |
| First section bottom boundary | Y = 717 px | Y = 828 px |
| Second section top boundary | Y = 765 px | Y = 852 px |
| Background gap | 48 px | 24 px |
| Display scale | 3 px/pt | 3 px/pt |
| Effective visible gap | **16 pt** | **8 pt** |

Coordinates use the top-left image origin and half-open pixel intervals. Apple's
last painted row is 716 and its gap occupies rows 717–764 inclusive. Zag Store's
last painted row is 827 and its gap occupies rows 828–851 inclusive. RGB scans at
X = 400, 645 and 900 agree. These columns pass through flat edges, avoiding rounded
corner anti-aliasing. Apple's gap pixels are RGB (0,0,0); Zag Store's are (28,28,30).

Both originals have the native 1290 × 2796 resolution of the reference 430 × 932
point iPhone display at @3x. The chat previews are scaled; they were not measured.
The PNG's 144-DPI metadata is unrelated to iOS display scale. The screens' different
navigation/presentation top offsets cancel when subtracting the two section edges.
No image rescaling or crop compensation is needed for these two originals.

## Layout audit and correction

`ZagSelfUpdateStatusView` uses an inset-grouped `Form`. Its first section has two
native navigation rows. The next section contains the update card in one native
row. There is no explicit outer padding, header or footer between these sections
in the available-update state shown. The optional pending-installation warning is
absent in that state.

The private `ZagSelfUpdateSectionSpacing` modifier set `listSectionSpacing` to
8 points. The screenshot's 24-pixel gap confirms that this is the complete effective
gap; there is no additional margin to subtract. The card's 18-point stack spacing,
row insets and vertical padding are **inside** its rounded background. They affect
card content, not the measured space between backgrounds.

Change only this private modifier to **16 points**: 16 × 3 = 48 target pixels,
matching Apple. The expected second-card top, with the first section unchanged,
is Y = 876 px (828 + 48), versus the previous Y = 852 px. Section widths, corner
radii, row heights, insets and horizontal alignment are unchanged.

Run `scripts/measure-zag-update-spacing.swift` with the two original PNG paths to
reproduce the scan. The presentation regression test checks this reference against
the source spacing. A new iPhone screenshot is still required to verify the final
rendered gap, link colours, expansion animation and Update Now visibility.

## Collapsed primary-action visibility

The reference Update Now button ends at Y = 1772 px. A conservative bound charges
all 44 points of the new expansion-link touch target as additional height (even
though the previous link already occupied a text line), plus 8 points of added
section gap: 1772 + (44 + 8) × 3 = **1928 px**. This is above the reference screen's
bottom safe-area boundary at 2796 − 34 × 3 = **2694 px**. The scanner reproduces this
check from the blue button pixels; final runtime confirmation is still required.
