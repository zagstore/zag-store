/// Transfer Activity to the central router only after Account actually dismisses.
/// Multiple taps collapse into one request; closing Account alone does nothing.
struct ZagAccountActivityHandoff {
    private var requested = false

    mutating func request() { requested = true }

    mutating func takeAfterDismissal() -> ZagStoreRoute? {
        defer { requested = false }
        return requested ? .activity : nil
    }
}
