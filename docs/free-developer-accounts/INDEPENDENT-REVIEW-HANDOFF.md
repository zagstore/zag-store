# Independent review hand-off: G2 (licence) and G4 (security)

Prepared 20 Nov 2026 and refreshed after PR #32 merged. The functional changes are **frozen** at the commits below. Reviewers record their findings in the packages' own decision tables. **Zag Store does not mark G2 or G4 complete.**

## 1. Commits under review

| PR | Branch | Frozen head | What it is |
|---|---|---|---|
| #26 | `claude-isideload-fork` | `4b1a6984` | The `zag-isideload` fork (`AppleAuthCore/zag-isideload`), network feature off |
| #28 | `claude-keychain-signing` | `64de6694` | Keychain signing keys and account lifecycle (L1, L2), certificate request recovery, recovery screens |
| #29 | `claude-isideload-bridge` | `c6ce0750` | The Rust bridge and Swift integration. It contains #26 and #28 through merge commits only. |

**`main`:** `5beb0801`, the merge of the test-only PR #32 (section 6) on top of `e077cf04`.

**History**
- #28 branches from `main` `bcf30a9f`. `main` has since gained only #30's documentation (`e077cf04`) and #32's two test-harness files (`5beb0801`).
- Each frozen head merges into `main` `5beb0801` without conflicts (checked with `git merge-tree`).
- Merge order, if approved after both reviews: #26, then #28, then #29. All three stay draft until then.

**Getting the commits**

```
git clone https://github.com/zagstore/zag-store && cd zag-store
git fetch origin claude-isideload-fork claude-keychain-signing claude-isideload-bridge
git checkout --detach c6ce0750      # contains all three
git merge-base --is-ancestor 4b1a6984 HEAD && git merge-base --is-ancestor 64de6694 HEAD && echo "contains #26 and #28"
```

A branch that has moved past its frozen head is not what was reviewed. Review the hashes above.

The repository is public. The packages at the frozen commit:
- G2: https://github.com/zagstore/zag-store/blob/c6ce0750f13b0ab4899f172dc6c7985dc3154567/docs/free-developer-accounts/G2-LICENCE-REVIEW.md
- G4: https://github.com/zagstore/zag-store/blob/c6ce0750f13b0ab4899f172dc6c7985dc3154567/docs/free-developer-accounts/G4-SECURITY-REVIEW.md
- Signing keys and lifecycle: https://github.com/zagstore/zag-store/blob/c6ce0750f13b0ab4899f172dc6c7985dc3154567/docs/free-developer-accounts/SIGNING-KEY-SECURITY.md
- Fork provenance: https://github.com/zagstore/zag-store/blob/c6ce0750f13b0ab4899f172dc6c7985dc3154567/AppleAuthCore/zag-isideload/PROVENANCE.md

## 2. The packages

Both are at `c6ce0750`:
- **G2:** `docs/free-developer-accounts/G2-LICENCE-REVIEW.md`. It covers provenance, reproducible evidence, MPL-2.0 obligations, dependencies, decisions A–D, an 18-item checklist and a decision record.
  - Supporting files: `AppleAuthCore/zag-isideload/PROVENANCE.md` and `upstream-changes.diff`.
  - Unchanged since 19 Nov: the fork (`4b1a6984`) and its dependencies have not changed.
- **G4:** `docs/free-developer-accounts/G4-SECURITY-REVIEW.md`. It covers network destinations, credential lifecycle, session isolation, logging, TLS, failure handling, feature gates, fail-closed assumptions (§9), questions, a 42-item checklist (§11, sections A–J) and a decision record.
  - Supporting file: `docs/free-developer-accounts/SIGNING-KEY-SECURITY.md`, covering keys, L1/L2, certificate recovery, removal, aliases and Release gating.

## 3. Reproduction commands

Nothing below contacts Apple or an anisette server. Live authentication, the live portal and live anisette are compiled off (`static let isEnabled = false`), and the bridge's `live` feature is built only to check its gate.

**G2 (macOS, Rust and git):**

```
git clone https://github.com/nab138/isideload            u   && git -C u   checkout 326e56229d0790d5d3ac9ec0f8cb1d47f8bc1bc5
git clone https://github.com/SideStore/apple-private-apis apa && git -C apa checkout 03beb1aa4299
git clone https://github.com/Dadoum/Sideloader          sl  && git -C sl  checkout 631abccace36
scripts/zag-g2-reproduce.sh u apa sl     # expects "differs from upstream exactly as recorded"
scripts/test-zag-isideload-fork.sh       # fork checks, including no TLS-disabling switch
```

**G4 (macOS with Xcode 26.5, an iOS 26.5 simulator and Rust):**

```
scripts/test-zag-apple-bridge.sh         # Rust 1/12/4; C header vs exports; Swift 62; gates off
scripts/test-zag-apple-accounts.sh       # 95: accounts, L1, aliases, local state, recovery actions
scripts/test-zag-zsign-branch.sh         # strict signing 86, integration 44 (L2, certificate recovery), DER 3
scripts/test-zag-apple-accounts-ui.sh    # simulator walkthrough: 18 checks, 14 screenshots
```

**Release build, binary scan and package guard:**

