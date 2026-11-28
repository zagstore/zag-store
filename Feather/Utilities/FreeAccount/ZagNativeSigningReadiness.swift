import Foundation

// The ordered prerequisites for native on-device signing, each independently
// checkable, so the interface can distinguish AUTHENTICATION, ADI PROVISIONING,
// CERTIFICATE AVAILABILITY and SIGNING READINESS — four distinct states, not one
// "signed in" flag — and always name the single next thing to do with a concrete
// recovery action. Pure and deterministic: the UI supplies the observed facts
// (all read locally, no Apple contact), and this type decides the rest.
//
// The signing stage is NEVER satisfied by authentication alone: `canSign`
// requires a verified device-generated certificate and provisioning assets in
// addition to a session, an on-device ADI profile and the build-level gate.

enum ZagNativeSigningStage: Int, CaseIterable, Sendable {
	case buildSupport
	case authentication
	case adiProvisioning
	case certificate
	case signing

	var title: String {
		switch self {
		case .buildSupport: return "On-device sign-in support"
		case .authentication: return "Apple Account"
		case .adiProvisioning: return "Device provisioning (ADI)"
		case .certificate: return "Signing certificate"
		case .signing: return "Signing readiness"
		}
	}

	var systemImage: String {
		switch self {
		case .buildSupport: return "cpu.fill"
		case .authentication: return "person.crop.circle"
		case .adiProvisioning: return "cpu"
		case .certificate: return "checkmark.seal"
		case .signing: return "signature"
		}
	}
}

/// How a stage reads in the interface. `blocked` is the one actionable stage (the
/// first unmet prerequisite); `pending` stages are waiting on an earlier one.
enum ZagNativeSigningStageStatus: Equatable, Sendable { case done, blocked, pending }

/// The single next action the user can take. Each maps to a concrete UI step.
enum ZagNativeSigningRecovery: Equatable, Sendable {
	case enableLiveBuild
	case signIn
	case confirmADIProvisioning
	case provisionCertificate
	case enableSigningBuild
	case ready

	var actionTitle: String {
		switch self {
		case .enableLiveBuild:       return "Sign-in unavailable in this build"
		case .signIn:                return "Connect Apple Account"
		case .confirmADIProvisioning:return "Set up this device"
		case .provisionCertificate:  return "Provision a certificate"
		case .enableSigningBuild:    return "Signing not enabled in this build"
		case .ready:                 return "Ready to sign"
		}
	}

	var detail: String {
		switch self {
		case .enableLiveBuild:        return "Native Apple Account sign-in is not enabled in this build; it requires the supervised live-test build. Use an imported certificate for now."
		case .signIn:                 return "Sign in with your free Apple Account to begin."
		case .confirmADIProvisioning: return "Register this device with Apple once. You confirm before anything is sent."
		case .provisionCertificate:   return "Request a development certificate for this iPhone's signing key."
		case .enableSigningBuild:     return "This build does not enable native signing execution."
		case .ready:                  return "A certificate and provisioning are in place; apps can be signed on-device."
		}
	}
}

struct ZagNativeSigningReadiness: Equatable, Sendable {
	/// This build actually links and enables on-device live authentication
	/// (the native bridge is live-compiled and live auth is turned on). When
	/// false, no amount of signing in can succeed, so it is the first gate.
	var buildSupportsLiveAuth: Bool
	/// A usable Apple Account session is present.
	var authenticated: Bool
	/// An on-device ADI provisioning profile exists for this machine.
	var adiProvisioned: Bool
	/// A valid device-generated signing identity AND its provisioning assets are
	/// verified — not merely that the user is authenticated.
	var certificateAvailable: Bool
	/// The build-level signing-execution gate is open.
	var signingGateOpen: Bool

	private func isMet(_ stage: ZagNativeSigningStage) -> Bool {
		switch stage {
		case .buildSupport:    return buildSupportsLiveAuth
		case .authentication:  return authenticated
		case .adiProvisioning: return adiProvisioned
		case .certificate:     return certificateAvailable
		case .signing:         return signingGateOpen
		}
	}

	/// The first prerequisite not yet met, in order; nil when all are met.
	var firstMissing: ZagNativeSigningStage? {
		ZagNativeSigningStage.allCases.first { !isMet($0) }
	}

	func status(of stage: ZagNativeSigningStage) -> ZagNativeSigningStageStatus {
		if isMet(stage) { return .done }
		return firstMissing == stage ? .blocked : .pending
	}

	/// Signing is permitted ONLY when every prerequisite is verified — the build
	/// supports live auth, a session, on-device provisioning, a real certificate
	/// + assets, and the build gate. Authentication alone is never sufficient.
	var canSign: Bool {
		buildSupportsLiveAuth && authenticated && adiProvisioned && certificateAvailable && signingGateOpen
	}

	/// The single next action to present.
	var recovery: ZagNativeSigningRecovery {
		switch firstMissing {
		case .buildSupport:    return .enableLiveBuild
		case .authentication:  return .signIn
		case .adiProvisioning: return .confirmADIProvisioning
		case .certificate:     return .provisionCertificate
		case .signing:         return .enableSigningBuild
		case nil:              return .ready
		}
	}
}
