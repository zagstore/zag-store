#if os(iOS) && canImport(ZagAppleAuth) && ZAG_ZSIGN_STRICT
import SwiftUI
import CryptoKit

@MainActor
final class ZagIdentityHandoff: ObservableObject {
    typealias Envelope = ZagIdentityHandoffEnvelope

    enum Failure: LocalizedError {
        case context, responseMissing, conflict, certificate, storage
        var errorDescription: String? {
            switch self {
            case .context: "Activate the original Apple ID, complete installation pairing, and open the Personal Team copy on this iPhone."
            case .responseMissing: "The Mac has not delivered the response yet. Keep this screen open and try again."
            case .conflict: "This account already has a different signing identity or an unresolved certificate request."
            case .certificate: "Apple did not confirm the running certificate for this Personal Team."
            case .storage: "Zag Store could not verify or securely store the identity. Check pairing and your Apple session, then start a new transfer."
            }
        }
    }

    private struct Pending {
        let key: Curve25519.KeyAgreement.PrivateKey
        let bytes: Data
        let token: ZagPersistedDeveloperToken
    }

    private struct Context {
        let token: ZagPersistedDeveloperToken
        let device: ZagPairedDeviceIdentity?
        let udid: String
        let bundle: String
        let team: String
        let signer: Data
        let serial: String
        let certificateExpiry: Date
    }

    private var pending: Pending?
    private var generation = UUID()
    @Published private(set) var code: String?
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    static func file(_ path: String) throws -> URL {
        let directories: [(String, FileManager.SearchPathDirectory)] = [
            ("Documents/", .documentDirectory), ("Library/Caches/", .cachesDirectory),
        ]
        guard let (prefix, directory) = directories.first(where: { path.hasPrefix($0.0) }) else { throw Envelope.Failure.invalid }
        return try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(String(path.dropFirst(prefix.count)))
    }

