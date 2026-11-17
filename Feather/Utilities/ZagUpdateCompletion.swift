import Foundation

/// `Restart to Complete...`: ends the running process after a successful
/// handoff, so iOS can finish replacing it.
///
/// `exit(0)` is not a supported iOS lifecycle operation (Apple Technical Q&A
/// QA1561); it is used here with the owner's explicit authorisation for Zag
/// Store's sideloaded distribution and may not be acceptable for other
/// distribution channels. It is a normal process exit, not a crash.
///
/// Termination proves nothing about installation. The pending-installation
/// record written before the transfer stays in place, and the next launch's
/// executable-hash verification alone decides whether the update happened and
/// whether the one-shot `Updated to …` message appears.
enum ZagUpdateCompletion {
    /// The only state in which the process may end: the coordinator reports
    /// verified on-device staging or native completion for this attempt, and
    /// the pending record needed for next-launch verification exists. Staging
    /// (209) follows signing, hashing and the full size-verified transfer.
    static func allowsTermination(actionState: ZagSelfUpdateActionState,
                                  handoff: ZagUpdateHandoffState,
                                  pendingRecorded: Bool) -> Bool {
        actionState == .handedOff && handoff.isSuccessfulHandoff && pendingRecorded
    }

    @MainActor private static var terminating = false

    /// Ends the process at most once, and only when `allowsTermination` holds.
    /// `terminate` is injectable for tests; production exits.
    @MainActor
    @discardableResult
    static func complete(actionState: ZagSelfUpdateActionState,
                         handoff: ZagUpdateHandoffState,
                         pendingRecorded: Bool,
                         terminate: () -> Void = terminateProcess) -> Bool {
        guard !terminating,
              allowsTermination(actionState: actionState, handoff: handoff, pendingRecorded: pendingRecorded)
        else { return false }
        terminating = true
        terminate()
        return true
    }

    /// The pending record and every other preference were written long before
    /// staging; this only makes sure the preferences daemon has them before the
    /// process ends. Nothing is consumed, acknowledged or marked installed.
    static func terminateProcess() {
        UserDefaults.standard.synchronize()
        exit(0)
    }
}
