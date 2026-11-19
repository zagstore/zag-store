#if ZAG_LIVE_EXPERIMENT
import Foundation

/// G5, E1 (plan §5.2): the single choke point in front of the bridge's
/// certificate request. `ZagIsideloadDeveloperPortal.submitCertificateRequest`
/// calls `consume` as its first statement, and nothing else in Zag Store can
/// send a certificate request (scripts/test-zag-g5-experiment.sh, T11).
enum ZagCertificateBudget {
	/// Checks the account pin (C6) and the campaign (C1–C5, C8), reads the team's certificate list
	/// again (it must still be empty), then records the one submission and
	/// the account pin in the registry, read back, before returning. Throws,
	/// and nothing is sent, unless all of that holds.
	static func consume(
		campaign: ZagLiveExperimentCampaign,
		accountKey: String,
		recheckCertificates: () async throws -> Int
	) async throws {
		// C6 first: another account is refused (and halts) as such, whatever
		// the budget's state.
		try campaign.checkAccount(accountKey)
		try campaign.authorizeSubmission()
		let certificates = try await recheckCertificates()
		try campaign.recordSubmission(accountKey: accountKey, certificatesNow: certificates)
	}
}
#endif
