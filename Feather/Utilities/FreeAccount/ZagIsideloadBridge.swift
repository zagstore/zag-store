#if ZAG_APPLE_BRIDGE
import CryptoKit
import Foundation
import Security

// G4: Zag Store's Apple Account and developer-portal interfaces, implemented
// by the Rust bridge to the trimmed zag-isideload fork
// (AppleAuthCore/zag-apple-bridge).
//
// Compiled only with ZAG_APPLE_BRIDGE, which no Xcode configuration sets: the
// app's Debug and Release builds contain none of this. The bridge library
// itself reaches the network only when built with its `live` feature, and
// even then only after `ZagIsideloadBridge.configureLive`, which refuses
// unless live authentication, the live portal and live anisette are all
// enabled (they are not). See docs/free-developer-accounts/G4-SECURITY-REVIEW.md.

/// One bridge slot: one account's sign-in and portal session. Swift runs one
/// operation at a time in a slot, until that operation's terminal event has
/// reached Swift. The bridge's cancellation is slot-wide, so this is what keeps
/// cancelling one operation from stopping another started after it.
final class ZagBridgeSlot: @unchecked Sendable {
	let id = zag_bridge_open_slot()
	private let lock = NSLock()
	/// The operation started here whose terminal event has not reached Swift.
	private var running: ZagBridgeEvents?
	/// Calls to `zag_bridge_cancel` under way. The bridge is called without
	/// the lock held, since it may answer on the calling thread. Meanwhile no
	/// operation starts here, so its slot-wide cancellation cannot reach one.
	private var cancelling = 0
	/// How long a cancelled operation may take to send its terminal event
	/// before Swift abandons it.
	let cancellationGrace: TimeInterval
	/// `zag_bridge_cancel`; tests replace it to act as a misbehaving bridge.
	private let cancelBridge: @Sendable (UInt64) -> Int32

	init(cancellationGrace: TimeInterval = 5, cancelBridge: @escaping @Sendable (UInt64) -> Int32 = { zag_bridge_cancel($0) }) {
		self.cancellationGrace = cancellationGrace
		self.cancelBridge = cancelBridge
	}

	deinit {
		zag_bridge_close_slot(id)
		// The bridge still sends the terminal event after closing. Should it
		// never come, the operation is not kept registered past its slot.
		if let running { ZagBridgeOperations.shared.abandon(running) }
	}

	/// Starts one operation; while another runs here, it fails as `busy`
	/// without reaching the bridge.
	func start(_ body: (UnsafeMutableRawPointer, zag_bridge_event_callback) -> Void) -> ZagBridgeEvents {
		let events = ZagBridgeEvents(slot: self)
		let started = lock.withLock {
			guard running == nil, cancelling == 0 else { return false }
			running = events
			return true
		}
		guard started else {
			events.deliver(.failed(.busy))
			return events
		}
		body(ZagBridgeOperations.shared.register(events), ZagBridgeOperations.callback)
		return events
	}

	/// Cancels `operation` while it is the one running here, never another.
	/// Returns whether the cancellation reached the bridge.
	fileprivate func cancel(_ operation: ZagBridgeEvents) -> Bool {
		let reaches = lock.withLock {
			guard running === operation else { return false }
			cancelling += 1
			return true
		}
		guard reaches else { return false }
		_ = cancelBridge(id)
		lock.withLock { cancelling -= 1 }
		return true
	}

	fileprivate func ended(_ operation: ZagBridgeEvents) {
		lock.withLock {
			if running === operation { running = nil }
		}
	}
}

enum ZagBridgeFailure: String, Error, Sendable {
	case disabled, notConfigured, network, rejected, twoFactorRejected, refused, rateLimited
	case sessionExpired, malformed, cancelled, busy, invalidInput, notSignedIn, unsupported
}

enum ZagBridgeEvent: Sendable {
	case codeRequired(ZagTwoFactorChallenge, retry: Bool)
	case signedIn(ZagAuthenticatedSession)
	/// The operation's JSON value.
	case result(Data)
	case failed(ZagBridgeFailure)

