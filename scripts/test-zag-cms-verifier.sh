#!/bin/zsh
# Host test for ZagCMSVerifier: builds a synthetic root->intermediate->signer
# chain, signs a CMS SignedData over a profile-like plist with OpenSSL, and
# checks cryptographic verification (valid, tampered, bad-signature, untrusted
# root, malformed, wrong-pin, expired-at-date) plus the REAL Apple profile when
# present. No Apple network, no real identity. Offline.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FA="$ROOT/Feather/Utilities/FreeAccount"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OSSL="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"; [ -x "$OSSL" ] || OSSL="openssl"

cd "$WORK"
mk_ca() { # name subject
  "$OSSL" req -x509 -newkey rsa:2048 -keyout "$1.key" -out "$1.crt" -days 3650 -nodes \
    -subj "/CN=$2" -sha256 -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
}
mk_leaf() { # name subject ca
  "$OSSL" req -newkey rsa:2048 -keyout "$1.key" -out "$1.csr" -nodes -subj "/CN=$2" -sha256 2>/dev/null
  "$OSSL" x509 -req -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -CAcreateserial -days 3650 -sha256 -out "$1.crt" 2>/dev/null
}
mk_subca() { # name subject ca
  "$OSSL" req -newkey rsa:2048 -keyout "$1.key" -out "$1.csr" -nodes -subj "/CN=$2" -sha256 2>/dev/null
  "$OSSL" x509 -req -in "$1.csr" -CA "$3.crt" -CAkey "$3.key" -CAcreateserial -days 3650 -sha256 \
    -extfile <(echo "basicConstraints=critical,CA:TRUE") -out "$1.crt" 2>/dev/null
}

# Trusted synthetic chain.
mk_ca root "Synthetic Test Root"
mk_subca inter "Synthetic Intermediate" root
mk_leaf signer "Synthetic Signer" inter
cat inter.crt root.crt > chain.pem

# A profile-like payload (the verifier only extracts/authenticates eContent).
cat > payload.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>TeamIdentifier</key><array><string>V54K5JYGS4</string></array>
<key>ProvisionedDevices</key><array><string>00009999-000ABCDEF1234567</string></array>
<key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
<key>Entitlements</key><dict><key>application-identifier</key><string>V54K5JYGS4.com.zagstore.test</string></dict>
</dict></plist>
XML

sign_cms() { # out signercrt signerkey certfile payload
  "$OSSL" cms -sign -binary -nodetach -in "$5" -signer "$2" -inkey "$3" -certfile "$4" -md sha256 -outform DER -out "$1"
}
sign_cms cms_valid.der signer.crt signer.key chain.pem payload.xml

# Untrusted: an independent root+signer, pinned later to the trusted synthetic root.
mk_ca orroot "Other Root"
mk_leaf osigner "Other Signer" orroot
sign_cms cms_untrusted.der osigner.crt osigner.key orroot.crt payload.xml

# Tampered payload: flip a byte inside the embedded plist text; signedAttrs digest must break.
python3 -I - cms_valid.der cms_tampered.der <<'PY'
import sys
b=bytearray(open(sys.argv[1],'rb').read())
i=b.find(b"ProvisionedDevices"); assert i>0
b[i]^=0x01
open(sys.argv[2],'wb').write(b)
PY

# Bad signature: flip the last byte (the signature OCTET STRING is last, no unsignedAttrs).
python3 -I - cms_valid.der cms_badsig.der <<'PY'
import sys
b=bytearray(open(sys.argv[1],'rb').read()); b[-1]^=0x01
open(sys.argv[2],'wb').write(b)
PY

head -c 100 /dev/urandom > malformed.bin

SYN_ROOT_SHA=$("$OSSL" x509 -in root.crt -outform DER | shasum -a 256 | awk '{print $1}')
VERIFY_NOW=$(date -u +%s)

# Real Apple profile (optional, read-only, never committed).
REAL="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/75c25062-d464-4a53-b319-388f7b27bb99.mobileprovision"
[ -f "$REAL" ] && cp "$REAL" real_profile.der || true

# Minimal shim for host build (CryptoKit + Security available on macOS).
cp "$ROOT/scripts/ZagCMSVerifierTests.swift" "$WORK/main.swift"
swiftc -O "$FA/ZagSigningKey.swift" "$FA/ZagCMSVerifier.swift" "$WORK/main.swift" -o "$WORK/cmstests" 2>&1 | grep -vi warning | head -20

"$WORK/cmstests" "$WORK" "$SYN_ROOT_SHA" "$VERIFY_NOW"
