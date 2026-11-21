#!/usr/bin/env bash
# Operator entry point for native ADI provisioning on Ubuntu.
#
#   --preflight  Offline only: runtime libraries, client metadata, identity,
#                and a native check that an empty state reads NOT_PROVISIONED.
#   --live       Runs the preflight, then one supervised provisioning run that
#                contacts Apple. Requires --authorize-apple-contact.
#
# Identity and metadata are passed as private files (0600), never as values.
# Starts no service and changes no production configuration.
set -euo pipefail
umask 077

usage() {
  cat >&2 <<'EOF'
Usage: native-adi-provision.sh --probe BIN --runtime DIR --state-parent DIR \
         --identity FILE --client-metadata FILE (--preflight | --live --authorize-apple-contact)
EOF
  exit 2
}
probe='' runtime='' parent='' identity='' metadata='' mode='' authorized=0
while (($#)); do
  case "$1" in
    --probe) (($# >= 2)) || usage; probe=$2; shift 2 ;;
    --runtime) (($# >= 2)) || usage; runtime=$2; shift 2 ;;
    --state-parent) (($# >= 2)) || usage; parent=$2; shift 2 ;;
    --identity) (($# >= 2)) || usage; identity=$2; shift 2 ;;
    --client-metadata) (($# >= 2)) || usage; metadata=$2; shift 2 ;;
    --preflight) mode=preflight; shift ;;
    --live) mode=live; shift ;;
    --authorize-apple-contact) authorized=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$probe" && -n "$runtime" && -n "$parent" && -n "$identity" && -n "$metadata" && -n "$mode" ]] || usage
[[ "$mode" != live || $authorized == 1 ]] || {
  echo "BLOCKED: --live contacts Apple and requires --authorize-apple-contact" >&2; exit 2; }
probe=$(realpath -e -- "$probe") runtime=$(realpath -e -- "$runtime") parent=$(realpath -e -- "$parent")
[[ -x "$probe" ]] || { echo "Probe binary is not executable" >&2; exit 1; }
[[ -f "$identity" ]] || { echo "Identity file missing" >&2; exit 1; }
here=$(dirname -- "$(realpath -e -- "$0")")

echo "== runtime libraries"
"$here/prepare-native-adi-runtime.sh" --destination "$runtime" --verify-only
echo "== client metadata"
ZAG_ANISETTE_CLIENT_INFO_FILE=$metadata "$probe" --metadata-readiness
echo "== identity (offline)"
ZAG_ANISETTE_CLIENT_INFO_FILE=$metadata "$probe" --validate-client-identity < "$identity"
echo "== native state queries (offline)"
check=$(mktemp -d "$parent/.zag-adi-offline-check.XXXXXXXX")
trap 'rm -rf -- "$check"' EXIT
# A fixed test identifier: this empty state is discarded immediately.
"$probe" "$runtime" --native-offline-check "$check" 00010203-0405-06 2>/dev/null | grep '^PASS: empty state'
rm -rf -- "$check"; trap - EXIT

if [[ "$mode" == preflight ]]; then
  echo "PREFLIGHT PASS: no Apple contact was made"
  exit 0
fi
state="$parent/adi-state-$(date -u +%Y%m%dT%H%M%SZ)"
echo "== supervised provisioning (contacts Apple) -> $state"
ZAG_ANISETTE_CLIENT_INFO_FILE=$metadata "$probe" --provision-client-supervised "$runtime" "$state" < "$identity"