```
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release \
  -destination generic/platform=iOS -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO DSTROOT=/tmp/zag-release install
scripts/test-zag-free-account-release-binary.sh /tmp/zag-release/Applications/Feather.app
scripts/build-zag-first-launch-test.sh /tmp/zag-first-launch
scripts/test-zag-package-guard.sh /tmp/zag-release/Applications/Feather.app \
  /tmp/zag-first-launch/dstroot/Applications/Feather.app
```

**Full regression:** run every `scripts/test-zag-*.sh` **one at a time**, never in parallel (they share the simulator and the login Keychain), except:
- `test-zag-package-guard.sh` and `test-zag-free-account-release-binary.sh`, which need the arguments above;
- `test-zag-zsign-real-certificate.sh`, which needs the owner's certificate.

Simulator suites accept `SIMULATOR_ID=<udid>`.

## 4. Results (20 Nov)

**On `main` `5beb0801`, after #32:** clean.
- All 42 suites that exist on `main` pass. The bridge and fork suites exist only on #26 and #29.
- `install-control-taps` passes 8 of 8.
- The Release build succeeds, and the Release scan passes.
- Package guard: 16 pass.
- Canonical IPA: unchanged (`67d1a79b`).

**On the frozen #29 head `c6ce0750`**, run sequentially before #32:
- **Suites:** 43 of 44 pass.
- **Release build:** succeeds. The Release scan passes, including the Apple Accounts gate and entry-placement checks.
- **Package guard:** 16 pass.
- **Canonical IPA:** unchanged (`67d1a79b`).

**The one failure there was `install-control-taps`,** in `testShrinkingPillStaysTappableThenReleasesItsArea`; the other 7 tests passed. It is a test-harness defect, now fixed on `main` (section 6).
- It is outside both reviews' scope: none of #26, #28 or #29 touches the install control or its test.
- The frozen heads still carry the old harness. So that one test can still fail there when a tap lands more than a second after the morph.
- When a reviewer sees that failure at the frozen heads, it is this known defect, not a finding against the reviewed code. Running the suite from `main` `5beb0801` uses the fixed harness.

## 5. Known limitations (for both reviewers)

- **Live behaviour is untested.** Nothing has run against Apple or an anisette server.
- **Unestablished live assumptions** (G4 §9) fail closed:
  - the token expiry unit;
  - the Personal Team's kind;
  - certificate lookup;
  - the request format;
  - the anisette serial;
  - whether Apple's listing includes certificate content. Without it, a lost response always ends as "unresolved" and needs the user;
  - whether aliases share an `adsid`. Unrecorded addresses are refused.
- **Correlation:** per-account anisette state does not make accounts unlinkable.
  - The device serial, the IP address, any persistent pseudonymous identifier and the provider itself can correlate accounts.
  - The provider and serial are deferred to G3, after the anisette study ends on 25 Nov and the privacy review.
- **Key exportability:** software RSA keys can be exported by the app's own process. iOS does not enforce non-extractability for them, and the Secure Enclave cannot hold RSA-2048.
- **Residual secrets in memory:** Swift `String` copies of the token and code; the code in an HTTP header inside the fork; the token in the fork's heap while a session exists (G4 question 1).
- **No certificate pinning** (G4 question 2).
- **Release gating:**
  - The recovery screens are Release code, but Settings shows them only when `ZagAppleAccountsFeature.isEnabled`, which is `false`.
  - In the Release binary, Stored Account Data is present.
  - The certificate recovery *view* is removed from the Release build because nothing in Release links to it yet. Enabling the feature needs a Release Apple Accounts screen that links to it.
- **G2 open items:** decisions A–D, including MPL-2.0 coverage of four files and the Sideloader-reference concern. These are the reviewer's to decide.

## 6. The install-button test failure (resolved on `main`; separate from the reviews)

**Root cause:** a test-harness defect, shown with a deterministic reproduction.
- The harness displays elapsed milliseconds with a locale-formatted `Text`, so 1550 ms reads `1,550`.
- The test parses it with `Int(label) ?? -1`. Any tap recorded a second or more after the morph therefore reports `-1` and fails, although the app recorded exactly the right event.
- A touch held across the hit-area shrink is not swallowed; that hypothesis was ruled out.

**Fix:** test-only PR #32 (`d7199fc6`), **merged** into `main` as `5beb0801` with the owner's approval. It changes two files in `scripts/` only.
- The label is shown verbatim, and the test waits for the tap's event before reading it.
- The assertions are unchanged, and a mutant control still fails the test.

**Evidence:** preserved in a comment on #32: https://github.com/zagstore/zag-store/pull/32#issuecomment-7007768207
- the instrumented late-tap reproduction (label `1,516` parses as `nil`; the row opened once);
- the ruled-out press-across-shrink case;
- the fixed test passing a 1499 ms tap;
- the mutant failing;
- the diagnostic diffs.

**Results:** the suite passed 8 of 8 at `d7199fc6` before the merge, and 8 of 8 in the full regression on `main`.

**Production impact found:** none.

**Not investigated further (owner, 20 Nov):** what delayed the tap past one second in the earlier regression. Synthetic CPU load did not reproduce it. It is reopened only if the problem recurs or shows a broader issue.

## 7. For reviewers: what not to do

- Do not enable live services or configure a live backend.
- Do not contact Apple or an anisette server.
- Do not build an experiment IPA.
- Do not use real Apple Account credentials.
- Findings and required changes go in each package's decision table. Changes after review need new commits, and a new review of those commits.
