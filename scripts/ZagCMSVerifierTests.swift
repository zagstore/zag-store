import Foundation

// Host checks for ZagCMSVerifier. Fixtures (built by test-zag-cms-verifier.sh)
// live in argv[1]; argv[2] is the synthetic root's SHA-256 (hex), argv[3] the
// verify date (epoch seconds) inside the synthetic certs' validity.
// Compiled as main.swift alongside ZagDER + ZagCMSVerifier.

let dir = CommandLine.arguments[1]
let syntheticRoot = CommandLine.arguments[2]
let verifyNow = Date(timeIntervalSince1970: TimeInterval(CommandLine.arguments[3]) ?? 0)
var failures = 0
func data(_ name: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)"))) ?? Data() }
func check(_ cond: Bool, _ label: String) { print((cond ? "PASS" : "FAIL") + ": " + label); if !cond { failures += 1 } }

let trusted: Set<String> = [syntheticRoot]

// 1. valid synthetic CMS + trusted chain -> authenticated payload.
switch ZagCMSVerifier.verify(data("cms_valid.der"), trustedRootSHA256: trusted, now: verifyNow) {
case .success(let payload):
	check(true, "valid CMS + trusted chain verifies")
	check(String(data: payload, encoding: .utf8)?.contains("ProvisionedDevices") == true, "valid CMS returns the authentic payload bytes")
case .failure(let f):
	check(false, "valid CMS + trusted chain verifies (got \(f))")
}

// 2. tampered payload -> digest mismatch (signedAttrs bind the content).
check(ZagCMSVerifier.verify(data("cms_tampered.der"), trustedRootSHA256: trusted, now: verifyNow) == .failure(.digestMismatch),
	  "tampered payload rejected (digest mismatch)")

// 3. corrupted signature bytes -> bad signature.
check(ZagCMSVerifier.verify(data("cms_badsig.der"), trustedRootSHA256: trusted, now: verifyNow) == .failure(.badSignature),
	  "invalid signature rejected")

// 4. signed by a DIFFERENT (untrusted) root, pinned to the synthetic root -> no trusted anchor.
check(ZagCMSVerifier.verify(data("cms_untrusted.der"), trustedRootSHA256: trusted, now: verifyNow) == .failure(.noTrustedAnchor),
	  "untrusted signer chain rejected (no pinned anchor)")

// 5. malformed CMS bytes -> not SignedData / malformed.
let malformed = ZagCMSVerifier.verify(data("malformed.bin"), trustedRootSHA256: trusted, now: verifyNow)
check(malformed == .failure(.notSignedData) || malformed == .failure(.malformedCMS), "malformed CMS rejected")

// 6. valid CMS but pinned to the WRONG fingerprint -> no trusted anchor.
check(ZagCMSVerifier.verify(data("cms_valid.der"), trustedRootSHA256: ["00"+String(syntheticRoot.dropFirst(2))], now: verifyNow) == .failure(.noTrustedAnchor),
	  "wrong pinned anchor rejected")

// 7. valid chain but verify date far past cert validity -> untrusted chain (expiry enforced).
check(ZagCMSVerifier.verify(data("cms_valid.der"), trustedRootSHA256: trusted, now: Date(timeIntervalSince1970: 7_000_000_000)) == .failure(.untrustedChain),
	  "expired-at-verify-date chain rejected")

// 8. REAL Apple profile (if present) -> verifies against the pinned Apple Root CA,
//    and the end-to-end preflight is NOT reachable without this crypto success.
let realProfile = data("real_profile.der")
if !realProfile.isEmpty {
	switch ZagCMSVerifier.verify(realProfile) {   // default pin = Apple Root CA
	case .success(let payload):
		check(true, "REAL Apple profile verifies against pinned Apple Root CA")
		check(String(data: payload, encoding: .utf8)?.contains("ProvisionedDevices") == true, "REAL profile authentic payload parsed")
	case .failure(let f):
		check(false, "REAL Apple profile verifies against pinned Apple Root CA (got \(f))")
	}
	// Tampering one byte of the real file must also fail closed.
	var corrupted = realProfile
	corrupted[corrupted.count / 2] ^= 0x01
	check({ if case .failure = ZagCMSVerifier.verify(corrupted) { return true }; return false }(),
		  "REAL profile with a flipped byte fails closed")
} else {
	print("SKIP: real Apple profile fixture not present")
}

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
