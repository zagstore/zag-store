import Foundation
import SwiftUI
import AppKit

struct InstallerPrompt: Identifiable {
    let id = UUID()
    let message: String
    let secure: Bool
    let confirmation: String?
    let action: String?
}

@MainActor
final class InstallerController: ObservableObject {
    @Published var busy = false
    @Published var prompt: InstallerPrompt?
    @Published var log = "Connect and unlock your iPhone, trust this Mac and enable Developer Mode.\n"
    @Published var status = "Ready"
    @Published var installedBundle = ""
    @Published var identityImported = false
    @Published var setupVerified = false
    @Published var stage: String?
    @Published private(set) var observedStages: Set<String> = []

    private var task: Process?
    private var input: FileHandle?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var events = Data()
    private var sessionID = UUID()
    private var eventStreamEnded = false
    private var exitCode: Int32?
    private var receivedError = false
    private var cancellationRequested = false

    func begin(upgrade: Bool, team: String, resumeSetup: Bool = false) {
        guard !busy else { return }
        let environment = ProcessInfo.processInfo.environment
        let bundled = Bundle.main.object(forInfoDictionaryKey: "ZagEngineBundled") as? Bool == true
        let nativeDev = bundled && Bundle.main.object(forInfoDictionaryKey: "ZagNativeInstallDevelopment") as? Bool == true
        guard !resumeSetup || nativeDev else { return }
        let resource = Bundle.main.resourceURL?.appendingPathComponent("DesktopEngine", isDirectory: true)
        let fileManager = FileManager.default
        let root: String
        if bundled {
            guard let resource,
                  fileManager.fileExists(atPath: resource.appendingPathComponent("tools/zag-installer/zag_installer.py").path),
                  fileManager.fileExists(atPath: resource.appendingPathComponent("helpers/release").path),
                  fileManager.fileExists(atPath: resource.appendingPathComponent("helpers/zag_desktop").path) else {
                status = "Bundled installer engine is unavailable"
                append("The signed installer bundle is incomplete. Reinstall zLoader from the official source.")
                return
            }
            root = resource.path
        } else {
            // Development-only fallback. A distributed app sets ZagEngineBundled=true.
            let roots = [
                environment["ZAG_INSTALLER_ROOT"],
                fileManager.currentDirectoryPath,
                NSHomeDirectory() + "/Documents/ZagStore-claude"
            ].compactMap { $0 }
            guard let checkout = roots.first(where: {
                fileManager.fileExists(atPath: $0 + "/tools/zag-installer/zag_installer.py")
            }) else {
                status = "Development checkout not found"
                append("Set ZAG_INSTALLER_ROOT to the verified Zag Store checkout, or launch from that checkout.")
                return
            }
            root = checkout
        }
        let selectedTeam = team.trimmingCharacters(in: .whitespacesAndNewlines)
        if (upgrade || resumeSetup) && selectedTeam.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) == nil {
            status = "Enter the original 10-character Personal Team ID"
            return
        }
        let script = root + "/tools/zag-installer/zag_installer.py"
        let process = Process()
        if bundled {
            let privatePython = root + "/python/bin/python3"
            let localOpenSSL = root + "/helpers/openssl"
            guard fileManager.isExecutableFile(atPath: privatePython),
                  fileManager.isExecutableFile(atPath: localOpenSSL) else {
                status = "Private installer runtime is missing"
                append("The installer package is incomplete. Reinstall zLoader from the official source.")
                return
            }
            process.executableURL = URL(fileURLWithPath: privatePython)
            process.arguments = [script, "--ui-pipe", "--precompiled-helpers",
                                 root + "/helpers", "--usb-transport", "standalone"]
                + (nativeDev ? ["--native-gui-dev"] : [])
                + (resumeSetup ? ["setup", "--team", selectedTeam] :
                    ["install"] + (upgrade ? ["--upgrade", selectedTeam] : []))
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script, "--ui-pipe", "install"]
                + (upgrade ? ["--upgrade", selectedTeam] : [])
        }
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        var env = environment
        let home = NSHomeDirectory()
        let extras = [
            "/opt/homebrew/opt/openssl@3/bin",
            "/usr/local/opt/openssl@3/bin",
            home + "/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        env["PATH"] = bundled ? [root + "/helpers", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
            : (extras + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"])
                .joined(separator: ":")
        if bundled {
            env.removeValue(forKey: "PYTHONHOME")
            env.removeValue(forKey: "PYTHONPATH")
            env.removeValue(forKey: "DYLD_LIBRARY_PATH")
            env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        }
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["ZAG_ANISETTE_URL"] = "" // Native provider, never silently select a remote service
        process.environment = env

        let stdin = Pipe()
        let eventsPipe = Pipe()
        let logsPipe = Pipe()
        process.standardInput = stdin
        process.standardOutput = eventsPipe
        process.standardError = logsPipe
        input = stdin.fileHandleForWriting
        stdout = eventsPipe
        stderr = logsPipe
        events.removeAll()
        sessionID = UUID()
        let session = sessionID
        eventStreamEnded = false
        exitCode = nil
        receivedError = false
        cancellationRequested = false
        installedBundle = ""
        identityImported = false
        setupVerified = false
        stage = nil
        observedStages.removeAll()
        prompt = nil
        log = ""
        status = resumeSetup ? "Checking the existing installation and signing receipt" : "Verifying the signed release and connected iPhone"
        busy = true
        task = process

        // A single reader enqueues data and EOF in order on the main queue.
        // Process exit alone does not imply the final event has been consumed.
        // Drain unstructured child output without displaying or retaining it.
        // Only structured protocol guidance and local diagnostic messages reach the UI.
        logsPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] completed in
            let code = completed.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionID == session, self.busy else { return }
                self.exitCode = code
                self.finishIfReady()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.sessionID == session, self.busy, !self.eventStreamEnded else { return }
                    self.status = "Installer event stream did not close. Check the device before retrying."
                    self.receivedError = true
                    self.close()
                }
            }
        }
        do {
            try process.run()
            let reader = eventsPipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                while true {
                    let data = reader.availableData
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sessionID == session, self.busy else { return }
                        if data.isEmpty {
                            self.eventStreamEnded = true
                            self.finishIfReady()
                        } else {
                            self.consume(data)
                        }
                    }
                    if data.isEmpty { break }
                }
            }
        } catch {
            status = "Unable to start the installer"
            append(bundled ? "Check the local Python runtime and USB support." :
                   "Check Python 3, Xcode, Cargo and the development checkout.")
            close()
        }
    }

    private func consume(_ data: Data) {
        events.append(data)
        if events.count > 16_384 {
            status = "Invalid installer protocol"
            task?.terminate()
            return
        }
        while let newline = events.firstIndex(of: 10) {
            let line = Data(events.prefix(upTo: newline))
            events.removeSubrange(...newline)
            guard line.count <= 8192,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let kind = object["type"] as? String else {
                status = "Invalid installer response"
                task?.terminate()
                return
            }
            switch kind {
            case "prompt":
                guard prompt == nil,
                      let message = object["message"] as? String,
                      let secure = object["secure"] as? Bool else {
                    status = "Unexpected installer prompt"
                    task?.terminate()
                    return
                }
                let confirmation = object["confirmation"] as? String
                let action = object["action"] as? String
                guard (confirmation == nil && action == nil) || (!secure && confirmation?.isEmpty == false && ["Install", "Upgrade", "Replace", "Continue", "Resume Setup", "Create Certificate"].contains(action ?? "")) else {
                    status = "Invalid installer confirmation"
                    task?.terminate()
                    return
                }
                prompt = InstallerPrompt(message: message, secure: secure, confirmation: confirmation, action: action)
                status = "Your confirmation is required"
            case "progress":
                let labels = ["preflight": "Checking release and device", "authentication": "Authenticating Apple ID",
                              "provisioning": "Preparing signing credentials", "signing": "Signing Zag Store",
                              "installation": "Installing Zag Store", "handoff": "Transferring signing setup"]
                guard let next = object["stage"] as? String, let label = labels[next] else {
                    status = "Invalid installer stage"
                    task?.terminate()
                    return
                }
                observedStages.insert(next)
                stage = next
                status = label
            case "finished":
                if let result = object["result"] as? [String: Any] {
                    installedBundle = result["installed_bundle"] as? String ?? ""
                    setupVerified = result["signing_setup"] as? String == "verified"
                    identityImported = setupVerified || result["signing_identity"] as? String == "imported"
                    if setupVerified {
                        status = "Installed and Signing Setup verified"
                    } else if result["signing_identity"] as? String == "imported" {
                        status = "Installed · Signing identity ready · Pairing optional"
                    } else if result["signing_setup"] as? String == "incomplete" {
                        status = "Installed. Signing Setup can be resumed separately."
                    } else {
                        status = "Installation complete"
                    }
                }
            case "error":
                receivedError = true
                status = (object["message"] as? String) ?? "Installation failed"
            default:
                status = "Unknown installer response"
                task?.terminate()
            }
        }
    }

    func answer(_ value: String) {
        guard prompt != nil, let input else { return }
        guard let wire = try? JSONSerialization.data(withJSONObject: ["value": value]),
              wire.count < 4096 else {
            status = "Invalid confirmation"
            return
        }
        input.write(wire + Data([10]))
        prompt = nil
        status = "Continuing installation"
    }

    func dismissCompletion() {
        guard !busy, !installedBundle.isEmpty else { return }
        installedBundle = ""
        identityImported = false
        setupVerified = false
        stage = nil
        observedStages.removeAll()
        status = "Ready"
    }

    func cancel() {
        guard busy, !cancellationRequested else { return }
        cancellationRequested = true
        let session = sessionID
        if prompt != nil, let input,
           let wire = try? JSONSerialization.data(withJSONObject: ["cancel": true]) {
            input.write(wire + Data([10]))
            prompt = nil
        } else {
            task?.terminate()
        }
        status = "Cancelling. Certificate requests may require reconciliation."
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.sessionID == session, self.busy, let process = self.task, process.isRunning else { return }
            process.terminate()
            self.status = "Cancellation requested. Check the device and signing state before retrying."
        }
    }

    private func append(_ value: String) {
        // Diagnostic output is never written to disk or sent to the website.
        let filtered = value.unicodeScalars.filter { $0.value == 10 || $0.value == 9 || $0.value >= 32 }
        log += String(String.UnicodeScalarView(filtered))
        if log.count > 14_000 { log = String(log.suffix(14_000)) }
    }

    private func finishIfReady() {
        guard eventStreamEnded, let code = exitCode else { return }
        if !events.isEmpty {
            receivedError = true
            status = "Incomplete installer response"
        }
        if installedBundle.isEmpty && !receivedError && !status.lowercased().contains("cancel") {
            status = code == 0 ? "Finished without an installation confirmation" : "Installer exited (\(code))"
        }
        if code != 0 && installedBundle.isEmpty { append("\nInstaller exited with status \(code).\n") }
        close()
    }

    private func close() {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        input?.closeFile()
        task = nil
        input = nil
        stdout = nil
        stderr = nil
        busy = false
        prompt = nil
    }
}

