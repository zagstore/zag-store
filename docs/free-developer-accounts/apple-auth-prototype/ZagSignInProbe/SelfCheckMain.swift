import Foundation

// Offline self-check executable. On a plain launch (no environment variables)
// it runs the whole sign-in path with the transport refused, so it validates
// the harness wiring end to end — fresh anisette from the provisioned profile,
// then signInExperiment(allowNetwork: false) — and makes NO Apple contact.
// Expected outcome: transport-failed, with anisette headers present.

@main
struct ZagSignInSelfCheck {
	static func main() async {
		let report = await ZagSignInExperimentRunner.run(live: false)
		ZagSignInExperimentRunner.emit(report, name: "zag_signin_selfcheck.json")
		exit(0)
	}
}
