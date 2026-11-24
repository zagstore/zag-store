#!/bin/zsh
# Host tests for the imported-identity bootstrap path. Generates synthetic
# PKCS#12 fixtures (NOT real Apple identities), compiles ZagImportedSigningIdentity
# with a shim that mirrors ZagKeychainSigningKeys.signer exactly, and runs the
# vertical-slice tests. No network, no real identity, no keychain persistence.
set -e
HERE="${0:A:h}"
ROOT="${HERE:h}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixtures"; mkdir -p "$FIX"

gen() { # gen <out> <subj> <pass>
	openssl req -x509 -newkey rsa:2048 -keyout "$FIX/$1.key.pem" -out "$FIX/$1.cert.pem" -days 365 -nodes -subj "$2" >/dev/null 2>&1
	openssl pkcs12 -export -inkey "$FIX/$1.key.pem" -in "$FIX/$1.cert.pem" -out "$FIX/$1.p12" -passout pass:$3 >/dev/null 2>&1
}
# Development-like identity on the target team.
gen id     "/UID=TESTUID001/CN=Apple Development: test@example.com (TESTAPP0001)/OU=V54K5JYGS4/O=Test/C=US" correct-horse
# A different development identity on a different team (for mismatch + team tests).
gen id2    "/UID=TESTUID002/CN=Apple Development: other@example.com (TESTAPP0002)/OU=OTHERTEAM0/O=Test/C=US" pw2
# A non-development certificate.
gen server "/CN=Some Server/OU=V54K5JYGS4/O=Test/C=US" pw3

# Synthetic provisioning profile (bare plist; the parser scans for it in a CMS
# blob too) embedding id's certificate DER. Synthetic UDID, never a real one.
openssl x509 -in "$FIX/id.cert.pem" -outform DER -out "$FIX/id.cert.der" >/dev/null 2>&1
python3 -I - "$FIX/id.cert.der" "$FIX/profile.plist" <<'PY'
import plistlib, sys, datetime
der = open(sys.argv[1], "rb").read()
profile = {
    "TeamIdentifier": ["V54K5JYGS4"],
    "DeveloperCertificates": [der],
    "ProvisionedDevices": ["00009999-000ABCDEF1234567"],
    "ExpirationDate": datetime.datetime(2099, 1, 1),
    "Entitlements": {
        "application-identifier": "V54K5JYGS4.com.zagstore.test",
        "com.apple.developer.team-identifier": "V54K5JYGS4",
        "get-task-allow": True,
        "keychain-access-groups": ["V54K5JYGS4.*"],
    },
}
open(sys.argv[2], "wb").write(plistlib.dumps(profile, fmt=plistlib.FMT_XML))
PY

# CMS-sign that profile with a synthetic chain so the on-device verifier
# (ZagCMSVerifier) has a real signature to authenticate in the preflight test.
osr() { openssl req "$@" >/dev/null 2>&1; }
osx() { openssl x509 "$@" >/dev/null 2>&1; }
osr -x509 -newkey rsa:2048 -keyout "$FIX/proot.key" -out "$FIX/proot.crt" -days 3650 -nodes -subj "/CN=Synthetic Profile Root" -sha256 -addext "basicConstraints=critical,CA:TRUE"
osr -newkey rsa:2048 -keyout "$FIX/psign.key" -out "$FIX/psign.csr" -nodes -subj "/CN=Synthetic Profile Signer" -sha256
osx -req -in "$FIX/psign.csr" -CA "$FIX/proot.crt" -CAkey "$FIX/proot.key" -CAcreateserial -days 3650 -sha256 -out "$FIX/psign.crt"
openssl cms -sign -binary -nodetach -in "$FIX/profile.plist" -signer "$FIX/psign.crt" -inkey "$FIX/psign.key" -certfile "$FIX/proot.crt" -md sha256 -outform DER -out "$FIX/profile_signed.der" >/dev/null 2>&1
# An untrusted-root variant (identical contents, different signer).
osr -x509 -newkey rsa:2048 -keyout "$FIX/uroot.key" -out "$FIX/uroot.crt" -days 3650 -nodes -subj "/CN=Untrusted Root" -sha256 -addext "basicConstraints=critical,CA:TRUE"
osr -newkey rsa:2048 -keyout "$FIX/usign.key" -out "$FIX/usign.csr" -nodes -subj "/CN=Untrusted Signer" -sha256
osx -req -in "$FIX/usign.csr" -CA "$FIX/uroot.crt" -CAkey "$FIX/uroot.key" -CAcreateserial -days 3650 -sha256 -out "$FIX/usign.crt"
openssl cms -sign -binary -nodetach -in "$FIX/profile.plist" -signer "$FIX/usign.crt" -inkey "$FIX/usign.key" -certfile "$FIX/uroot.crt" -md sha256 -outform DER -out "$FIX/profile_untrusted.der" >/dev/null 2>&1
printf '%s' "$(openssl x509 -in "$FIX/proot.crt" -outform DER | shasum -a 256 | awk '{print $1}')" > "$FIX/synthetic_root_sha256.txt"

# Shim: an exact copy of ZagKeychainSigningKeys.signer (raw PKCS#1 v1.5 DigestInfo)
# plus the minimal error stub the signing-key file expects.
cat > "$WORK/shim.swift" <<'SWIFT'
import Foundation
import Security
enum ZagAppleAuthError: Error, Equatable { case keychain(OSStatus) }
enum ZagKeychainSigningKeys {
	static func signer(_ key: SecKey) -> (Data) -> Data? {
		{ digestInfo in SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15Raw, digestInfo as CFData, nil) as Data? }
	}
}
SWIFT

cp "$ROOT/scripts/ZagImportedIdentityTests.swift" "$WORK/main.swift"
swiftc -O \
	"$WORK/shim.swift" \
	"$ROOT/Feather/Utilities/FreeAccount/ZagSigningModels.swift" \
	"$ROOT/Feather/Utilities/FreeAccount/ZagSigningKey.swift" \
	"$ROOT/Feather/Utilities/FreeAccount/ZagImportedSigningIdentity.swift" \
	"$ROOT/Feather/Utilities/FreeAccount/ZagMobileProvision.swift" \
	"$ROOT/Feather/Utilities/FreeAccount/ZagImportedIdentityProfileMatch.swift" \
	"$ROOT/Feather/Utilities/FreeAccount/ZagCMSVerifier.swift" \
	"$ROOT/Feather/Utilities/FreeAccount/ZagSigningPreflight.swift" \
	"$WORK/main.swift" \
	-o "$WORK/tests" 2>&1 | grep -vi 'warning:' || true

"$WORK/tests" "$FIX"