private struct DeviceIllustration: View {
    let identifier: String?
    private var homeButton: Bool {
        ["iPhone10,1", "iPhone10,2", "iPhone10,4", "iPhone10,5", "iPhone12,8", "iPhone14,6"].contains(identifier ?? "")
    }
    private var island: Bool {
        ["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4"].contains(identifier ?? "")
    }
    private var notch: Bool {
        ["iPhone10,3", "iPhone10,6", "iPhone11,2", "iPhone11,4", "iPhone11,6", "iPhone11,8", "iPhone12,1", "iPhone12,3", "iPhone12,5", "iPhone13,1", "iPhone13,2", "iPhone13,3", "iPhone13,4", "iPhone14,2", "iPhone14,3", "iPhone14,4", "iPhone14,5", "iPhone14,7", "iPhone14,8", "iPhone17,5"].contains(identifier ?? "")
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(ZagPalette.spectrum).opacity(0.12)
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(ZagPalette.spectrum, lineWidth: 2)
            VStack(spacing: 0) {
                if island {
                    Capsule().fill(ZagPalette.spectrum).frame(width: 11, height: 4).padding(.top, 5)
                } else if notch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                        .fill(ZagPalette.spectrum).frame(width: 14, height: 5).padding(.top, 2)
                } else if homeButton {
                    Capsule().fill(ZagPalette.spectrum).frame(width: 8, height: 2).padding(.top, 5)
                }
                Spacer(minLength: 0)
                if homeButton {
                    Circle().strokeBorder(ZagPalette.spectrum, lineWidth: 1.3).frame(width: 6, height: 6).padding(.bottom, 4)
                } else {
                    Capsule().fill(ZagPalette.spectrum).frame(width: 12, height: 2).padding(.bottom, 4)
                }
            }
        }.frame(width: 29, height: 51)
            .frame(width: 42, height: 54)
            .accessibilityHidden(true)
    }
}

