// Standalone unit test for the pure ZagNativeSigningReadiness model.
// Compiled with swiftc against the model source only (no app deps), so it runs
// fast and off the device. Asserts the ordered-prerequisite logic, the
// first-missing/recovery mapping, and — critically — that signing is never
// permitted by authentication alone.

import Foundation

private var failures = 0
private func check(_ cond: Bool, _ what: String) {
	if cond { print("  ok: \(what)") } else { print("  FAIL: \(what)"); failures += 1 }
}

@main enum ReadinessTestMain {
static func main() {
	// 1. Nothing done, and the build does not support live auth: that is the
	//    first gate (the real AppTesters build), recovery explains the build.
	let none = ZagNativeSigningReadiness(buildSupportsLiveAuth: false, authenticated: false, adiProvisioned: false,
										 certificateAvailable: false, signingGateOpen: false)
	check(none.firstMissing == .buildSupport, "no build support → first missing is buildSupport")
	check(none.recovery == .enableLiveBuild, "no build support → recovery explains the build, not a dead sign-in")
	check(none.canSign == false, "no build support → cannot sign")
	check(none.status(of: .buildSupport) == .blocked, "buildSupport is the one actionable stage")
	check(none.status(of: .authentication) == .pending, "authentication waits (pending) behind build support")
	check(none.status(of: .signing) == .pending, "signing waits (pending)")

	// 1b. Build supports live auth but nothing else: sign-in is the next step.
	let buildOnly = ZagNativeSigningReadiness(buildSupportsLiveAuth: true, authenticated: false, adiProvisioned: false,
											  certificateAvailable: false, signingGateOpen: false)
	check(buildOnly.firstMissing == .authentication, "build-supported, unauthenticated → first missing is authentication")
	check(buildOnly.recovery == .signIn, "build-supported, unauthenticated → recovery is signIn")
	check(buildOnly.status(of: .buildSupport) == .done, "buildSupport done when the build supports live auth")
	check(buildOnly.canSign == false, "build-supported but unauthenticated → cannot sign")

	// 2. Authenticated only: provisioning is next.
	let auth = ZagNativeSigningReadiness(buildSupportsLiveAuth: true, authenticated: true, adiProvisioned: false,
										 certificateAvailable: false, signingGateOpen: false)
	check(auth.firstMissing == .adiProvisioning, "authenticated → first missing is ADI provisioning")
	check(auth.recovery == .confirmADIProvisioning, "authenticated → recovery is confirm ADI")
	check(auth.status(of: .authentication) == .done, "authentication done once authenticated")
	check(auth.canSign == false, "authenticated alone → cannot sign")

	// 3. Authenticated + provisioned: certificate is next.
	let prov = ZagNativeSigningReadiness(buildSupportsLiveAuth: true, authenticated: true, adiProvisioned: true,
										 certificateAvailable: false, signingGateOpen: false)
	check(prov.firstMissing == .certificate, "auth+adi → first missing is certificate")
	check(prov.recovery == .provisionCertificate, "auth+adi → recovery is provision certificate")
	check(prov.canSign == false, "auth+adi without certificate → cannot sign")

	// 4. The critical guard: authenticated + gate OPEN but NO certificate must
	//    NOT permit signing (signing is never enabled by authentication alone).
	let authGateNoCert = ZagNativeSigningReadiness(buildSupportsLiveAuth: true, authenticated: true, adiProvisioned: true,
												   certificateAvailable: false, signingGateOpen: true)
	check(authGateNoCert.canSign == false, "gate open + authenticated but no certificate → still cannot sign")
	check(authGateNoCert.firstMissing == .certificate, "missing certificate is surfaced even with the gate open")

	// 5. Certificate present but build gate closed: the gate is the blocker.
	let gateClosed = ZagNativeSigningReadiness(buildSupportsLiveAuth: true, authenticated: true, adiProvisioned: true,
											   certificateAvailable: true, signingGateOpen: false)
	check(gateClosed.firstMissing == .signing, "certificate present, gate closed → signing stage is the blocker")
	check(gateClosed.recovery == .enableSigningBuild, "gate closed → recovery names the build gate")
	check(gateClosed.canSign == false, "gate closed → cannot sign")

	// 6. Everything verified: ready.
	let ready = ZagNativeSigningReadiness(buildSupportsLiveAuth: true, authenticated: true, adiProvisioned: true,
										  certificateAvailable: true, signingGateOpen: true)
	check(ready.firstMissing == nil, "all met → nothing missing")
	check(ready.recovery == .ready, "all met → ready")
	check(ready.canSign, "all met → can sign")
	check(ZagNativeSigningStage.allCases.allSatisfy { ready.status(of: $0) == .done }, "all stages done when ready")

	if failures == 0 { print("SUCCESS: ZagNativeSigningReadiness checks passed") }
	else { print("FAILED: \(failures) readiness check(s)"); exit(1) }
}

}
