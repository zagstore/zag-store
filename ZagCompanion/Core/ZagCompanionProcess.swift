import Foundation

// A small, dependency-free process runner. Every external tool the companion
// uses (xcrun devicectl, xcodebuild, codesign, security, zip) goes through
// here, so argument handling and output capture are consistent and logged.

public struct ZagToolResult: Sendable {
	public let status: Int32
	public let standardOutput: String
	public let standardError: String
	public var combined: String { standardOutput + standardError }
	public var succeeded: Bool { status == 0 }
}

public enum ZagProcess {
	/// Runs a tool to completion, capturing stdout and stderr separately.
	@discardableResult
	public static func run(_ launchPath: String, _ arguments: [String], currentDirectory: URL? = nil,
						   environment: [String: String]? = nil) -> ZagToolResult {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: launchPath)
		process.arguments = arguments
		if let currentDirectory { process.currentDirectoryURL = currentDirectory }
		if let environment { process.environment = environment }
		let out = Pipe(), err = Pipe()
		process.standardOutput = out
		process.standardError = err
		// Drain concurrently so a large output never deadlocks the pipe.
		var outData = Data(), errData = Data()
		let group = DispatchGroup()
		let queue = DispatchQueue(label: "zag.companion.proc", attributes: .concurrent)
		do { try process.run() }
		catch { return ZagToolResult(status: -1, standardOutput: "", standardError: "launch failed: \(error)") }
		group.enter(); queue.async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
		group.enter(); queue.async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
		process.waitUntilExit()
		group.wait()
		return ZagToolResult(status: process.terminationStatus,
							 standardOutput: String(decoding: outData, as: UTF8.self),
							 standardError: String(decoding: errData, as: UTF8.self))
	}

	/// Resolves an Xcode tool path via `xcrun`, falling back to a bare name.
	public static func xcrun(_ tool: String, _ arguments: [String], currentDirectory: URL? = nil) -> ZagToolResult {
		run("/usr/bin/xcrun", [tool] + arguments, currentDirectory: currentDirectory)
	}
}