private struct WiredDevice: Sendable {
    let title: String
    let detail: String
    let ready: Bool
    var developerModeRequired = false
    var trusted = false
    var modelIdentifier: String? = nil

    static func friendlyModel(_ identifier: String) -> String {
        let models = [
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
            "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e"
        ]
        return models[identifier] ?? identifier
    }

    static func inspect() -> WiredDevice {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "ZagEngineBundled") as? Bool == true
        let helper: URL?
        if bundled {
            helper = Bundle.main.resourceURL?.appendingPathComponent("DesktopEngine/helpers/zag-usb")
        } else {
            let root = ProcessInfo.processInfo.environment["ZAG_INSTALLER_ROOT"]
                ?? NSHomeDirectory() + "/Documents/ZagStore-claude"
            helper = URL(fileURLWithPath: root).appendingPathComponent("tools/zag-installer/native-usb/target/release/zag-usb")
        }
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            return WiredDevice(title: "Native USB helper unavailable",
                               detail: "zLoader requires its bundled USB helper.", ready: false)
        }
        do {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = helper
            process.arguments = ["status"]
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, data.count <= 8192,
               let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               report["transport"] as? String == "system-usbmuxd",
               report["trust_verified"] as? Bool == false,
               let code = report["diagnostic"] as? String {
                switch code {
                case "no_device":
                    return WiredDevice(title: "No wired device", detail: "Connect your iPhone using a data-capable USB cable.", ready: false)
                case "multiple_devices":
                    return WiredDevice(title: "Multiple wired devices", detail: "Disconnect other devices and leave only the intended iPhone connected.", ready: false)
                case "pairing_unavailable":
                    return WiredDevice(title: "USB trust unavailable", detail: "Unlock your iPhone and confirm Trust if prompted. Existing pairing is not reset.", ready: false)
                case "session_failed", "connection_failed":
                    return WiredDevice(title: "USB session unavailable", detail: "Unlock your iPhone, reconnect the cable and check Trust if prompted.", ready: false)
                case "unsupported_device":
                    return WiredDevice(title: "Unsupported device", detail: "This installer currently requires an iPhone.", ready: false)
                default: break
                }
            }
            guard process.terminationStatus == 0, data.count <= 8192,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["transport"] as? String == "system-usbmuxd",
                  root["trust_verified"] as? Bool == true,
                  let info = root["device"] as? [String: Any],
                  info["DeviceClass"] as? String == "iPhone",
                  let version = info["ProductVersion"] as? String,
                  let model = info["ProductType"] as? String,
                  let name = info["DeviceName"] as? String else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let developerMode = root["developer_mode"] as? Bool
            let ready = developerMode == true
            let modelName = friendlyModel(model)
            let modelAlreadyInName = name.range(of: modelName, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            return WiredDevice(title: name,
                               detail: ((modelAlreadyInName ? [] : [modelName]) + ["iOS \(version)",
                                        ready ? "Trusted USB connection" : (developerMode == false ? "Developer Mode required" : "Developer Mode status unavailable")])
                                   .joined(separator: " · "),
                               ready: ready, developerModeRequired: developerMode == false, trusted: true, modelIdentifier: model)
        } catch {
            return WiredDevice(title: "No trusted wired iPhone",
                               detail: "Connect and unlock one iPhone; confirm Trust and Developer Mode.",
                               ready: false)
        }
    }
}

