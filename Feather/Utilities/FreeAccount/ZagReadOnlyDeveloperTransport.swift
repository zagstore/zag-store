import Foundation

// Fail the build loudly rather than silently degrade: a read-only-live
// experiment MUST have the real native auth module linked. Without this, a build
// with the flag but without ZagAppleAuth would quietly compile the live path out
// (canImport false) and fall back to the disabled portal — defeating the
// experiment. With it, a successful build PROVES the live read-only path and the
// real developerHeaders() implementation are compiled in.
#if ZAG_CERT_REPLACEMENT_READONLY_LIVE && !canImport(ZagAppleAuth)
#error("ZAG_CERT_REPLACEMENT_READONLY_LIVE requires the ZagAppleAuth module to be linked (add ZagAppleAuth.xcframework to the Feather target). See scripts/zag-build-readonly-cert-inventory.sh.")
#endif

// A hard read-only boundary for the developer-services portal, BELOW the UI and
// consent layers. It inspects every outgoing request and lets through only the
// read-only developer-services endpoints; any mutating endpoint (a QH65B2
// mutating action, or a /services/v1/ request whose method override is not GET —
// e.g. the DELETE revoke) is refused before a single byte reaches the network,
// regardless of what the UI or the consent coordinator allowed. This is the
// mechanism that makes a "read-only inventory only" live session safe: the
// capability is removed at the transport, not merely hidden in the UI.

/// The live mode of the certificate-replacement experiment. The first live
/// session is READ-ONLY: only the certificate inventory may run; revocation and
/// CSR submission are blocked at the transport boundary (ZagReadOnlyTransport).
enum ZagCertReplacementLiveMode: Equatable, Sendable { case disabled, readOnlyInventory }

enum ZagCertReplacementExperiment {
	static var mode: ZagCertReplacementLiveMode {
		#if ZAG_CERT_REPLACEMENT_READONLY_LIVE
		return .readOnlyInventory
		#else
		return .disabled
		#endif
	}
}

enum ZagReadOnlyEndpointPolicy {
	enum Decision: Equatable, Sendable {
		case allowReadOnly
		case blockMutating(String)   // a short, non-sensitive reason
	}

	/// Classifies a request by URL path and method override only (never the body
	/// or any token). Fail-closed: anything not positively recognised as a
	/// read-only developer-services endpoint is blocked.
	static func classify(_ request: ZagHTTPRequest) -> Decision {
		let path = request.url.path   // no query, no host

		// QH65B2 plist actions: ".../services/QH65B2/<action.rawValue>".
		if let range = path.range(of: "/services/QH65B2/") {
			let actionPart = String(path[range.upperBound...])
			guard let action = ZagDeveloperServicesAction(rawValue: actionPart) else {
				return .blockMutating("unknown QH65B2 action")
			}
			return action.isMutating ? .blockMutating("QH65B2 \(actionPart)") : .allowReadOnly
		}

		// /services/v1/ JSON API: a read is POST + X-HTTP-Method-Override: GET;
		// every other override (DELETE revoke, POST, PATCH, PUT) is a mutation.
		if path.contains("/services/v1/") {
			let override = request.headers.first(where: { $0.key.caseInsensitiveCompare("X-HTTP-Method-Override") == .orderedSame })?.value
			if let override, override.caseInsensitiveCompare("GET") == .orderedSame { return .allowReadOnly }
			return .blockMutating("v1 override \(override ?? request.method)")
		}

		return .blockMutating("unrecognised endpoint")
	}

	static func isReadOnly(_ request: ZagHTTPRequest) -> Bool {
		if case .allowReadOnly = classify(request) { return true }
		return false
	}
}

/// Wraps a base transport and enforces `ZagReadOnlyEndpointPolicy`. A blocked
/// request NEVER reaches the base transport; it throws immediately. Used to
/// compose a read-only developer-services portal for a first live session.
struct ZagReadOnlyTransport: ZagHTTPTransport {
	let base: ZagHTTPTransport

	func send(_ request: ZagHTTPRequest) async throws -> ZagHTTPResponse {
		switch ZagReadOnlyEndpointPolicy.classify(request) {
		case .allowReadOnly:
			return try await base.send(request)
		case .blockMutating(let reason):
			throw ZagTransportError.readOnlyBlocked(reason)
		}
	}
}