    static func read(_ path: String, limit: Int) throws -> Data {
        let input = try FileHandle(forReadingFrom: file(path))
        defer { try? input.close() }
        let bytes = try input.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw Envelope.Failure.invalid }
        return bytes
    }

    static func takeBootstrap() -> Envelope.Bootstrap? {
        guard let bundle = Bundle.main.bundleIdentifier, bundle.hasPrefix("app.zagstore.ios."),
              let url = try? file(Envelope.bootstrapPath),
              let data = try? read(Envelope.bootstrapPath, limit: Envelope.maxSize),
              let setup = try? JSONDecoder().decode(Envelope.Bootstrap.self, from: data),
              (try? FileManager.default.removeItem(at: url)) != nil,
              setup.bundle == bundle, (try? setup.validate()) != nil else { return nil }
        return setup
    }

    func cancel() {
        generation = UUID()
        pending = nil
        code = nil
        for path in [Envelope.requestPath, Envelope.responsePath, Envelope.setupRequestPath, Envelope.setupResponsePath] {
            if let url = try? Self.file(path) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func context(bootstrap: Envelope.Bootstrap? = nil) async throws -> Context {
        guard let account = try ZagNativeAppleIDs.shared.catalog().activeID,
              let token = ZagNativeAppleIDs.shared.connectedToken(account),
              let bundle = Bundle.main.bundleIdentifier, let executable = Bundle.main.executableURL,
              let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { throw Failure.context }
        // A trusted desktop bootstrap is scoped to the exact USB installation.
        // It can establish key-import evidence without creating local pairing.
        // Only the paired path may establish renewable installation ownership.
        let device: ZagPairedDeviceIdentity?
        let udid: String
        let checkInventory: ((String?) -> Bool)?
        if let bootstrap, !ZagRPPairingCore.shared.hasSavedPairing {
            try bootstrap.validate()
            guard bootstrap.bundle == bundle,
                  try Envelope.scope(account: token.accountID, team: bootstrap.team) == bootstrap.keyScope
            else { throw Failure.context }
            device = nil
            udid = bootstrap.udid
            checkInventory = nil
        } else {
            let (paired, installed) = try await ZagRPPairingCore.shared.signingDeviceInventory()
            device = paired
            udid = paired.udid
            checkInventory = { signerName in
                guard let app = installed[bundle], let signerName else { return false }
                return app.version == Bundle.main.version
                    && app.build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    && app.signerIdentity == signerName
            }
        }
        let evidence = try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: executable, options: .mappedIfSafe)
            guard let signers = ZagCodeSignatureInspection.signerCertificates(in: data),
                  let signer = signers.first, signers.allSatisfy({ $0 == signer }),
                  let certificate = ZagCertificateInspection(der: signer),
                  let team = certificate.organizationalUnit, bundle == "app.zagstore.ios." + team,
                  certificate.expiresAt > .now,
                  let entitlements = try ZagNativeAccountInstall.runningComponents(certificate: signer)[bundle]
            else { throw Failure.context }
            let component = ZagNativeInstalledProfiles.Component(originalBundleIdentifier: "app.zagstore.ios",
                bundleIdentifier: bundle, uuid: "", expiresAt: .distantPast, signedEntitlements: entitlements)
            _ = try ZagProfileOnlyRenewal.validate(Data(contentsOf: profile), component: component, team: team,
                certificate: signer, udid: udid)
            return (signer, team, certificate.serialNumber, certificate.expiresAt, certificate.commonName)
        }.value
        if let checkInventory {
            guard checkInventory(evidence.4), ZagRPPairingCore.shared.pairedIdentity == device else { throw Failure.context }
        } else {
            guard let bootstrap, (try? bootstrap.validate()) != nil,
                  bootstrap.team == evidence.1, bootstrap.certificate == evidence.0,
                  !ZagRPPairingCore.shared.hasSavedPairing else { throw Failure.context }
        }
        guard try ZagNativeAppleIDs.shared.catalog().activeID == account,
              ZagNativeAppleIDs.shared.connectedToken(account) == token else { throw Failure.context }
        return Context(token: token, device: device, udid: udid, bundle: bundle, team: evidence.1, signer: evidence.0,
                       serial: evidence.2, certificateExpiry: evidence.3)
    }

    func verifyExisting(_ bootstrap: Envelope.Bootstrap) async -> Bool {
        do {
            let attempt = generation
            guard let account = try ZagNativeAppleIDs.shared.catalog().activeID,
                  let token = ZagNativeAppleIDs.shared.connectedToken(account),
                  try Envelope.scope(account: token.accountID, team: bootstrap.team) == bootstrap.keyScope,
                  let raw = try ZagNativeAccountInstall.secrets.load(.signingPrivateKey, account: account, team: bootstrap.team)
            else { return false }
            let identity = try JSONDecoder().decode(ZagSigningIdentity.self, from: raw)
            let keys = ZagKeychainSigningKeyFactory(keys: .init(namespace: ZagNativeAccountInstall.namespace))
            guard identity.certificate == bootstrap.certificate,
                  keys.check(certificate: identity.certificate, privateKey: identity.privateKey,
                             account: account, team: bootstrap.team, keySlot: identity.keySlot) != .mismatch
            else { return false }
            let context = try await context()
            guard generation == attempt, context.token == token,
                  context.udid.caseInsensitiveCompare(bootstrap.udid) == .orderedSame,
                  context.bundle == bootstrap.bundle, context.team == bootstrap.team, context.signer == bootstrap.certificate
            else { return false }
            try await ZagNativeAccountInstall.verifyRunningInstallation()
            guard generation == attempt, ZagNativeAppleIDs.shared.connectedToken(account) == token,
                  ZagRPPairingCore.shared.pairedIdentity == context.device else { return false }
            let proof = try bootstrap.wrap(Data(SHA256.hash(data: bootstrap.certificate)), label: "existing")
            try proof.write(to: Self.file(Envelope.acknowledgementPath), options: [.atomic, .completeFileProtection])
            message = "Signing identity is already verified for this installation."
            return true
        } catch {
            return false
        }
    }

    func cancelSetup(_ bootstrap: Envelope.Bootstrap) {
        cancel()
        if let proof = try? bootstrap.wrap(Data(), label: "cancelled"),
           let url = try? Self.file(Envelope.acknowledgementPath) {
            try? proof.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    @discardableResult
    func prepare(bootstrap: Envelope.Bootstrap? = nil) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        cancel()
        let attempt = generation
        message = nil
        do {
            let context = try await context(bootstrap: bootstrap)
            guard generation == attempt else { return false }
            let key = Curve25519.KeyAgreement.PrivateKey()
            let request = Envelope.Request(protocolVersion: 1, nonce: UUID(),
                expires: min(bootstrap?.expires ?? .infinity, Date().timeIntervalSince1970 + Envelope.lifetime),
                recipient: key.publicKey.rawRepresentation, udid: context.udid, bundle: context.bundle, team: context.team,
                keyScope: try Envelope.scope(account: context.token.accountID, team: context.team), certificate: context.signer)
            try request.validate()
            let bytes = try JSONEncoder().encode(request)
            if let bootstrap {
                try bootstrap.check(request)
                try bootstrap.wrap(bytes, label: "request").write(to: Self.file(Envelope.setupRequestPath),
                                                                  options: [.atomic, .completeFileProtection])
            } else {
                try bytes.write(to: Self.file(Envelope.requestPath), options: [.atomic, .completeFileProtection])
                code = Envelope.code(bytes)
            }
            pending = Pending(key: key, bytes: bytes, token: context.token)
            return true
        } catch {
            message = (error as? Failure)?.localizedDescription ?? Failure.context.localizedDescription
            return false
        }
    }

    func accept(bootstrap: Envelope.Bootstrap? = nil, authenticatedResponse: Data? = nil) async {
        guard !busy, let pending else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            let response: Data
            if let bootstrap, let authenticatedResponse {
                response = try bootstrap.unwrap(authenticatedResponse, label: "response")
            } else {
                let url = try Self.file(Envelope.responsePath)
                guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.responseMissing }
                response = try Self.read(Envelope.responsePath, limit: Envelope.maxSize)
            }
            // Consume before import. Interrupted transfers need a new challenge.
            cancel()
            let attempt = generation
            let importedWithoutPairing = try await ZagNativeAccountInstall.withExclusiveOperation {
                let context = try await context(bootstrap: bootstrap)
                guard context.token == pending.token else { throw Failure.context }
                let request = try Envelope.decodeRequest(pending.bytes)
                try bootstrap?.check(request)
                try request.checkBinding(device: context.udid, bundle: context.bundle, team: context.team,
                    scope: Envelope.scope(account: context.token.accountID, team: context.team), certificate: context.signer)
                let account = context.token.nativeAccountID
                let scope = ZagSigningScope(accountID: account, teamID: context.team)
                if let entry = ZagNativeAppInventory.entry(bundleIdentifier: context.bundle) {
                    guard entry.pendingInstall == nil, entry.installation.record.owner?.scope == scope else { throw Failure.conflict }
                }
                let portal = ZagNativeAccountInstall.portal(token: context.token, consent: ZagDenyingMutationConsent(), maxRequests: 16)
                let teams = try await portal.teams()
                guard ZagNativeDeveloperTeam.personalTeam(in: teams, expectedID: context.team) != nil else { throw Failure.certificate }
                let certificates = try await portal.certificates(team: context.team)
                guard generation == attempt,
                      certificates.contains(where: { $0.data == context.signer && $0.expiresAt > .now }),
                      try ZagNativeAppleIDs.shared.catalog().activeID == account,
                      ZagNativeAppleIDs.shared.connectedToken(account) == context.token,
                      (context.device == nil ? !ZagRPPairingCore.shared.hasSavedPairing
                                             : ZagRPPairingCore.shared.pairedIdentity == context.device)
                else { throw Failure.certificate }
                try bootstrap?.validate()
                var key = try Envelope.open(response, request: pending.bytes, recipient: pending.key)
                defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
                try ZagNativeAppleIDs.shared.storeTeams(teams.map(\.signingTeam), for: account)
                let keys = ZagKeychainSigningKeys(namespace: ZagNativeAccountInstall.namespace)
                do {
                    try ZagSigningIdentityHandoffImport.commit(certificate: context.signer, serial: context.serial,
                        expires: context.certificateExpiry, scope: scope, store: ZagNativeAccountInstall.secrets) { slot in
                        try keys.importHandoff(key, certificate: context.signer, account: account, team: context.team, slot: slot)
                    }
                } catch ZagSigningIdentityHandoffImport.Failure.conflict {
                    throw Failure.conflict
                }
                return context.device == nil
            }
            if importedWithoutPairing, let bootstrap {
                guard generation == attempt else { return }
                let proof = try bootstrap.wrap(Data(SHA256.hash(data: pending.bytes)), label: "imported")
                try proof.write(to: Self.file(Envelope.acknowledgementPath), options: [.atomic, .completeFileProtection])
                message = "Signing identity received. Installation pairing is only needed to enable local installation and renewal."
                return
            }
            // This independently verifies paired inventory, existing ownership
            // and profile readback before publishing a renewable receipt.
            if let bootstrap {
                do {
                    try await ZagNativeAccountInstall.verifyRunningInstallation()
                    guard generation == attempt else { return }
                    let proof = try bootstrap.wrap(Data(SHA256.hash(data: pending.bytes)), label: "verified")
                    try proof.write(to: Self.file(Envelope.acknowledgementPath), options: [.atomic, .completeFileProtection])
                    message = "Signing identity received and this installation is verified for renewal."
                } catch {
                    message = "Signing identity received. Installation ownership could not be confirmed. Reconnect and retry Signing Setup."
                }
            } else {
                await ZagRunningInstallation.shared.inspect(verifyPersonal: true, retry: true)
                message = ZagRunningInstallation.shared.nativeUUID == nil
                    ? "Signing identity received. Retry installation verification to enable self-renewal."
                    : "Signing identity received and this installation is verified for renewal."
            }
        } catch {
            message = (error as? Failure)?.localizedDescription
                ?? (error as? Envelope.Failure)?.localizedDescription ?? Failure.storage.localizedDescription
        }
    }


}

