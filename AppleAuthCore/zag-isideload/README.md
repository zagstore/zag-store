# zag-isideload

This is Zag Store's trimmed fork of [`nab138/isideload`](https://github.com/nab138/isideload), pinned at commit `326e56229d07` (0.5.2). It keeps only Apple Account sign-in, the developer portal and the anisette client.

**Status: evaluation only.**
- Zag Store does not build or use this crate.
- Every request is refused unless the `live-network` cargo feature is enabled. That feature is off by default and needs the owner's separate approval.
- The licence review is preliminary and has not been completed independently.

`PROVENANCE.md` lists every change, the licence evidence for each file and the questions for the reviewer. `LICENCE-INVENTORY.tsv` lists the dependencies. `upstream-changes.diff` is the complete diff from upstream.

Licences:
- upstream code: MIT (`LICENSE-isideload-MIT`);
- files marked as possibly derived from `SideStore/apple-private-apis`: MPL-2.0 (`LICENSE-MPL-2.0`);
- Zag Store's additions: MIT.
