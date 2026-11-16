import Foundation

/// How often native Gate4 percentages may invalidate views that observe the
/// whole pairing core. The exact value is always stored and published to
/// dedicated subscribers; only whole-object invalidation is coarsened.
enum ZagGate4PublicationPolicy {
	/// Within one percentage phase: every ten points, and always at 100.
	static func invalidatesViews(fromPercent previous: Int, toPercent next: Int) -> Bool {
		next == 100 || previous / 10 != next / 10
	}
}