// Shared with the production WordPress Refraction theme and realtime analytics.
private enum ZagPalette {
    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
    static let cyan = rgb(0x00e5ff)
    static let blue = rgb(0x2979ff)
    static let violet = rgb(0x8b5cf6)
    static let magenta = rgb(0xff2bd6)
    static let spectrum = LinearGradient(colors: [cyan, blue, violet, magenta], startPoint: .leading, endPoint: .trailing)
}

private enum RememberedAccounts {
    static func decode(_ data: String) -> [String] {
        guard let bytes = data.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: bytes) else { return [] }
        return Array(values.prefix(20))
    }
    static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(Array(values.prefix(20))) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct InstallerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dark: Bool { colorScheme == .dark }
    private var completed: Bool { !installer.busy && !installer.installedBundle.isEmpty }
    private var successfulSetup: Bool { completed && installer.identityImported }
    private var actionTitle: String {
        if completed { return "Done" }
        return nativeDevelopment ? "Continue with Apple ID" : (upgrade ? "Upgrade Zag Store" : "Install Zag Store")
    }
    private var nativeDevelopment: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ZagEngineBundled") as? Bool == true &&
        Bundle.main.object(forInfoDictionaryKey: "ZagNativeInstallDevelopment") as? Bool == true
    }
    private var nativeUSBPreview: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ZagEngineBundled") as? Bool == true && !nativeDevelopment
    }
    private var surface: Color { ZagPalette.rgb(dark ? 0x141e33 : 0xffffff) }
    private var border: Color { ZagPalette.rgb(dark ? 0x29374e : 0xdcdcde) }
    private var muted: Color { dark ? ZagPalette.rgb(0xa6b5d2) : Color.secondary }
    private var success: Color { ZagPalette.rgb(dark ? 0x5eead4 : 0x087f75) }
    private var attention: Color { ZagPalette.rgb(dark ? 0xf0b85c : 0x946000) }
    private var atmosphere: some View {
        ZStack {
            ZagPalette.rgb(dark ? 0x0a1020 : 0xf7f9fd)
            RadialGradient(colors: [ZagPalette.blue.opacity(dark ? 0.18 : 0.09), .clear], center: .topLeading, startRadius: 0, endRadius: 390)
            RadialGradient(colors: [ZagPalette.magenta.opacity(dark ? 0.12 : 0.06), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 350)
        }
    }
    private var connectionLight: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !device.ready)) { context in
            let color = device.ready ? success : attention
            let pulse = reduceMotion || !device.ready ? 0.0 : (sin(context.date.timeIntervalSinceReferenceDate * 2.5) + 1) / 2
            ZStack {
                Circle().fill(color.opacity(0.12 + pulse * 0.15)).frame(width: 19, height: 19)
                Circle().fill(color).frame(width: 9, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
    @Environment(\.colorScheme) private var colorScheme
    @State private var device = WiredDevice(title: "Checking USB connection…", detail: "", ready: false)
    @State private var showDiagnostics = false
    @State private var showAdvanced = false
    @State private var showDeviceDetails = false

    private var brandImage: NSImage? {
        let name = colorScheme == .dark ? "zagstore_dark_installer" : "zagstore_installer"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
    @ObservedObject var installer: InstallerController
    @State private var showRecovery = false
    @State private var upgrade = false
    @State private var team = ""
    @State private var reply = ""
    @AppStorage("rememberedAppleID") private var rememberedAppleID = ""
    @AppStorage("rememberedAppleIDs") private var rememberedAppleIDs = "[]"
    @State private var rememberAccount = false
    @State private var revealPassword = false
    @State private var combinedPassword = ""
    @FocusState private var promptFocused: Bool
    @State private var preferredAccount: String?

    private var accountColumn: some View {
        let accounts = RememberedAccounts.decode(rememberedAppleIDs)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "apple.logo").font(.system(size: 17, weight: .medium))
                Text("Apple IDs").font(.system(size: 23, weight: .semibold))
                Spacer()
                Text("\(accounts.count)").font(.caption.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(border, in: Capsule())
            }
            Text("Choose an account for your next installation.")
                .font(.system(size: 14)).foregroundStyle(muted)
            if accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle").font(.system(size: 36, weight: .light))
                    Text("No remembered accounts").font(.system(size: 16, weight: .medium))
                    Text("Remember an Apple ID when signing in.").font(.system(size: 14))
                }.foregroundStyle(muted).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            ForEach(accounts, id: \.self) { account in
                HStack(spacing: 8) {
                    Button {
                        preferredAccount = account
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "person.crop.circle.fill").font(.title2)
                                .foregroundStyle(ZagPalette.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account).font(.system(size: 15, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(preferredAccount == account ? "Selected for next sign-in" : "Remembered")
                                    .font(.system(size: 12)).foregroundStyle(muted)
                            }
                            Spacer(minLength: 0)
                            if preferredAccount == account {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(success)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Menu {
                        Button("Forget Apple ID", role: .destructive) {
                            rememberedAppleIDs = RememberedAccounts.encode(accounts.filter { $0 != account })
                            if preferredAccount == account { preferredAccount = nil }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }.padding(10)
                    .background(surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(preferredAccount == account ? ZagPalette.blue : border, lineWidth: 1) }
            }
            Button {
                preferredAccount = nil
                installer.begin(upgrade: upgrade, team: team)
            } label: {
                Label("Use another Apple ID", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }.disabled(!device.ready || nativeUSBPreview || installer.busy || completed)
            Divider()
            Label("Only account identifiers are remembered. Passwords are not saved.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(muted)
        }
        .padding(16)
        .frame(width: 290)
        .background(surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(border, lineWidth: 1) }
        .disabled(installer.busy)
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
        HStack(alignment: .top, spacing: 20) {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let image = brandImage {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Text("Z").font(.largeTitle.bold()).frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Loader").font(.system(size: 38, weight: .bold)).foregroundStyle(dark ? Color.white : Color.primary).accessibilityLabel("zLoader")
                    Text("Your device. Your apps.")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(muted)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Your password stays between this Mac and Apple. Signing credentials can be transferred privately to your iPhone.", systemImage: "lock.shield")
                HStack(spacing: 12) {
                    DeviceIllustration(identifier: device.modelIdentifier)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.title).font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(dark ? ZagPalette.rgb(0xe8edf5) : Color.primary)
                        Text(device.detail).font(.system(size: 15)).foregroundStyle(muted)
                    }
                    Spacer()
                    connectionLight
                    Button { showDeviceDetails.toggle() } label: {
                        Image(systemName: showDeviceDetails ? "chevron.down" : "chevron.right")
                            .frame(width: 28, height: 28)
                    }.buttonStyle(.plain).accessibilityLabel(showDeviceDetails ? "Hide device details" : "Show device details")
                }
                .padding(12)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1) }
                if showDeviceDetails {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(device.trusted ? "USB trust verified" : "USB trust not verified", systemImage: device.trusted ? "checkmark.shield" : "shield")
                        Label(device.ready ? "Developer Mode enabled" : (device.developerModeRequired ? "Developer Mode disabled" : "Developer Mode not verified"), systemImage: "gearshape")
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
                if device.developerModeRequired {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Enable Developer Mode", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(attention)
                        Text("On your iPhone, open Settings → Privacy & Security → Developer Mode. Enable it, restart your iPhone and confirm when prompted.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Keep your iPhone unlocked and connected. If Developer Mode is missing, reconnect to Xcode and check again.")
                            .font(.caption)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface, in: RoundedRectangle(cornerRadius: 12))
                }
                Label("Pairing can be configured later in Zag Store for local installation and renewal.", systemImage: "arrow.triangle.2.circlepath")
                if nativeUSBPreview {
                    Label("Native USB verified. Installation remains disabled until the USB transfer path is validated.", systemImage: "wrench.and.screwdriver")
                        .foregroundStyle(attention)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(muted)

            if !nativeDevelopment {
                Toggle("Upgrade an existing Personal Team copy", isOn: $upgrade)
                    .disabled(installer.busy)
                if upgrade {
                    TextField("Original Personal Team ID (10 characters)", text: $team)
                        .textFieldStyle(.roundedBorder)
                        .disabled(installer.busy)
                }
            }
            HStack {
                Button {
                    if completed {
                        installer.dismissCompletion()
                    } else {
                        installer.begin(upgrade: upgrade, team: team)
                    }
                } label: {
                    Text(actionTitle)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .opacity(installer.busy ? 0 : 1)
                        .background {
                            ZagUpdateSpectrumSurface(morph: installer.busy ? 1 : 0,
                                                     progress: 1, theme: ZagPalette.rgb(0x0090ff),
                                                     moving: installer.busy, success: successfulSetup)
                        }
                        .contentShape(Capsule())
                        .opacity(!installer.busy && !completed && (!device.ready || nativeUSBPreview) ? 0.45 : 1)
                        .animation(reduceMotion ? nil : .timingCurve(ZagUpdateMorphSpecification.x1,
                            ZagUpdateMorphSpecification.y1, ZagUpdateMorphSpecification.x2,
                            ZagUpdateMorphSpecification.y2, duration: ZagUpdateMorphSpecification.duration),
                            value: installer.busy)
                }
                .buttonStyle(.plain)
                .disabled(installer.busy || (!completed && (!device.ready || nativeUSBPreview)))
                .accessibilityLabel(installer.busy ? "Installation in progress" : actionTitle)
            }
            if installer.busy {
                Button("Cancel installation") { installer.cancel() }.frame(maxWidth: .infinity)
            }
            if nativeDevelopment && !installer.busy && installer.installedBundle.isEmpty {
                Text("Install, update or recover Zag Store using your Apple ID. Existing installations are checked before any changes.")
                    .font(.caption).foregroundStyle(muted).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            if installer.busy {
                Text(installer.status).font(.headline).frame(maxWidth: .infinity)
                Text("Keep your iPhone connected.").font(.caption).foregroundStyle(muted).frame(maxWidth: .infinity)
                if let stage = installer.stage {
                    let steps = ["preflight", "authentication", "provisioning", "signing", "installation", "handoff"]
                    let labels = ["Checking release and device", "Apple ID authentication", "Preparing signing credentials", "Signing Zag Store", "Installing on iPhone", "Transferring signing identity"]
                    if let current = steps.firstIndex(of: stage) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(steps.indices, id: \.self) { index in
                                let visited = installer.observedStages.contains(steps[index])
                                let active = index == current
                                HStack(spacing: 10) {
                                    Image(systemName: active ? "circle.dotted" : (visited ? "checkmark.circle.fill" : "circle"))
                                        .foregroundStyle(active ? ZagPalette.blue : (visited ? success : muted))
                                        .accessibilityHidden(true)
                                    Text(labels[index]).foregroundStyle(active ? Color.primary : muted)
                                    Spacer()
                                    Text(active ? "In progress" : (visited ? "Passed" : "Not started"))
                                        .font(.caption).foregroundStyle(muted)
                                }.accessibilityElement(children: .combine)
                            }
                        }.font(.callout).padding(12)
                            .background(surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else if !installer.installedBundle.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48, weight: .light)).foregroundStyle(success)
                        .accessibilityHidden(true)
                    Text(installer.identityImported ? "You're all set!" : "Signing Setup pending").font(.title2.bold())
                    Text("Zag Store installed on your iPhone.").foregroundStyle(muted)
                }.frame(maxWidth: .infinity)
                Label("Zag Store installed", systemImage: "checkmark.circle.fill").foregroundStyle(success).font(.headline)
                if installer.identityImported {
                    Label("Signing identity ready", systemImage: "checkmark.circle.fill").foregroundStyle(success)
                    Label(installer.setupVerified ? "Signing Setup verified" : "Pairing can be configured later", systemImage: installer.setupVerified ? "checkmark.circle.fill" : "shield")
                        .foregroundStyle(installer.setupVerified ? success : muted)
                } else {
                    Text(installer.status).foregroundStyle(muted)
                    if nativeDevelopment,
                       installer.installedBundle.range(of: #"^app\.zagstore\.ios\.[A-Z0-9]{10}$"#, options: .regularExpression) != nil {
                        let recoveryTeam = String(installer.installedBundle.suffix(10))
                        Button("Resume Signing Setup") {
                            installer.begin(upgrade: false, team: recoveryTeam, resumeSetup: true)
                        }
                        .disabled(!device.ready)
                        Text("Uses the saved signing identity for this installation. No reinstall is required. Apple ID sign-in may still be needed on your iPhone.")
                            .font(.caption).foregroundStyle(muted)
                    }
                }
            } else {
                Text(installer.status).font(.headline)
            }
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            if nativeDevelopment {
                Label("Development build · Existing pairing is not changed automatically.", systemImage: "wrench.and.screwdriver").foregroundStyle(attention).font(.caption)
            }
            if nativeDevelopment {
                DisclosureGroup("Signing Setup Recovery", isExpanded: $showRecovery) {
                    if !upgrade {
                        TextField("Original Personal Team ID (10 characters)", text: $team)
                            .textFieldStyle(.roundedBorder)
                            .disabled(installer.busy)
                    }
                    Button("Resume Signing Setup") {
                        installer.begin(upgrade: false, team: team, resumeSetup: true)
                    }
                    .disabled(installer.busy || !device.ready || team.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) == nil)
                }
            }
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
            Button("Copy safe diagnostic summary") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
                let allowedStages = ["preflight", "authentication", "provisioning", "signing", "installation", "handoff"]
                let stage = installer.stage.flatMap { allowedStages.contains($0) ? $0 : nil } ?? "none"
                let report = [
                    "zLoader \(version) (\(build))",
                    "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                    "USB trust verified: \(device.trusted)",
                    "Developer Mode verified: \(device.ready)",
                    "Operation active: \(installer.busy)",
                    "Stage: \(stage)",
                    "Installation reported: \(!installer.installedBundle.isEmpty)",
                    "Signing identity ready: \(installer.identityImported)",
                    "Signing Setup verified: \(installer.setupVerified)"
                ].joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
            Text("Copies only status flags and software versions, not raw logs or account identifiers.")
                .font(.caption).foregroundStyle(muted)
            ScrollView {
                Text(installer.log.isEmpty ? "Installer diagnostics appear here." : installer.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 180)
            .padding(12)
            .background(surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 1) }
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        accountColumn
        }
        .padding(24)
        }
        Divider()
            HStack {
                Spacer()
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                Text("Version \(version) (\(build))")
                    .font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(muted)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .task {
            while !Task.isCancelled {
                if !installer.busy {
                    device = await Task.detached(priority: .utility) { WiredDevice.inspect() }.value
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 460, idealHeight: 650)
        .background { atmosphere.ignoresSafeArea() }
        .tint(ZagPalette.rgb(0x3a5ce8))
        .sheet(item: $installer.prompt) { prompt in
            let combinedPrompt = prompt.secure && prompt.message == "Apple ID credentials: "
            let accountPrompt = prompt.message == "Apple ID: " || combinedPrompt
            let passwordPrompt = prompt.message == "Apple ID password: "
            let verificationPrompt = prompt.secure && prompt.message == "Apple verification code: "
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: accountPrompt || passwordPrompt ? "apple.logo" : (prompt.secure ? "lock.shield" : "checkmark.shield"))
                        .font(.system(size: 34))
                    Text(accountPrompt || passwordPrompt ? "Sign in with your Apple ID" : (verificationPrompt ? "Enter verification code" : (prompt.secure ? "Secure verification" : "Confirm Installation")))
                        .font(.title2.bold())
                    Text("zLoader").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                if prompt.confirmation == "AUTO-RECOVER" {
                    Label("Recover existing installation", systemImage: "arrow.clockwise.circle")
                        .font(.headline)
                } else if prompt.confirmation == "AUTO-UPGRADE" {
                    Label("Update existing installation", systemImage: "arrow.up.circle")
                        .font(.headline)
                }
                Text(prompt.message)
                    .fixedSize(horizontal: false, vertical: true)
                if verificationPrompt {
                    Text("Enter the six-digit code from your trusted Apple device or phone number.")
                        .font(.callout).foregroundStyle(.secondary)
                    SecureField("Six-digit code", text: $reply)
                        .font(.system(size: 26, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .focused($promptFocused)
                        .accessibilityLabel("Six-digit Apple verification code")
                        .onChange(of: reply) { value in
                            let filtered = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            if filtered != value { reply = filtered }
                        }
                } else if prompt.secure && !combinedPrompt {
                    HStack {
                        if passwordPrompt && revealPassword {
                            TextField("Password", text: $reply).focused($promptFocused)
                        } else {
                            SecureField(passwordPrompt ? "Password" : "Enter securely", text: $reply).focused($promptFocused)
                        }
                        if passwordPrompt {
                            Button { revealPassword.toggle() } label: {
                                Image(systemName: revealPassword ? "eye.slash" : "eye")
                            }.buttonStyle(.plain).accessibilityLabel(revealPassword ? "Hide password" : "Show password")
                        }
                    }.textFieldStyle(.roundedBorder)
                } else if prompt.confirmation == nil {
                    TextField(accountPrompt ? "name@example.com" : "Response", text: $reply)
                        .textFieldStyle(.roundedBorder).focused($promptFocused)
                    if accountPrompt {
                        let accounts = RememberedAccounts.decode(rememberedAppleIDs)
                        if !accounts.isEmpty {
                            Menu("Choose remembered Apple ID") {
                                ForEach(accounts, id: \.self) { account in
                                    Button(account) { reply = account; rememberAccount = true }
                                }
                                Divider()
                                Button("Use another Apple ID") { reply = ""; rememberAccount = false; promptFocused = true }
                            }
                        }
                        if combinedPrompt {
                            HStack {
                                if revealPassword {
                                    TextField("Password", text: $combinedPassword)
                                } else {
                                    SecureField("Password", text: $combinedPassword)
                                }
                                Button { revealPassword.toggle() } label: {
                                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                                }.buttonStyle(.plain).accessibilityLabel(revealPassword ? "Hide password" : "Show password")
                            }.textFieldStyle(.roundedBorder)
                        }
                        Toggle("Remember this Apple ID on this Mac", isOn: $rememberAccount)
                        Text("Only the account identifier is saved, never your password.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Cancel") {
                        reply = ""
                        installer.cancel()
                    }
                    Spacer()
                    Button(prompt.action ?? "Continue") {
                        var answer = prompt.confirmation ?? reply
                        if accountPrompt {
                            let account = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                            var accounts = RememberedAccounts.decode(rememberedAppleIDs)
                            accounts.removeAll { $0.caseInsensitiveCompare(account) == .orderedSame }
                            if rememberAccount && !account.isEmpty && account.utf8.count <= 320 {
                                accounts.insert(account, at: 0)
                            }
                            rememberedAppleIDs = RememberedAccounts.encode(accounts)
                            rememberedAppleID = ""
                        }
                        if combinedPrompt {
                            guard let data = try? JSONSerialization.data(withJSONObject: ["email": reply, "password": combinedPassword]),
                                  let encoded = String(data: data, encoding: .utf8),
                                  encoded.count <= 2048,
                                  let wire = try? JSONSerialization.data(withJSONObject: ["value": encoded]),
                                  wire.count < 4096 else { return }
                            answer = encoded
                        }
                        combinedPassword = ""
                        reply = "" // Do not retain passwords in UI state
                        installer.answer(answer)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.confirmation == nil && (reply.isEmpty || (verificationPrompt && reply.count != 6) || (combinedPrompt && combinedPassword.isEmpty)))
                }
            }
            .padding(24)
            .frame(width: 440)
            .onAppear {
                if !rememberedAppleID.isEmpty {
                    var accounts = RememberedAccounts.decode(rememberedAppleIDs)
                    if !accounts.contains(where: { $0.caseInsensitiveCompare(rememberedAppleID) == .orderedSame }) {
                        accounts.insert(rememberedAppleID, at: 0)
                    }
                    rememberedAppleIDs = RememberedAccounts.encode(accounts)
                    rememberedAppleID = ""
                }
                let selected = preferredAccount.flatMap { account in
                    RememberedAccounts.decode(rememberedAppleIDs).contains(account) ? account : nil
                }
                reply = accountPrompt ? (selected ?? "") : ""
                rememberAccount = accountPrompt && selected != nil
                revealPassword = false
                promptFocused = true
            }
            .onDisappear { reply = ""; combinedPassword = ""; revealPassword = false }
            .interactiveDismissDisabled()
        }
    }
}

private struct InstallerGeneralSettingsView: View {
    @AppStorage("rememberedAppleID") private var rememberedAppleID = ""
    @AppStorage("rememberedAppleIDs") private var rememberedAppleIDs = "[]"
    var body: some View {
        Form {
            Section("Apple ID") {
                let accounts = RememberedAccounts.decode(rememberedAppleIDs)
                if accounts.isEmpty && rememberedAppleID.isEmpty {
                    Text("No remembered Apple IDs")
                }
                ForEach(accounts, id: \.self) { account in
                    HStack {
                        Text(account).textSelection(.enabled)
                        Spacer()
                        Button("Forget") {
                            rememberedAppleIDs = RememberedAccounts.encode(accounts.filter { $0 != account })
                        }.accessibilityLabel("Forget \(account)")
                    }
                }
                if !rememberedAppleID.isEmpty {
                    HStack {
                        Text(rememberedAppleID)
                        Spacer()
                        Button("Forget") { rememberedAppleID = "" }
                    }
                }
                Button("Forget All Apple IDs") {
                    rememberedAppleIDs = "[]"
                    rememberedAppleID = ""
                }.disabled(accounts.isEmpty && rememberedAppleID.isEmpty)
                Text("Only the account identifier is remembered. Passwords are not saved by this preference.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                Text("zLoader · Version \(version) (\(build))")
                Link("Zag Store website", destination: URL(string: "https://zagstore.app")!)
                Button("Third-party acknowledgements…") {
                    if let resources = Bundle.main.resourceURL {
                        let notices = resources.appendingPathComponent("ThirdPartyNotices", isDirectory: true)
                        if FileManager.default.fileExists(atPath: notices.path) {
                            NSWorkspace.shared.open(notices)
                        }
                    }
                }
                Text("Development candidate: third-party licence review is not yet complete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
    }
}

@main
struct ZagInstallerApp: App {
    @StateObject private var installer = InstallerController()
    @StateObject private var updates = InstallerUpdates()

    var body: some Scene {
        WindowGroup {
            InstallerView(installer: installer)
                .onAppear { updates.checkOnLaunchIfAllowed(installerBusy: installer.busy) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About zLoader") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                    let credits = NSAttributedString(string: "Install Zag Store using your own Apple ID.\n\nhttps://zagstore.app", attributes: [.font: NSFont.systemFont(ofSize: 12)])
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "zLoader",
                        .applicationVersion: version,
                        .version: build,
                        .credits: credits
                    ])
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkNow(installerBusy: installer.busy)
                }
                .disabled(!updates.canCheckForUpdates || installer.busy)
            }
        }

        Settings {
            TabView {
                InstallerGeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                InstallerUpdateSettingsView(updates: updates, installer: installer)
                    .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            }.frame(minWidth: 480, minHeight: 280)
        }
    }
}
