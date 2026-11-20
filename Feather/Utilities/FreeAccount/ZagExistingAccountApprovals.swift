#if ZAG_EXISTING_ACCOUNT_EXPERIMENT
import Foundation

/// G5 existing-account path (issue #37): the owner's approval of each
/// Apple-side change, and the journal of what was sent.
///
/// - Only the mutations the latest accepted preflight requires can be
///   approved, each one separately, for the pinned account and team.
/// - Each approved mutation can be sent once per campaign. `consume` records
///   it as sent (written and read back) before the bridge sends anything;
///   a failed write refuses. Nothing is ever sent again for it, whatever the
///   outcome: there are no retries.
/// - App groups, revocation and deletion have no approval and are never sent.
/// - The journal is a Keychain item (this device only), so it survives a
///   reinstall like the campaign registry.
final class ZagExistingAccountApprovals: @unchecked Sendable {
	enum Refusal: Error, Equatable, Sendable {
		case noPreflight, notRequired, notApproved, alreadySent, wrongAccount, journalWriteFailed
	}

	enum Sent: String, Codable, Sendable {
		/// Recorded before sending; the outcome is not known yet.
		case sentUnconfirmed, succeeded, failed
	}

	struct Journal: Codable, Equatable, Sendable {
		var campaignID: String
		var accountKey: String?
		var team: String?
		var required: [ZagExistingAccountMutation] = []
		var approved: [ZagExistingAccountMutation] = []
		var sent: [ZagExistingAccountMutation: Sent] = [:]
	}

	static let service = "ZagStore.live-test.existing-approvals"
	let campaignID: String
	private let store: ZagCampaignRegistryStore
	private let lock = NSLock()

	init(campaignID: String, store: ZagCampaignRegistryStore = ZagKeychainCampaignRegistryStore(service: ZagExistingAccountApprovals.service)) {
		self.campaignID = campaignID
		self.store = store
	}

	/// The journal of this campaign; a journal of another campaign is ignored.
	var journal: Journal? { lock.withLock { try? loadLocked() } }

	private func loadLocked() throws -> Journal {
		guard let data = try store.read() else { return Journal(campaignID: campaignID) }
		guard let journal = try? JSONDecoder().decode(Journal.self, from: data) else { throw Refusal.journalWriteFailed }
		return journal.campaignID == campaignID ? journal : Journal(campaignID: campaignID)
	}

	private func saveLocked(_ journal: Journal) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		guard let data = try? encoder.encode(journal) else { throw Refusal.journalWriteFailed }
		do {
			try store.write(data)
			guard try store.read() == data else { throw Refusal.journalWriteFailed }
		} catch {
			throw Refusal.journalWriteFailed
		}
	}

	/// After an accepted preflight: the mutations that may be approved. A later
	/// preflight replaces the set but never forgets what was sent; approvals
	/// not in the new set are withdrawn.
	func recordPreflight(accountKey: String, team: String, required: Set<ZagExistingAccountMutation>) throws {
		try lock.withLock {
			var journal = try loadLocked()
			if let pinned = journal.accountKey, pinned != accountKey || journal.team != team { throw Refusal.wrongAccount }
			journal.accountKey = accountKey
			journal.team = team
			journal.required = required.sorted()
			journal.approved = journal.approved.filter(required.contains)
			try saveLocked(journal)
		}
	}

	/// The owner's approval of one mutation, for the preflight's account.
	func approve(_ mutation: ZagExistingAccountMutation, accountKey: String, team: String) throws {
		try lock.withLock {
			var journal = try loadLocked()
			guard journal.accountKey != nil else { throw Refusal.noPreflight }
			guard journal.accountKey == accountKey, journal.team == team else { throw Refusal.wrongAccount }
			guard journal.required.contains(mutation) else { throw Refusal.notRequired }
			guard journal.sent[mutation] == nil else { throw Refusal.alreadySent }
			if !journal.approved.contains(mutation) { journal.approved = (journal.approved + [mutation]).sorted() }
			try saveLocked(journal)
		}
	}

	/// Whether `mutation` could be consumed now (nothing is recorded).
	func check(_ mutation: ZagExistingAccountMutation, accountKey: String, team: String) throws {
		try lock.withLock { _ = try checkLocked(mutation, accountKey: accountKey, team: team) }
	}

	private func checkLocked(_ mutation: ZagExistingAccountMutation, accountKey: String, team: String) throws -> Journal {
		let journal = try loadLocked()
		guard journal.accountKey != nil else { throw Refusal.noPreflight }
		guard journal.accountKey == accountKey, journal.team == team else { throw Refusal.wrongAccount }
		guard journal.sent[mutation] == nil else { throw Refusal.alreadySent }
		guard journal.approved.contains(mutation) else { throw Refusal.notApproved }
		return journal
	}

	/// Records `mutation` as sent before it is sent. Throws, and nothing may
	/// be sent, unless it is approved, unsent and the record is read back.
	func consume(_ mutation: ZagExistingAccountMutation, accountKey: String, team: String) throws {
		try lock.withLock {
			var journal = try checkLocked(mutation, accountKey: accountKey, team: team)
			journal.sent[mutation] = .sentUnconfirmed
			try saveLocked(journal)
		}
	}

	/// The outcome of a consumed mutation. It stays consumed either way.
	func settle(_ mutation: ZagExistingAccountMutation, succeeded: Bool) {
		lock.withLock {
			guard var journal = try? loadLocked(), journal.sent[mutation] == .sentUnconfirmed else { return }
			journal.sent[mutation] = succeeded ? .succeeded : .failed
			try? saveLocked(journal)
		}
	}
}
#endif