struct ZagIdentityHandoffView: View {
    @StateObject private var handoff = ZagIdentityHandoff()

    var body: some View {
        Form {
            Section {
                Text("Activate the Apple ID that signed this copy and pair this iPhone. Connect it to the trusted Mac that holds the signing key.")
                Button("Prepare Signing Identity Transfer") { Task { await handoff.prepare() } }
                    .disabled(handoff.busy || handoff.code != nil)
            }
            if let code = handoff.code {
                Section {
                    Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("Enter this verification code in Zag Installer on the Mac. Keep this screen open. The code expires after ten minutes.")
                    Button("Import Desktop Signing Identity") { Task { await handoff.accept() } }
                        .disabled(handoff.busy)
                    Button("Cancel Transfer", role: .cancel) { handoff.cancel() }.disabled(handoff.busy)
                }
            }
            if let message = handoff.message { Text(message) }
        }
        .navigationTitle("Desktop Signing Identity")
        .onDisappear { handoff.cancel() }
    }
}

struct ZagAutomaticIdentitySetupModifier: ViewModifier {
    let ready: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrap: ZagIdentityHandoffEnvelope.Bootstrap?

    func body(content: Content) -> some View {
        content
            .task(id: ready && scenePhase == .active) {
                guard ready, scenePhase == .active,
                      Bundle.main.bundleIdentifier?.hasPrefix("app.zagstore.ios.") == true else { return }
                while !Task.isCancelled {
                    if let next = ZagIdentityHandoff.takeBootstrap() { bootstrap = next }
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
            .sheet(isPresented: Binding(get: { bootstrap != nil }, set: { if !$0 { bootstrap = nil } })) {
                if let bootstrap { ZagAutomaticIdentitySetupView(bootstrap: bootstrap).id(bootstrap.id) }
            }
    }
}

private struct ZagAutomaticIdentitySetupView: View {
    typealias Envelope = ZagIdentityHandoffEnvelope
    let bootstrap: Envelope.Bootstrap
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pairing = ZagRPPairingCore.shared
    @StateObject private var handoff = ZagIdentityHandoff()
    @State private var selectedAccount: UUID?
    @State private var signingIn = false
    @State private var authorised = false
    @State private var checkingExisting = true
    @State private var verifiedExisting = false
    @State private var notice: String?

    private func matchingAccount(_ id: UUID) -> Bool {
        guard let token = ZagNativeAppleIDs.shared.connectedToken(id) else { return false }
        return (try? Envelope.scope(account: token.accountID, team: bootstrap.team)) == bootstrap.keyScope
    }

    private func selectAccount(_ id: UUID) {
        guard matchingAccount(id) else {
            notice = "Use the same Apple ID that signed this copy on the Mac."
            return
        }
        selectedAccount = id
        notice = nil
    }

    private func authorize() {
        guard let selectedAccount, matchingAccount(selectedAccount) else {
            self.selectedAccount = nil
            notice = "Sign in with the original Apple ID before authorizing setup."
            return
        }
        do {
            try ZagNativeAppleIDs.shared.activate(selectedAccount)
            notice = nil
            authorised = true
        } catch {
            notice = "Zag Store could not activate the original Apple ID."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Text("Use the signing identity from your trusted USB connection. This copy will keep the certificate it was installed with.")
                if selectedAccount == nil {
                    Button("Sign In with the Original Apple ID") { signingIn = true }
                }
                if checkingExisting {
                    ProgressView("Checking existing signing identity…")
                } else if !authorised && !verifiedExisting {
                    Button("Authorize Signing Identity") { authorize() }
                        .disabled(selectedAccount == nil)
                } else if handoff.message == nil && notice == nil {
                    ProgressView("Verifying signing setup…")
                }
                if let notice = notice ?? handoff.message { Text(notice) }
                if !pairing.hasSavedPairing && (verifiedExisting || handoff.message != nil) {
                    NavigationLink("Set Up Installation Pairing") { InstallationView() }
                }
            }
            .navigationTitle("Signing Setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(verifiedExisting || (authorised && handoff.message != nil) ? "Done" : "Close") {
                        if !verifiedExisting && handoff.message == nil { handoff.cancelSetup(bootstrap) }
                        dismiss()
                    }
                }
            }
            .navigationDestination(isPresented: $signingIn) {
                ZagAppleIDAuthenticationView(account: nil) { id in
                    selectAccount(id)
                    signingIn = false
                }
            }
        }
        .onAppear {
            if let account = try? ZagNativeAppleIDs.shared.catalog().accounts.first(where: { matchingAccount($0.id) }) {
                selectAccount(account.id)
            }
        }
        .task {
            verifiedExisting = await handoff.verifyExisting(bootstrap)
            checkingExisting = false
        }
        .task(id: authorised) {
            guard authorised, await handoff.prepare(bootstrap: bootstrap) else { return }
            while !Task.isCancelled, (try? bootstrap.validate()) != nil {
                if let wire = try? ZagIdentityHandoff.read(Envelope.setupResponsePath, limit: Envelope.maxWireSize),
                   (try? bootstrap.unwrap(wire, label: "response")) != nil {
                    await handoff.accept(bootstrap: bootstrap, authenticatedResponse: wire)
                    return
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            handoff.cancel()
            notice = "Signing Setup expired. Reconnect the iPhone and retry setup on the Mac."
        }
        .onDisappear { handoff.cancel() }
    }
}

#endif