	var isTerminal: Bool {
		if case .codeRequired = self { return false }
		return true
	}

	/// Parses one event. Anything unexpected is `failed(.malformed)`.
	static func parse(_ data: Data) -> ZagBridgeEvent {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let event = object["event"] as? String else { return .failed(.malformed) }
		switch event {
		case "codeRequired":
			guard let prompt = object["prompt"] as? [String: Any],
				  let method = prompt["method"] as? String,
				  let length = prompt["codeLength"] as? Int, (4...8).contains(length) else { return .failed(.malformed) }
			let masked = (prompt["maskedDestination"] as? String).map { "•• •• \($0)" }
			let challenge = ZagTwoFactorChallenge(
				method: method == "sms" ? .sms : .trustedDevice, codeLength: length,
				maskedDestination: masked, canRequestSMS: prompt["canRequestSms"] as? Bool ?? false
			)
			return .codeRequired(challenge, retry: prompt["retry"] as? Bool ?? false)
		case "signedIn":
			guard let credential = object["credential"] as? [String: Any],
				  let account = credential["accountIdentifier"] as? String,
				  let token = credential["token"] as? String,
				  let expiry = credential["expiresAt"] as? Double,
				  let teams = object["teams"] as? [[String: Any]] else { return .failed(.malformed) }
			let parsedTeams = teams.compactMap { team -> ZagDeveloperTeam? in
				guard let identifier = team["identifier"] as? String, let name = team["name"] as? String else { return nil }
				let kind = (team["kind"] as? String).flatMap(ZagDeveloperTeam.Kind.init(rawValue:)) ?? .unknown
				return ZagDeveloperTeam(identifier: identifier, name: name, kind: kind)
			}
			guard parsedTeams.count == teams.count else { return .failed(.malformed) }
			return .signedIn(ZagAuthenticatedSession(
				credential: ZagSessionCredential(accountIdentifier: account, token: token, expiresAt: Date(timeIntervalSince1970: expiry)),
				teams: parsedTeams
			))
		case "result":
			guard let value = object["value"],
				  let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return .failed(.malformed) }
			return .result(data)
		case "failed":
			return .failed((object["kind"] as? String).flatMap(ZagBridgeFailure.init(rawValue:)) ?? .malformed)
		default:
			return .failed(.malformed)
		}
	}

	/// Whether the bridge ends the operation with this message (`signedIn`,
	/// `result` or `failed`), whatever else it holds. This, not whether Swift
	/// could read the message, decides when the bridge has finished.
	static func endsOperation(_ data: Data) -> Bool {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			  let event = object["event"] as? String else { return false }
		return ["signedIn", "result", "failed"].contains(event)
	}
}

/// The operations the bridge may still call back, by the token passed to it
/// as `context`. The context is a number, not a pointer to an object, so a
/// message for an operation that has ended or been abandoned, a repeated
/// terminal event, or a stray callback finds nothing and is ignored. It
/// never reaches freed memory. An operation is registered once and removed
/// once: by its terminal event, or when its slot closes first.
final class ZagBridgeOperations: @unchecked Sendable {
	static let shared = ZagBridgeOperations()
	private let lock = NSLock()
	private var lastToken: UInt = 0
	private var running: [UInt: ZagBridgeEvents] = [:]

	/// Operations still registered (tests).
	var count: Int { lock.withLock { running.count } }

	fileprivate func register(_ events: ZagBridgeEvents) -> UnsafeMutableRawPointer {
		lock.withLock {
			lastToken += 1
			running[lastToken] = events
			return UnsafeMutableRawPointer(bitPattern: lastToken)!
		}
	}

	/// Gives up an operation whose terminal event did not come: its readers
	/// get `cancelled` (once; nothing if it has already ended) and its slot is
	/// freed. Anything the bridge sends for it later is ignored.
	fileprivate func abandon(_ events: ZagBridgeEvents) {
		lock.withLock { running = running.filter { $0.value !== events } }
		events.abandoned()
	}

