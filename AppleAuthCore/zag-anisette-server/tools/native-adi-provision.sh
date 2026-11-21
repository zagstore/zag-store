#!/usr/bin/env bash
# Operator workflow for native ADI provisioning on Ubuntu (x86_64).
#
#   --discover          classify every client metadata source found
#                       (verified / unverified / unusable) and the sourced
#                       reference candidates; no file is written
#   --prepare-metadata  write the private 0600 metadata file (--client-metadata)
#                       from one explicitly chosen source:
#                         --from-candidate ID | --from-file FILE [--source TEXT] [--apple-verified]
#   --preflight         offline: libraries, metadata, identity, existing states,
#                       native NOT_PROVISIONED check; ends with what blocks --live
#   --live              preflight, then one supervised provisioning run that
#                       contacts Apple; requires --authorize-apple-contact, and
#                       --accept-unverified-metadata unless the metadata is verified
#
# The metadata file is the one the native server serves at /v3/client_info
# (ZAG_ANISETTE_CLIENT_INFO_FILE); provisioning reads the same file.
# Identity and metadata are private files, never values on the command line.
# Starts no service and changes no production configuration.
set -euo pipefail
umask 077

usage() {
  cat >&2 <<'EOF'
Usage: native-adi-provision.sh --probe BIN MODE [options]
  --discover          [--client-metadata FILE] [--identity FILE] [--state-parent DIR] [--metadata-dir DIR]
  --prepare-metadata  --client-metadata OUT (--from-candidate ID | --from-file FILE [--source TEXT] [--apple-verified])
  --preflight         --runtime DIR --state-parent DIR --identity FILE --client-metadata FILE
  --live              (as --preflight) --authorize-apple-contact [--accept-unverified-metadata]
EOF
  exit 2
}
probe='' runtime='' parent='' identity='' metadata='' metadata_dir='' mode='' authorized=0 accept_unverified=0
prepare=()
while (($#)); do
  case "$1" in
    --probe) (($# >= 2)) || usage; probe=$2; shift 2 ;;
    --runtime) (($# >= 2)) || usage; runtime=$2; shift 2 ;;
    --state-parent) (($# >= 2)) || usage; parent=$2; shift 2 ;;
    --identity) (($# >= 2)) || usage; identity=$2; shift 2 ;;
    --client-metadata) (($# >= 2)) || usage; metadata=$2; shift 2 ;;
    --metadata-dir) (($# >= 2)) || usage; metadata_dir=$2; shift 2 ;;
    --from-candidate|--from-file|--source) (($# >= 2)) || usage; prepare+=("$1" "$2"); shift 2 ;;
    --apple-verified) prepare+=("$1"); shift ;;
    --discover|--prepare-metadata|--preflight|--live) [[ -z "$mode" ]] || usage; mode=${1#--}; shift ;;
    --authorize-apple-contact) authorized=1; shift ;;
    --accept-unverified-metadata) accept_unverified=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$probe" && -n "$mode" ]] || usage
probe=$(realpath -e -- "$probe")
[[ -x "$probe" ]] || { echo "Probe binary is not executable" >&2; exit 1; }

if [[ "$mode" == discover ]]; then
  echo "== sourced reference candidates (never verified by Zag Store)"
  "$probe" --metadata-candidates
  sources=()
  [[ -n "$metadata" && -e "$metadata" ]] && sources+=("$metadata")
  [[ -n "${ZAG_ANISETTE_CLIENT_INFO_FILE:-}" && -e "$ZAG_ANISETTE_CLIENT_INFO_FILE" ]] && sources+=("$ZAG_ANISETTE_CLIENT_INFO_FILE")
  [[ -n "$identity" ]] && sources+=("$identity")
  if [[ -n "$metadata_dir" ]]; then
    for f in "$metadata_dir"/*.json; do [[ -e "$f" ]] && sources+=("$f"); done
  fi
  if [[ -n "$parent" ]]; then
    for f in "$parent"/*/client-identity.json; do [[ -e "$f" ]] && sources+=("$f"); done
  fi
  echo "== local sources"
  if ((${#sources[@]} == 0)) || ! "$probe" --metadata-report "${sources[@]}"; then
    echo "BLOCKED: no usable local client metadata. Either supply the pair your native server will serve"
    echo "  (--prepare-metadata --from-file FILE --source TEXT), or explicitly adopt a sourced candidate"
    echo "  (--prepare-metadata --from-candidate ID), which stays unverified until Apple accepts it."
    exit 3
  fi
  exit 0
fi

if [[ "$mode" == prepare-metadata ]]; then
  [[ -n "$metadata" && ${#prepare[@]} -gt 0 ]] || usage
  [[ -d "$(dirname -- "$metadata")" ]] || { echo "Metadata directory missing" >&2; exit 1; }
  "$probe" --metadata-prepare "$metadata" "${prepare[@]}"
  exit 0
fi

[[ -n "$runtime" && -n "$parent" && -n "$identity" && -n "$metadata" ]] || usage
[[ "$mode" != live || $authorized == 1 ]] || {
  echo "BLOCKED: --live contacts Apple and requires --authorize-apple-contact" >&2; exit 2; }
runtime=$(realpath -e -- "$runtime") parent=$(realpath -e -- "$parent")
[[ -f "$identity" ]] || { echo "Identity file missing" >&2; exit 1; }
[[ "$(uname -m)" == x86_64 ]] || { echo "x86_64 host required" >&2; exit 1; }
export ZAG_ANISETTE_CLIENT_INFO_FILE=$metadata

echo "== runtime libraries"
# Regular ELF files, not links; the native check below proves they load.
for name in libstoreservicescore.so libCoreADI.so; do
  lib="$runtime/lib/x86_64/$name"
  [[ -f "$lib" && ! -L "$lib" && "$(head -c 4 -- "$lib" | od -An -c | tr -d ' ')" == '177ELF' ]] || {
    echo "Missing or invalid library: $name" >&2; exit 1; }
  sha256sum -- "$lib"
done
echo "== client metadata (the file /v3/client_info serves)"
readiness=$("$probe" --metadata-readiness) || exit 1
echo "$readiness"
echo "== identity (offline)"
"$probe" --validate-client-identity < "$identity"
echo "== existing provisioned states under the state parent"
states=0
for record in "$parent"/*/client-identity.json; do
  [[ -e "$record" ]] || continue
  states=$((states + 1))
  dir=$(dirname -- "$record")
  if "$probe" --metadata-check-state "$dir" >/dev/null 2>&1; then
    echo "consistent: $dir"
  else
    echo "MISMATCH: $dir was not provisioned with this client metadata; do not serve headers for it with this file"
  fi
done
((states)) || echo "none"
for leftover in "$parent"/.*.incomplete; do
  [[ -e "$leftover" ]] && echo "NOTE: interrupted attempt left $leftover (never provisioned state; inspect and remove)"
done
echo "== native state queries (offline)"
check=$(mktemp -d "$parent/.zag-adi-offline-check.XXXXXXXX")
trap 'rm -rf -- "$check"' EXIT
# A fixed test identifier: this empty state is discarded immediately.
"$probe" "$runtime" --native-offline-check "$check" 00010203-0405-06 2>/dev/null | grep '^PASS: empty state'
rm -rf -- "$check"; trap - EXIT

blockers=()
case "$readiness" in
  *'provenance not recorded'*) blockers+=("metadata has no provenance: re-prepare it with --prepare-metadata --from-file \"$metadata\" --source TEXT") ;;
  *'PASS: private client metadata is readable and well-formed: unverified'*)
    ((accept_unverified)) || blockers+=("metadata is not Apple-verified: a live attempt needs --accept-unverified-metadata (it is an experiment)") ;;
esac
((authorized)) || blockers+=("operator authorization for Apple contact: --live --authorize-apple-contact")

if [[ "$mode" == preflight ]]; then
  echo "PREFLIGHT PASS: no Apple contact was made"
  if ((${#blockers[@]})); then
    echo "Remaining before one live attempt:"
    printf '  - %s\n' "${blockers[@]}"
  fi
  exit 0
fi
for blocker in "${blockers[@]}"; do
  [[ "$blocker" == operator* ]] || { echo "BLOCKED: $blocker" >&2; exit 2; }
done
state="$parent/adi-state-$(date -u +%Y%m%dT%H%M%SZ)"
echo "== supervised provisioning (contacts Apple) -> $state"
flags=()
((accept_unverified)) && flags+=(--accept-unverified-metadata)
"$probe" --provision-client-supervised "$runtime" "$state" "${flags[@]}" < "$identity"
