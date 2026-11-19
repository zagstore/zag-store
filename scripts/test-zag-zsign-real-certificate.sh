#!/bin/bash
# Positive signing with a real certificate, without moving the Zsign
# submodule: signs copies of a built Zag Store (1) with the pinned Zsign's
# ordinary path, (2) with the branch's ordinary path, and (3) with the
# branch's strict per-component path through a non-extractable keychain key.
# Each result is checked independently (code page hashes, special slots,
# CDHashes, sealed resources, CMS signature and chain to Apple Root CA with
# OpenSSL, entitlements, embedded profile, every resource) and certificate
# import's revocation check is compared between pinned and branch.
#
# Inputs (nothing personal is stored in this script):
#   ZAG_REAL_APP            unsigned built Feather.app
#   ZAG_REAL_PROFILE        the certificate's .mobileprovision
#   ZAG_REAL_P12            the certificate's .p12
#   ZAG_REAL_PASSWORD_FILE  a file with a "Password: …" line (never printed)
#   ZAG_REAL_BUNDLE_ID      the profile's bundle ID
#   ZAG_REAL_BUILD          optional: CFBundleVersion to stamp, as the packager does
#   ZAG_REAL_OUT            optional: folder for the signed test IPAs
#   ZAG_ZSIGN_BRANCH        default zag-free-account-signing
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${ZAG_ZSIGN_BRANCH:-zag-free-account-signing}"
for v in ZAG_REAL_APP ZAG_REAL_PROFILE ZAG_REAL_P12 ZAG_REAL_PASSWORD_FILE ZAG_REAL_BUNDLE_ID; do
	[ -n "${!v:-}" ] || { echo "SKIP: $v is not set" >&2; exit 3; }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp/}zag-zsign-real.XXXXXX")