	fileprivate func receive(_ context: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ length: Int) {
		var data = bytes.map { Data(bytes: $0, count: length) }
		defer {
			// The copy of the message (a session token, perhaps) is wiped.
			let count = data?.count ?? 0
			data?.resetBytes(in: 0..<count)
		}
		let ends = data.map(ZagBridgeEvent.endsOperation) ?? false
		let token = UInt(bitPattern: context)
		let events = lock.withLock { ends ? running.removeValue(forKey: token) : running[token] }
		events?.received(data.map(ZagBridgeEvent.parse) ?? .failed(.malformed), ends: ends)
	}

	static let callback: zag_bridge_event_callback = { context, bytes, length in
		ZagBridgeOperations.shared.receive(context, bytes, length)
	}
}

/// One operation's events, in order, delivered from the bridge thread.
final class ZagBridgeEvents: @unchecked Sendable {
	private typealias Waiter = CheckedContinuation<ZagBridgeEvent?, Never>
	private let lock = NSLock()
	private var buffer: [ZagBridgeEvent] = []
	private var finished = false
	private var waiters: [Waiter] = []
	private weak var slot: ZagBridgeSlot?

	fileprivate init(slot: ZagBridgeSlot) {
		self.slot = slot
	}

	/// Passes one event on; nothing after the first terminal one.
	fileprivate func deliver(_ event: ZagBridgeEvent) {
		let (first, others): (Waiter?, [Waiter]) = lock.withLock {
			guard !finished else { return (nil, []) }
			finished = event.isTerminal
			guard !waiters.isEmpty else {
				buffer.append(event)
				return (nil, [])
			}
			let first = waiters.removeFirst()
			guard finished else { return (first, []) }
			defer { waiters = [] }
			return (first, waiters)
		}
		first?.resume(returning: event)
		// Readers still waiting after the terminal event get nil.
		others.forEach { $0.resume(returning: nil) }
	}

	/// A message from the bridge; `ends` when the bridge finishes the
	/// operation with it. One Swift cannot use while the bridge carries on is
	/// passed on as `malformed`, and the operation is cancelled.
	fileprivate func received(_ event: ZagBridgeEvent, ends: Bool) {
		// Free the slot first, so the reader can start its next operation.
		if ends { slot?.ended(self) }
		deliver(event)
		if !ends && event.isTerminal { cancel() }
	}

	/// The next event, or nil after the terminal one. Several readers are
	/// served in turn; none is left waiting.
	func next() async -> ZagBridgeEvent? {
		await withCheckedContinuation { continuation in
			let ready: ZagBridgeEvent?? = lock.withLock {
				if !buffer.isEmpty { return .some(buffer.removeFirst()) }
				if finished { return .some(nil) }
				waiters.append(continuation)
				return nil
			}
			if let ready { continuation.resume(returning: ready) }
		}
	}

	fileprivate func abandoned() {
		slot?.ended(self)
		deliver(.failed(.cancelled))
	}

	/// Cancels this operation in the bridge if it is still running there.
	/// One that has already ended keeps its outcome (a certificate issued just
	/// before cancelling is reported as issued). The bridge answers with the
	/// terminal event; should it not within the slot's grace period, Swift
	/// abandons the operation, so no caller waits for it forever. (The bridge
	/// then refuses a new operation in the slot as busy while the old one
	/// still runs there.)
	func cancel() {
		guard let slot, slot.cancel(self) else { return }
		let grace = slot.cancellationGrace
		Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
			if let self { ZagBridgeOperations.shared.abandon(self) }
		}
	}
}

enum ZagIsideloadBridge {
	/// True only when the linked bridge library was built with `live`.
	static var liveCompiled: Bool { zag_bridge_live_compiled() == 1 }

