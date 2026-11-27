import Foundation
import SwiftUI
import AppKit

struct InstallerPrompt: Identifiable {
    let id = UUID()
    let message: String
    let secure: Bool
}

@MainActor
final class InstallerController: ObservableObject {
    @Published var busy = false
    @Published var prompt: InstallerPrompt?
    @Published var log = "Connect and unlock your iPhone, trust this Mac and enable Developer Mode.\n"
    @Published var status = "Ready"
    @Published var installedBundle = ""

    private var task: Process?
    private var input: FileHandle?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var events = Data()

    func begin(upgrade: Bool, team: String) {
        guard !busy else { return }
        let environment = ProcessInfo.processInfo.environment
        let bundled = Bundle.main.object(forInfoDictionaryKey: "ZagEngineBundled") as? Bool == true
        let resource = Bundle.main.resourceURL?.appendingPathComponent("DesktopEngine", isDirectory: true)
        let fileManager = FileManager.default
        let root: String
        if bundled {
            guard let resource,
                  fileManager.fileExists(atPath: resource.appendingPathComponent("tools/zag-installer/zag_installer.py").path),
                  fileManager.fileExists(atPath: resource.appendingPathComponent("helpers/release").path),
                  fileManager.fileExists(atPath: resource.appendingPathComponent("helpers/zag_desktop").path) else {
                status = "Bundled installer engine is unavailable"
                append("The signed installer bundle is incomplete. Reinstall Zag Installer from the official source.")
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
        if upgrade && selectedTeam.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) == nil {
            status = "Enter the original 10-character Personal Team ID"
            return
        }
        let script = root + "/tools/zag-installer/zag_installer.py"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, "--ui-pipe"]
            + (bundled ? ["--precompiled-helpers", root + "/helpers"] : [])
            + ["install"] + (upgrade ? ["--upgrade", selectedTeam] : [])
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
        env["PATH"] = (extras + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"])
            .joined(separator: ":")
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
        installedBundle = ""
        prompt = nil
        log = ""
        status = "Verifying the signed release and connected iPhone"
        busy = true
        task = process

        eventsPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        logsPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let value = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.append(value) }
        }
        process.terminationHandler = { [weak self] completed in
            let code = completed.terminationStatus
            Task { @MainActor [weak self] in self?.ended(code) }
        }
        do {
            try process.run()
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
                prompt = InstallerPrompt(message: message, secure: secure)
                status = "Your confirmation is required"
            case "finished":
                if let result = object["result"] as? [String: Any] {
                    installedBundle = result["installed_bundle"] as? String ?? ""
                    if result["signing_setup"] as? String == "verified" {
                        status = "Installed and Signing Setup verified"
                    } else if result["signing_setup"] as? String == "incomplete" {
                        status = "Installed. Complete Signing Setup on your iPhone."
                    } else {
                        status = "Installation complete"
                    }
                }
            case "error":
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

    func cancel() {
        guard busy else { return }
        if prompt != nil, let input,
           let wire = try? JSONSerialization.data(withJSONObject: ["cancel": true]) {
            input.write(wire + Data([10]))
            prompt = nil
        } else {
            task?.terminate()
        }
        status = "Cancelling. Certificate requests may require reconciliation."
    }

    private func append(_ value: String) {
        // Diagnostic output is never written to disk or sent to the website.
        let filtered = value.unicodeScalars.filter { $0.value == 10 || $0.value == 9 || $0.value >= 32 }
        log += String(String.UnicodeScalarView(filtered))
        if log.count > 14_000 { log = String(log.suffix(14_000)) }
    }

    private func ended(_ code: Int32) {
        if installedBundle.isEmpty && !status.contains("failed") && !status.contains("error")
            && !status.contains("stopped") && !status.contains("cancel") {
            status = code == 0 ? "Finished" : "Installer exited (\(code))"
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

private struct WiredDevice: Sendable {
    let title: String
    let detail: String
    let ready: Bool

    static func inspect() -> WiredDevice {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let report = directory.appendingPathComponent("devices.json")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["devicectl", "list", "devices", "--timeout", "5", "--json-output", report.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any],
                  let result = root["result"] as? [String: Any],
                  let devices = result["devices"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            let wired = devices.filter {
                ($0["connectionProperties"] as? [String: Any])?["transportType"] as? String == "wired"
            }
            guard wired.count == 1, let device = wired.first else {
                return WiredDevice(title: wired.isEmpty ? "No wired device detected" : "Multiple devices connected",
                                   detail: "Connect one iPhone or iPad using USB.", ready: false)
            }
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let paired = connection["pairingState"] as? String == "paired"
            let developer = properties["developerModeStatus"] as? String
            let ready = paired && hardware["platform"] as? String == "iOS" && developer != "disabled"
            let name = properties["name"] as? String ?? "Connected device"
            let model = hardware["marketingName"] as? String ?? hardware["productType"] as? String ?? "iPhone or iPad"
            let version = properties["osVersionNumber"] as? String
            return WiredDevice(title: name, detail: [model, version.map { "iOS \($0)" }, ready ? "USB connected" : "Unlock, trust this Mac and enable Developer Mode"].compactMap { $0 }.joined(separator: " · "), ready: ready)
        } catch {
            return WiredDevice(title: "Device detection unavailable", detail: "Check Xcode device services and USB trust.", ready: false)
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

private struct InstallerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var dark: Bool { colorScheme == .dark }
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

    private var brandImage: NSImage? {
        let name = colorScheme == .dark ? "zagstore_dark" : "zagstore"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
    @ObservedObject var installer: InstallerController
    @State private var upgrade = false
    @State private var team = ""
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                if let image = brandImage {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Text("Z").font(.largeTitle.bold()).frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Zag Installer").font(.largeTitle.bold())
                    Text("Install Zag Store using your own Apple ID")
                        .foregroundStyle(muted)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Your Apple ID stays between this Mac and Apple.", systemImage: "lock.shield")
                HStack(spacing: 12) {
                    Image(systemName: "iphone").font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.title).font(.headline)
                        Text(device.detail).font(.caption).foregroundStyle(muted)
                    }
                    Spacer()
                    connectionLight
                }
                .padding(12)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1) }
                Label("Signing Setup prepares on-device renewal.", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.callout)
            .foregroundStyle(muted)

            Toggle("Upgrade an existing Personal Team copy", isOn: $upgrade)
                .disabled(installer.busy)
            if upgrade {
                TextField("Original Personal Team ID (10 characters)", text: $team)
                    .textFieldStyle(.roundedBorder)
                    .disabled(installer.busy)
            }
            HStack {
                Button {
                    installer.begin(upgrade: upgrade, team: team)
                } label: {
                    Text(installer.busy ? "Installing…" : (upgrade ? "Upgrade Zag Store" : "Install Zag Store"))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background {
                            Capsule().fill(ZagPalette.rgb(0x0090ff))
                        }
                        .contentShape(Capsule())
                        .opacity(installer.busy || !device.ready ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(installer.busy || !device.ready)
                if installer.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { installer.cancel() }
                }
            }
            Divider()
            HStack {
                Text(installer.status).font(.headline)
                Spacer()
                if !installer.installedBundle.isEmpty {
                    Label("Verified install", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(success)
                }
            }
            if !installer.installedBundle.isEmpty {
                Text(installer.installedBundle).font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
            ScrollView {
                Text(installer.log.isEmpty ? "Installer diagnostics appear here." : installer.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            .background(surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: 1) }
            }
            Spacer(minLength: 0)
        }
        .task {
            while !Task.isCancelled {
                if !installer.busy {
                    device = await Task.detached(priority: .utility) { WiredDevice.inspect() }.value
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 565)
        .background { atmosphere.ignoresSafeArea() }
        .tint(ZagPalette.rgb(0x3a5ce8))
        .sheet(item: $installer.prompt) { prompt in
            VStack(alignment: .leading, spacing: 20) {
                Text(prompt.secure ? "Secure Apple Authentication" : "Confirm Installation")
                    .font(.title2.bold())
                Text(prompt.message)
                    .fixedSize(horizontal: false, vertical: true)
                if prompt.secure {
                    SecureField("Enter securely", text: $reply)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("Response", text: $reply)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Cancel") {
                        reply = ""
                        installer.cancel()
                    }
                    Spacer()
                    Button("Continue") {
                        let answer = reply
                        reply = "" // Do not retain passwords in UI state
                        installer.answer(answer)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 440)
            .onAppear { reply = "" }
            .interactiveDismissDisabled()
        }
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkNow(installerBusy: installer.busy)
                }
                .disabled(!updates.canCheckForUpdates || installer.busy)
            }
        }

        Settings {
            InstallerUpdateSettingsView(updates: updates, installer: installer)
        }
    }
}
