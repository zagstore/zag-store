import SwiftUI
import os

@main
struct ZagAuthProbeApp: App {
    @State private var report = "running apple-auth offline self-test…"
    var body: some Scene {
        WindowGroup {
            ScrollView {
                Text(report).font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .onAppear { report = runSelfTest() }
        }
    }
    private func runSelfTest() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let statePath = docs.appendingPathComponent("zag_state.bin").path
        var buf = [CChar](repeating: 0, count: 4096)
        let rc = zag_apple_auth_selftest(statePath, &buf, buf.count)
        let json = String(cString: buf)
        let outURL = docs.appendingPathComponent("zag_result.json")
        try? (json + "\n").data(using: .utf8)?.write(to: outURL)
        os_log("ZAGPROBE rc=%d %{public}@", rc, json)
        return "device self-test rc=\(rc)\n\n\(json)"
    }
}