	/// Configures the live backend with the approved anisette server and the
	/// device serial decided with it (G3; there is no default). Refused unless
	/// every live switch is on, which needs the owner's approval of G1–G6;
	/// none is on.
	static func configureLive(anisetteURL: URL, deviceSerial: String) -> Bool {
		guard ZagLiveAuthentication.isEnabled, ZagLivePortal.isEnabled, ZagAnisetteLive.isEnabled, liveCompiled,
			  anisetteURL.scheme == "https" else { return false }
		var storage = ZagBridgeStorage(
			context: nil,
			store: { _, key, value, length in ZagBridgeAnisetteKeychain.store(key, value, length) },
			retrieve: { _, key, value, length in ZagBridgeAnisetteKeychain.retrieve(key, value, length) },
			delete_item: { _, key in ZagBridgeAnisetteKeychain.delete(key) },
			release: { _, value, length in ZagBridgeAnisetteKeychain.release(value, length) }
		)
		return anisetteURL.absoluteString.withCString { url in
			deviceSerial.withCString { serial in zag_bridge_configure_live(url, serial, &storage) }
		} == ZAG_BRIDGE_OK
	}

	#if DEBUG
	/// Tests only: the bridge's scripted backend (a library built with `mock`).
	static func configureMock(_ script: Data) -> Bool {
		script.withUnsafeBytes { zag_bridge_configure_mock($0.bindMemory(to: UInt8.self).baseAddress, $0.count) } == ZAG_BRIDGE_OK
	}
	#endif

