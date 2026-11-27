import Foundation

@main
struct DesktopHandoff {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 2 else { throw ZagIdentityHandoffEnvelope.Failure.invalid }
            let request = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            var key = try FileHandle.standardInput.read(upToCount: 4097) ?? Data()
            defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
            let envelope = try ZagIdentityHandoffEnvelope.seal(key, for: request)
            FileHandle.standardOutput.write(envelope)
        } catch {
            exit(1)
        }
    }
}
