#if ZAG_LIVE_EXPERIMENT
import Foundation

// G5: the one campaign this experiment build may run (plan §3.2, §5.5).
// Written only by scripts/zag-g5-build-check.sh, from the `authorised` row of
// docs/free-developer-accounts/G5-CAMPAIGNS.md, in its own constants commit
// on top of the reviewed experiment commit. Edit it by hand never.
//
// These placeholders authorise nothing, and every check refuses them:
// campaign number 0, an all-zero nonce, a window in 1970 and no anisette
// provider. A build made from them can never arm.
enum ZagLiveExperimentCampaignConstants {
	static let campaignID = "G5-C0"
	static let campaignNumber = 0
	/// The authorised window, seconds since 1970 (UTC).
	static let notBefore: TimeInterval = 0
	static let notAfter: TimeInterval = 0
	/// 16 random bytes from the build check, as 32 lowercase hex characters.
	static let buildNonce = "00000000000000000000000000000000"
	/// The G3 anisette provider (https) and its device-serial decision.
	static let anisetteURL = ""
	static let deviceSerialPolicy = "unset"
	static let deviceSerial = ""
	/// The experiment commit the constants commit sits on (40 hex).
	static let branchSHA = "0000000000000000000000000000000000000000"
	/// SHA-256 of the bridge library and of the Zsign library linked into
	/// this build (64 hex), for the report header.
	static let bridgeLibSHA = "0000000000000000000000000000000000000000000000000000000000000000"
	static let zsignSHA = "0000000000000000000000000000000000000000000000000000000000000000"
	/// G1–G6 as recorded in the ledger row when the build was made.
	static let gates = ["G1": false, "G2": false, "G3": false, "G4": false, "G5": false, "G6": false]
}
#endif