	/// The anisette scope of an Apple Account: each account has its own
	/// anisette device state (owner decision, 19 Nov), named by a hash of the
	/// address entered, never the address. The same address in any case gets
	/// the same scope, so later sign-ins and portal sessions reuse it.
	static func anisetteScope(forAppleID appleID: String) -> String {
		let normalised = appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return "a" + SHA256.hash(data: Data(normalised.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
	}

	/// Matches the bridge's own check (`valid_anisette_scope`).
	static func isValidAnisetteScope(_ scope: String) -> Bool {
		(1...64).contains(scope.count) && scope.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
	}

	static func signIn(slot: ZagBridgeSlot, appleID: String, password: ZagEphemeralSecret) throws -> ZagBridgeEvents {
		let email = Array(appleID.utf8)
		let scope = anisetteScope(forAppleID: appleID)
		return try password.withBytes { secret in
			slot.start { context, callback in
				scope.withCString { scope in
					zag_bridge_sign_in(slot.id, scope, email, email.count, secret.bindMemory(to: UInt8.self).baseAddress, secret.count, context, callback)
				}
			}
		}
	}

	static func portal(slot: ZagBridgeSlot, credential: ZagSessionCredential, request: [String: Any]) async -> ZagBridgeEvent {
		guard var credentialJSON = try? JSONSerialization.data(withJSONObject: [
			"accountIdentifier": credential.accountIdentifier,
			"token": credential.token,
			"expiresAt": UInt64(max(0, credential.expiresAt.timeIntervalSince1970)),
		]), let requestJSON = try? JSONSerialization.data(withJSONObject: request) else { return .failed(.invalidInput) }
		defer { credentialJSON.resetBytes(in: 0..<credentialJSON.count) }
		let events = credentialJSON.withUnsafeBytes { credentialBytes in
			requestJSON.withUnsafeBytes { requestBytes in
				slot.start { context, callback in
					zag_bridge_portal(
						slot.id,
						credentialBytes.bindMemory(to: UInt8.self).baseAddress, credentialBytes.count,
						requestBytes.bindMemory(to: UInt8.self).baseAddress, requestBytes.count,
						context, callback
					)
				}
			}
		}
		return await withTaskCancellationHandler {
			await events.next() ?? .failed(.cancelled)
		} onCancel: {
			events.cancel()
		}
	}
}

// MARK: - Authentication

/// One account's sign-in through the bridge. Give each authenticator its own
/// instance (`ZagAccountDirectory.Configuration.makeService`), so each
/// account has its own slot.
///
/// The `anisette` parameters are unused: the bridge obtains anisette data
/// itself from the configured provider. `ZagBridgeAnisetteSource` keeps the
/// directory's anisette step as a gate.
actor ZagIsideloadAuthenticationService: ZagAppleAuthenticationService {
	private let slot = ZagBridgeSlot()
	private var events: ZagBridgeEvents?
	/// A call is waiting for the sign-in's next event. The actor is reentrant
	/// there, so a second call arriving meanwhile is refused rather than
	/// answering, cancelling or reading the first one's sign-in.
	private var reading = false

	private func ensureIdle() throws {
		if reading { throw ZagAuthenticationServiceError.malformedResponse }
	}

	func signIn(appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep {
		try ensureIdle()
		if let earlier = events {
			// The authenticator abandoned an earlier sign-in waiting for a code.
			earlier.cancel()
			while await next() != nil {}
		}
		events = try ZagIsideloadBridge.signIn(slot: slot, appleID: appleID, password: password)
		return try await step(afterCode: false)
	}

	func requestCode(by method: ZagTwoFactorMethod, anisette: ZagAnisetteData) async throws -> ZagTwoFactorChallenge {
		try ensureIdle()
		guard method == .sms, events != nil else { throw ZagAuthenticationServiceError.malformedResponse }
		guard zag_bridge_answer(slot.id, ZAG_BRIDGE_ANSWER_SMS, nil, 0) == ZAG_BRIDGE_OK else { throw ZagAuthenticationServiceError.malformedResponse }
		guard case .twoFactorRequired(let challenge) = try await step(afterCode: false) else { throw ZagAuthenticationServiceError.malformedResponse }
		return challenge
	}

	func submitCode(_ code: String, challenge: ZagTwoFactorChallenge, appleID: String, password: ZagEphemeralSecret, anisette: ZagAnisetteData) async throws -> ZagSignInStep {
		try ensureIdle()
		guard events != nil else { throw ZagAuthenticationServiceError.twoFactorRejected }
		var digits = Array(code.utf8)
		let answered = zag_bridge_answer(slot.id, ZAG_BRIDGE_ANSWER_CODE, digits, digits.count)
		// The bridge keeps its own zeroising copy.
		digits.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
		guard answered == ZAG_BRIDGE_OK else { throw ZagAuthenticationServiceError.twoFactorRejected }
		return try await step(afterCode: true)
	}

	func isValid(_ credential: ZagSessionCredential, anisette: ZagAnisetteData) async throws -> Bool {
		switch await ZagIsideloadBridge.portal(slot: slot, credential: credential, request: ["op": "teams"]) {
		case .result: return true
		case .failed(.sessionExpired): return false
		case .failed(let failure): throw Self.error(for: failure)
		default: throw ZagAuthenticationServiceError.malformedResponse
		}
	}

	private func next() async -> ZagBridgeEvent? {
		guard let events else { return nil }
		reading = true
		defer { reading = false }
		let event = await withTaskCancellationHandler {
			await events.next()
		} onCancel: {
			events.cancel()
		}
		if event?.isTerminal != false, self.events === events { self.events = nil }
		return event
	}

	/// After a code, a repeated prompt means the code was not accepted; the
	/// sign-in keeps waiting for the next one.
	private func step(afterCode: Bool) async throws -> ZagSignInStep {
		switch await next() {
		case .codeRequired(let challenge, let retry):
			if afterCode && retry { throw ZagAuthenticationServiceError.twoFactorRejected }
			return .twoFactorRequired(challenge)
		case .signedIn(let session):
			// EXPERIMENT: which team is the Personal Team is not inferred. With
			// several teams of unknown kind, none is chosen: signing on the wrong
			// team (an organisation's) would have side effects there.
			let identified = session.teams.contains { $0.kind != .unknown }
			guard session.teams.count == 1 || identified else { throw ZagAuthenticationServiceError.malformedResponse }
			return .authenticated(session)
		case .failed(let failure):
			throw Self.error(for: failure)
		case .result, nil:
			throw ZagAuthenticationServiceError.malformedResponse
		}
	}

	static func error(for failure: ZagBridgeFailure) -> Error {
		switch failure {
		case .disabled, .notConfigured, .unsupported: ZagAuthenticationServiceError.liveAuthenticationDisabled
		case .network: ZagAuthenticationServiceError.network
		case .rejected: ZagAuthenticationServiceError.invalidCredentials
		case .twoFactorRejected: ZagAuthenticationServiceError.twoFactorRejected
		case .rateLimited: ZagAuthenticationServiceError.rateLimited
		case .cancelled: CancellationError()
		case .refused, .sessionExpired, .malformed, .busy, .invalidInput, .notSignedIn: ZagAuthenticationServiceError.malformedResponse
		}
	}
}

// MARK: - Developer portal

/// One account's developer-portal operations through the bridge, with that
/// account's stored session. Its own slot is bound to the account on first
/// use; another account's credential is refused by the bridge.
struct ZagIsideloadDeveloperPortal: ZagDeveloperPortalService {
	let account: UUID
	let secrets: ZagFreeAccountSecretStore
	private let slot = ZagBridgeSlot()

	init(account: UUID, secrets: ZagFreeAccountSecretStore) {
		self.account = account
		self.secrets = secrets
	}

	private func call<T: Decodable>(_ request: [String: Any], as type: T.Type) async throws -> T {
		let value = try await raw(request)
		guard let decoded = try? JSONDecoder().decode(T.self, from: value) else { throw ZagPortalError.malformedResponse }
		return decoded
	}

	private func raw(_ request: [String: Any]) async throws -> Data {
		guard let data = try? secrets.load(.session, account: account),
			  let credential = try? JSONDecoder().decode(ZagSessionCredential.self, from: data) else { throw ZagPortalError.sessionRejected }
		switch await ZagIsideloadBridge.portal(slot: slot, credential: credential, request: request) {
		case .result(let value):
			return value
		case .failed(let failure):
			throw Self.error(for: failure)
		default:
			throw ZagPortalError.malformedResponse
		}
	}

	static func error(for failure: ZagBridgeFailure) -> Error {
		switch failure {
		case .disabled, .notConfigured, .unsupported: ZagPortalError.livePortalDisabled
		case .sessionExpired, .notSignedIn: ZagPortalError.sessionRejected
		case .network: ZagPortalError.network
		case .rateLimited: ZagPortalError.rateLimited
		case .cancelled: CancellationError()
		// EXPERIMENT: which refusal (a limit, an identifier in use) is not
		// inferred from Apple's messages; the provisioner's own limits come first.
		case .refused, .rejected, .twoFactorRejected, .malformed, .busy, .invalidInput: ZagPortalError.malformedResponse
		}
	}

	private struct Device: Decodable { let udid: String; let name: String }
	private struct AppID: Decodable { let identifier: String; let bundleIdentifier: String; let expiresAt: Double? }
	private struct Group: Decodable { let identifier: String }
	private struct Certificate: Decodable { let serialNumber: String; let name: String; let machineName: String?; let expiresAt: Double; let data: String? }
	private struct Profile: Decodable { let data: String }

	private static func appID(_ id: AppID) -> ZagRegisteredAppID {
		ZagRegisteredAppID(identifier: id.identifier, bundleIdentifier: id.bundleIdentifier, expiresAt: id.expiresAt.map(Date.init(timeIntervalSince1970:)))
	}

	private static func certificate(_ c: Certificate) -> ZagDevelopmentCertificate {
		ZagDevelopmentCertificate(
			serialNumber: c.serialNumber, name: c.name, machineName: c.machineName,
			expiresAt: Date(timeIntervalSince1970: c.expiresAt),
			// Undecodable data counts as absent: the certificate is then not
			// recognised by key, which is the cautious outcome.
			data: c.data.flatMap { Data(base64Encoded: $0) }.flatMap { $0.isEmpty ? nil : $0 }
		)
	}

	func devices(team: String) async throws -> [ZagRegisteredDevice] {
		try await call(["op": "devices", "team": team], as: [Device].self).map { ZagRegisteredDevice(udid: $0.udid, name: $0.name) }
	}

	func registerDevice(udid: String, name: String, team: String) async throws -> ZagRegisteredDevice {
		let device = try await call(["op": "registerDevice", "team": team, "udid": udid, "name": name], as: Device.self)
		return ZagRegisteredDevice(udid: device.udid, name: device.name)
	}

	func appIDs(team: String) async throws -> [ZagRegisteredAppID] {
		try await call(["op": "appIds", "team": team], as: [AppID].self).map(Self.appID)
	}

	func registerAppID(bundleIdentifier: String, name: String, team: String) async throws -> ZagRegisteredAppID {
		Self.appID(try await call(["op": "registerAppId", "team": team, "bundleIdentifier": bundleIdentifier, "name": name], as: AppID.self))
	}

	func appGroups(team: String) async throws -> [ZagRegisteredAppGroup] {
		try await call(["op": "appGroups", "team": team], as: [Group].self).map { ZagRegisteredAppGroup(identifier: $0.identifier) }
	}

	func registerAppGroup(_ identifier: String, team: String) async throws -> ZagRegisteredAppGroup {
		ZagRegisteredAppGroup(identifier: try await call(["op": "registerAppGroup", "team": team, "identifier": identifier], as: Group.self).identifier)
	}

	func assignAppGroups(_ groups: [String], to appID: ZagRegisteredAppID, team: String) async throws {
		_ = try await raw(["op": "assignAppGroups", "team": team, "groups": groups, "appId": appID.identifier])
	}

	func certificates(team: String) async throws -> [ZagDevelopmentCertificate] {
		try await call(["op": "certificates", "team": team], as: [Certificate].self).map(Self.certificate)
	}

	func submitCertificateRequest(_ request: ZagCertificateRequest, team: String) async throws -> ZagIssuedCertificate {
		let issued = try await call([
			"op": "submitCertificateRequest", "team": team,
			"request": request.data.base64EncodedString(), "machineName": "Zag Store",
		], as: Certificate.self)
		guard let encoded = issued.data, let data = Data(base64Encoded: encoded) else { throw ZagPortalError.malformedResponse }
		return ZagIssuedCertificate(certificate: Self.certificate(issued), data: data)
	}

	func profile(for appID: ZagRegisteredAppID, team: String) async throws -> ZagIssuedProfile {
		let profile = try await call(["op": "profile", "team": team, "appId": appID.identifier], as: Profile.self)
		guard let data = Data(base64Encoded: profile.data) else { throw ZagPortalError.malformedResponse }
		return try ZagIssuedProfile(profileData: data)
	}
}

// MARK: - Anisette

extension ZagAnisetteData {
	/// Marks that the bridge obtains anisette data itself; carries no headers.
	init(managedByBridgeAt date: Date) {
		headers = [:]
		obtainedAt = date
	}
}

/// The directory's anisette step for the bridge: the bridge fetches anisette
/// data from its configured provider, so this only gates. It refuses unless
/// live anisette is enabled, or the bridge's test backend is in use.
struct ZagBridgeAnisetteSource: ZagAnisetteSource {
	var allowsTestBackend = false
	func anisetteData() async throws -> ZagAnisetteData {
		#if DEBUG
		if allowsTestBackend { return ZagAnisetteData(managedByBridgeAt: Date()) }
		#endif
		guard ZagAnisetteLive.isEnabled, ZagIsideloadBridge.liveCompiled else { throw ZagAnisetteError.liveProvidersDisabled }
		return ZagAnisetteData(managedByBridgeAt: Date())
	}
}

/// The anisette provider's device state in the this-device-only Keychain,
/// never synchronised. Values are opaque to Zag Store. The bridge names each
/// item `<account's anisette scope>/<key>`, so accounts never share one.
enum ZagBridgeAnisetteKeychain {
	static let service = "ZagStore.anisette.bridge"

	private static func query(_ key: UnsafePointer<CChar>?, service: String) -> [String: Any]? {
		guard let key, let account = String(validatingCString: key), !account.isEmpty, account.count <= 128 else { return nil }
		return [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecAttrSynchronizable as String: false,
		]
	}

	/// Adds the item, or replaces its value in place: a failed write leaves
	/// the previous state, never none (losing it registers a new anisette
	/// device with Apple at the next sign-in).
	static func store(_ key: UnsafePointer<CChar>?, _ value: UnsafePointer<UInt8>?, _ length: Int, service: String = service) -> Int32 {
		guard let item = query(key, service: service), let value else { return 1 }
		let data = Data(bytes: value, count: length)
		let attributes: [String: Any] = [
			kSecValueData as String: data,
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
		]
		let added = SecItemAdd(item.merging(attributes) { $1 } as CFDictionary, nil)
		if added == errSecSuccess { return 0 }
		guard added == errSecDuplicateItem else { return 1 }
		return SecItemUpdate(item as CFDictionary, attributes as CFDictionary) == errSecSuccess ? 0 : 1
	}

	static func retrieve(_ key: UnsafePointer<CChar>?, _ value: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ length: UnsafeMutablePointer<Int>?,
						 service: String = service) -> Int32 {
		guard var item = query(key, service: service), let value, let length else { return 1 }
		item[kSecReturnData as String] = true
		item[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data, !data.isEmpty else { return 1 }
		let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
		data.copyBytes(to: buffer, count: data.count)
		value.pointee = buffer
		length.pointee = data.count
		return 0
	}

	static func delete(_ key: UnsafePointer<CChar>?, service: String = service) -> Int32 {
		guard let item = query(key, service: service) else { return 1 }
		let status = SecItemDelete(item as CFDictionary)
		return status == errSecSuccess || status == errSecItemNotFound ? 0 : 1
	}

	static func release(_ value: UnsafeMutablePointer<UInt8>?, _ length: Int) {
		guard let value else { return }
		value.update(repeating: 0, count: length)
		value.deallocate()
	}
}

/// The anisette state as each account's local state: the directory records an
/// account's scope at sign-in and removes the scope's items with the account.
/// Items are found only under this service; the scope is the part of the item
/// name before the first "/".
struct ZagBridgeAnisetteLocalState: ZagAccountLocalState {
	var service = ZagBridgeAnisetteKeychain.service

	func scope(forAppleID appleID: String) -> String { ZagIsideloadBridge.anisetteScope(forAppleID: appleID) }

	private func names() throws -> [String] {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecMatchLimit as String: kSecMatchLimitAll,
			kSecReturnAttributes as String: true,
		]
		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound { return [] }
		guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw ZagAccountError.storage }
		return items.compactMap { $0[kSecAttrAccount as String] as? String }
	}

	func scopes() throws -> Set<String> {
		Set(try names().compactMap { name in
			name.firstIndex(of: "/").map { String(name[..<$0]) }.flatMap { ZagIsideloadBridge.isValidAnisetteScope($0) ? $0 : nil }
		})
	}

	func remove(scope: String) throws {
		guard ZagIsideloadBridge.isValidAnisetteScope(scope) else { throw ZagAccountError.storage }
		for name in try names() where name.hasPrefix(scope + "/") {
			let status = SecItemDelete([
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: service,
				kSecAttrAccount as String: name,
			] as CFDictionary)
			guard status == errSecSuccess || status == errSecItemNotFound else { throw ZagAccountError.storage }
		}
		guard try !scopes().contains(scope) else { throw ZagAccountError.storage }
	}
}
#endif
