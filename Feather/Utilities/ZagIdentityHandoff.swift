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
        let device: ZagPairedDeviceIdentity
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

    private func file(_ path: String) throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent(String(path.dropFirst("Documents/".count)))
    }

    func cancel() {
        generation = UUID()
        pending = nil
        code = nil
        for path in [Envelope.requestPath, Envelope.responsePath] {
            if let url = try? file(path) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func context() async throws -> Context {
        guard let account = try ZagNativeAppleIDs.shared.catalog().activeID,
              let token = ZagNativeAppleIDs.shared.connectedToken(account),
              let bundle = Bundle.main.bundleIdentifier, let executable = Bundle.main.executableURL,
              let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { throw Failure.context }
        let (device, installed) = try await ZagRPPairingCore.shared.signingDeviceInventory()
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
                certificate: signer, udid: device.udid)
            return (signer, team, certificate.serialNumber, certificate.expiresAt, certificate.commonName)
        }.value
        guard let app = installed[bundle], app.version == Bundle.main.version,
              app.build == Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let signerName = evidence.4, app.signerIdentity == signerName,
              try ZagNativeAppleIDs.shared.catalog().activeID == account,
              ZagNativeAppleIDs.shared.connectedToken(account) == token,
              ZagRPPairingCore.shared.pairedIdentity == device else { throw Failure.context }
        return Context(token: token, device: device, bundle: bundle, team: evidence.1, signer: evidence.0,
                       serial: evidence.2, certificateExpiry: evidence.3)
    }

    func prepare() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        cancel()
        let attempt = generation
        message = nil
        do {
            let context = try await context()
            guard generation == attempt else { return }
            let key = Curve25519.KeyAgreement.PrivateKey()
            let request = Envelope.Request(protocolVersion: 1, nonce: UUID(), expires: Date().timeIntervalSince1970 + Envelope.lifetime,
                recipient: key.publicKey.rawRepresentation, udid: context.device.udid, bundle: context.bundle, team: context.team,
                keyScope: try Envelope.scope(account: context.token.accountID, team: context.team), certificate: context.signer)
            try request.validate()
            let bytes = try JSONEncoder().encode(request)
            let url = try file(Envelope.requestPath)
            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            pending = Pending(key: key, bytes: bytes, token: context.token)
            code = Envelope.code(bytes)
        } catch {
            message = (error as? Failure)?.localizedDescription ?? Failure.context.localizedDescription
        }
    }

    func accept() async {
        guard !busy, let pending else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            let url = try file(Envelope.responsePath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.responseMissing }
            // Consume the challenge before any suspension or attempted import.
            // A partial or rejected response requires a fresh request.
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let response = try input.read(upToCount: Envelope.maxSize + 1) ?? Data()
            cancel()
            let attempt = generation
            try await ZagNativeAccountInstall.withExclusiveOperation {
                let context = try await context()
                guard context.token == pending.token else { throw Failure.context }
                let request = try Envelope.decodeRequest(pending.bytes)
                try request.checkBinding(device: context.device.udid, bundle: context.bundle, team: context.team,
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
                      ZagRPPairingCore.shared.pairedIdentity == context.device else { throw Failure.certificate }
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
            }
            // This independently verifies paired inventory, existing ownership
            // and profile readback before publishing a renewable receipt.
            await ZagRunningInstallation.shared.inspect(verifyPersonal: true, retry: true)
            message = ZagRunningInstallation.shared.nativeUUID == nil
                ? "Signing identity received. Retry installation verification to enable self-renewal."
                : "Signing identity received and this installation is verified for renewal."
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
#endif
