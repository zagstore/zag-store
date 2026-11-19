#!/bin/bash
# G2 licence review: reproduces the provenance evidence for the retained
# zag-isideload sources from independently obtained upstream checkouts.
#   zag-g2-reproduce.sh <isideload> <apple-private-apis> <Sideloader>
# Each argument is a checkout (or extracted archive) of:
#   nab138/isideload            326e56229d0790d5d3ac9ec0f8cb1d47f8bc1bc5
#   SideStore/apple-private-apis 03beb1aa4299…
#   Dadoum/Sideloader            631abccace36…
# Prints whether the fork differs from upstream exactly as recorded in
# upstream-changes.diff, then the similarity evidence for each retained file.
# Reads the checkouts as data only; contacts nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 3 ] || { sed -n '2,12p' "$0"; exit 2; }
ISIDELOAD="$1"; APA="$2"; SIDELOADER="$3"
FORK="$ROOT/AppleAuthCore/zag-isideload"
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-g2.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

for pair in "$ISIDELOAD:326e56229d07" "$APA:03beb1aa4299" "$SIDELOADER:631abccace36"; do
	dir=${pair%:*}; want=${pair##*:}
	if git -C "$dir" rev-parse HEAD > /dev/null 2>&1; then
		head=$(git -C "$dir" rev-parse HEAD)
		case "$head" in "$want"*) echo "PASS: $dir is at $want";; *) echo "FAIL: $dir is at $head, not $want"; exit 1;; esac
	else
		echo "NOTE: $dir is not a git checkout; its commit cannot be checked here"
	fi
done

# The crate is in the isideload/ folder of the upstream repository.
UPSTREAM_CRATE="$ISIDELOAD/isideload"
[ -f "$UPSTREAM_CRATE/Cargo.toml" ] || UPSTREAM_CRATE="$ISIDELOAD"
mkdir "$WORK/upstream" "$WORK/zag-isideload"
cp -R "$UPSTREAM_CRATE"/. "$WORK/upstream/"
git -C "$ROOT" ls-files -z AppleAuthCore/zag-isideload | (cd "$ROOT" && xargs -0 tar cf -) | tar xf - -C "$WORK"
cp -R "$WORK/AppleAuthCore/zag-isideload"/. "$WORK/zag-isideload/"
(cd "$WORK" && diff -ru --exclude=Cargo.lock --exclude=target --exclude=tests --exclude='LICENSE*' --exclude='LICENCE*' \
	--exclude=PROVENANCE.md --exclude=README.md --exclude=upstream-changes.diff --exclude=.gitignore upstream zag-isideload > diff.txt || true)
strip() { grep -vE '^(\+\+\+|---) ' "$1" | sed -E 's/^diff -ru .* (upstream\/[^ ]+) (zag-isideload\/[^ ]+)$/diff \1 \2/'; }
if diff -q <(strip "$WORK/diff.txt") <(strip "$FORK/upstream-changes.diff") > /dev/null; then
	echo "PASS: the fork differs from upstream exactly as recorded in upstream-changes.diff"
else
	echo "FAIL: the fork's differences from upstream are not those recorded"; diff <(strip "$FORK/upstream-changes.diff") <(strip "$WORK/diff.txt") | head -20; exit 1
fi

S="$UPSTREAM_CRATE/src"; A="$APA"; D="$SIDELOADER/source"
similarity() { echo "== $1 vs ${2#"$WORK"/}"; python3 -I "$ROOT/scripts/zag_g2_similarity.py" "$S/$1" "$2" | tail -3; }
similarity auth/apple_account.rs "$A/icloud-auth/src/client.rs"
similarity auth/apple_account.rs "$D/server/appleaccount.d"
similarity auth/grandslam.rs "$A/icloud-auth/src/client.rs"
similarity anisette/remote_v3/state.rs "$A/omnisette/src/remote_anisette_v3.rs"
similarity anisette/remote_v3/mod.rs "$A/omnisette/src/remote_anisette_v3.rs"
for file in developer_session app_ids certificates devices app_groups teams; do
	similarity "dev/$file.rs" "$D/server/developersession.d"
done
similarity sideload/bundle.rs "$D/sideload/bundle.d"
similarity sideload/application.rs "$D/sideload/application.d"