[ -n "${ZAG_REAL_KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT
SSL="${ZAG_OPENSSL_PREFIX:-$(brew --prefix openssl@3 2>/dev/null || true)}"
TARGET="$(uname -m)-apple-macos$(sw_vers -productVersion | cut -d. -f1)"
password() { sed -n 's/^Password:[[:space:]]*//p' "$ZAG_REAL_PASSWORD_FILE" | head -1 | tr -d '\r'; }

echo "Zsign pinned at $(git -C "$ROOT" ls-tree HEAD Zsign | awk '{print $3}' | cut -c1-7); branch $BRANCH at $(git -C "$ROOT/Zsign" rev-parse --short "$BRANCH")"
mkdir -p "$WORK/branch"
git -C "$ROOT/Zsign" archive "$BRANCH" | tar -x -C "$WORK/branch"
# The pinned commit is exported too: the submodule's working tree may be on
# another commit while the branch is being worked on.
PINNED=$(git -C "$ROOT" ls-tree HEAD Zsign | awk '{print $3}')
mkdir -p "$WORK/pinned"
git -C "$ROOT/Zsign" archive "$PINNED" | tar -x -C "$WORK/pinned"
ZAG_ZSIGN_SRC="$WORK/pinned/src" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/pinnedlib" >/dev/null
ZAG_ZSIGN_SRC="$WORK/branch/src" bash "$ROOT/scripts/zag-build-zsign-macos.sh" "$WORK/branchlib" >/dev/null
swiftc -parse-as-library -target "$TARGET" -I "$WORK/pinnedlib/include" "$WORK/pinned/Sources/zsign.swift" "$ROOT/scripts/ZagRealCertificateSigning.swift" \
	-Xlinker "$WORK/pinnedlib/libzsign.a" -lc++ -framework Security -o "$WORK/pinned-tool" 2>&1 | grep -E 'error' || true
swiftc -parse-as-library -D ZAG_STRICT -target "$TARGET" -I "$WORK/branchlib/include" "$WORK/branch/Sources/zsign.swift" "$ROOT/scripts/ZagRealCertificateSigning.swift" \
	-Xlinker "$WORK/branchlib/libzsign.a" -lc++ -framework Security -o "$WORK/branch-tool" 2>&1 | grep -E 'error' || true
[ -x "$WORK/pinned-tool" ] && [ -x "$WORK/branch-tool" ] || { echo "FAIL: the signing tools did not build" >&2; exit 1; }

# The same preparation as ZagStore-Package.zsh: bundle ID, no ZagTunnel.
prepare() {
	mkdir -p "$WORK/$1/Payload"
	ditto "$ZAG_REAL_APP" "$WORK/$1/Payload/Feather.app"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ZAG_REAL_BUNDLE_ID" "$WORK/$1/Payload/Feather.app/Info.plist"
	[ -z "${ZAG_REAL_BUILD:-}" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ZAG_REAL_BUILD" "$WORK/$1/Payload/Feather.app/Info.plist"
	rm -rf "$WORK/$1/Payload/Feather.app/PlugIns/ZagTunnel.appex"
	rmdir "$WORK/$1/Payload/Feather.app/PlugIns" 2>/dev/null || true
	xattr -cr "$WORK/$1/Payload/Feather.app"
	echo "$WORK/$1/Payload/Feather.app"
}

security cms -D -i "$ZAG_REAL_PROFILE" > "$WORK/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/profile-entitlements.plist"
TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")

security find-certificate -a -c "Apple Root CA" -p /System/Library/Keychains/SystemRootCertificates.keychain > "$WORK/apple-roots.pem"
python3 -I -c 'import plistlib,sys,hashlib; p=plistlib.load(open(sys.argv[1],"rb")); print("\n".join(hashlib.sha256(c).hexdigest() for c in p["DeveloperCertificates"]))' "$WORK/profile.plist" > "$WORK/profile-certificates"

# macOS codesign is not used as the judge: on this Mac it rejects Zsign's
# output, the pinned production Zsign's included (OSStatus -67061), although
# every element below verifies. Its answer is recorded, and the iPhone, which
# enforces signatures at install and launch, is the final check.
verify() {
	local name="$1" app="$2" sig="$WORK/${1// /-}-signature"
	python3 -I "$ROOT/scripts/zag_signature_check.py" "$app" "$TEAM" "$sig" | sed "s/^/$name: /" || { echo "FAIL: $name: signature structure"; return 1; }
	local cms leaf chain
	for cms in "$sig"/*.cms; do
		leaf="${cms%.cms}.leaf"
		"$SSL/bin/openssl" cms -verify -inform DER -in "$cms" -binary -content "${cms%.cms}.cd0" -CAfile "$WORK/apple-roots.pem" -purpose any -ignore_critical \
			-signer "$leaf" -out /dev/null 2>"$cms.err" || { echo "FAIL: $name: $(cat "${cms%.cms}.name"): CMS signature or chain to Apple Root CA rejected: $(head -1 "$cms.err")"; return 1; }
		grep -qx "$("$SSL/bin/openssl" x509 -in "$leaf" -outform DER | shasum -a 256 | cut -d' ' -f1)" "$WORK/profile-certificates" \
			|| { echo "FAIL: $name: $(cat "${cms%.cms}.name") is signed by a certificate the profile does not list"; return 1; }
	done
	chain=$("$SSL/bin/openssl" cms -cmsout -print -inform DER -in "$sig/0.cms" 2>/dev/null | sed -n 's/^ *subject: .*CN *= *\([^,]*\).*/\1/p' | paste -sd '>' -)
	python3 -I -c 'import plistlib,sys; a,b=(plistlib.load(open(p,"rb")) for p in sys.argv[1:3]); sys.exit(0 if a==b else 1)' \
		"$sig/0.entitlements" "$WORK/profile-entitlements.plist" || { echo "FAIL: $name: signed entitlements differ from the profile's"; return 1; }
	cmp -s "$app/embedded.mobileprovision" "$ZAG_REAL_PROFILE" || { echo "FAIL: $name: embedded profile differs"; return 1; }
	# Apart from signatures, the profile and Info.plist (bundle ID), every file
	# is byte-identical to the built app's, and none is missing.
	local changed missing
	changed=$(cd "$app" && find . -type f ! -path '*/_CodeSignature/*' ! -name embedded.mobileprovision ! -path ./Info.plist | while read -r f; do
		if ! cmp -s "$f" "$ZAG_REAL_APP/$f"; then file -b "$f" | grep -q 'Mach-O' || echo "$f"; fi
	done)
	[ -z "$changed" ] || { echo "FAIL: $name: resources changed: $changed"; return 1; }
	missing=$(cd "$ZAG_REAL_APP" && find . -type f ! -path '*/_CodeSignature/*' ! -path './PlugIns/*' | while read -r f; do [ -e "$app/$f" ] || echo "$f"; done)
	[ -z "$missing" ] || { echo "FAIL: $name: files missing: $missing"; return 1; }
	echo "PASS: $name: CMS verified to Apple Root CA ($chain), signer listed in the profile; entitlements, profile and every resource as expected"
	local verdict
	verdict=$(codesign --verify --deep --strict "$app" 2>&1 | head -1 | sed 's|.*: ||')
	echo "INFO: $name: macOS codesign --verify --deep --strict: ${verdict:-valid}"
}

# Zsign writes a .zsign_cache folder in the current directory.
cd "$WORK"
FAILED=0
APP=$(prepare pinned-ordinary)
# The pinned (production) Zsign is the baseline: its result is reported, and
# it does not decide the outcome (see the branch's DER and CMS fixes).
password | "$WORK/pinned-tool" ordinary "$APP" "$ZAG_REAL_PROFILE" "$ZAG_REAL_P12" | sed 's/^/pinned: /' \
	&& verify "pinned ordinary" "$APP" | sed 's/^FAIL:/BASELINE (pinned):/; s/^\(.*\): FAIL:/\1: BASELINE (pinned):/' || true
APP=$(prepare branch-ordinary)
password | "$WORK/branch-tool" ordinary "$APP" "$ZAG_REAL_PROFILE" "$ZAG_REAL_P12" | sed 's/^/branch: /' && verify "branch ordinary" "$APP" || FAILED=1
APP=$(prepare branch-strict)
password | "$WORK/branch-tool" strict "$APP" "$ZAG_REAL_PROFILE" "$ZAG_REAL_P12" "$WORK/throwaway.keychain-db" | sed 's/^/branch: /' \
	&& verify "branch strict (keychain key)" "$APP" || FAILED=1
[ ! -e "$WORK/throwaway.keychain-db" ] || { echo "FAIL: the throwaway keychain was not deleted"; FAILED=1; }

PINNED_CHECK=$(password | "$WORK/pinned-tool" check "$ZAG_REAL_PROFILE" "$ZAG_REAL_P12")
BRANCH_CHECK=$(password | "$WORK/branch-tool" check "$ZAG_REAL_PROFILE" "$ZAG_REAL_P12")
echo "pinned import check: $PINNED_CHECK"
echo "branch import check: $BRANCH_CHECK"
if [ "$PINNED_CHECK" = "$BRANCH_CHECK" ]; then echo "PASS: certificate import answers exactly as the pinned Zsign"; else echo "FAIL: certificate import answers differently"; FAILED=1; fi

if [ "$FAILED" = 0 ] && [ -n "${ZAG_REAL_OUT:-}" ]; then
	mkdir -p "$ZAG_REAL_OUT"
	for kind in branch-ordinary branch-strict; do
		ipa="$ZAG_REAL_OUT/ZagStore-ZSIGN-$(echo "$kind" | tr a-z A-Z)-TEST.ipa"
		rm -f "$ipa"
		(cd "$WORK/$kind" && /usr/bin/zip -qry "$ipa" Payload)
		echo "IPA: $ipa $(shasum -a 256 "$ipa" | cut -c1-16)"
	done
fi
[ "$FAILED" = 0 ] || { echo "FAIL: real-certificate signing" >&2; exit 1; }
echo "SUCCESS: real-certificate signing with Zsign $BRANCH"
