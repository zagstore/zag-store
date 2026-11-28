import Foundation

@main
struct DesktopHandoff {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count == 2 else { throw ZagIdentityHandoffEnvelope.Failure.invalid }
            let request = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            var payload = Data()
            defer { payload.resetBytes(in: payload.startIndex..<payload.endIndex) }
            // A pipe read can be short. Read to EOF without exceeding the
            // envelope's plaintext limit (plus one byte to detect overflow).
            while payload.count <= 4096 {
                guard let chunk = try FileHandle.standardInput.read(upToCount: 4097 - payload.count),
                      !chunk.isEmpty else { break }
                payload.append(chunk)
            }
            let envelope = try ZagIdentityHandoffEnvelope.seal(payload, for: request)
            FileHandle.standardOutput.write(envelope)
        } catch {
            exit(1)
        }
    }
}
