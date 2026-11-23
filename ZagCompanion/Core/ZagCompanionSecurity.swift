import Foundation

// Input validation, archive-safety and log hygiene for untrusted IPAs and
// external tool output, plus the pure renewal decision so it can be tested
// without a device or any Apple-side action.

public enum ZagCompanionSafety {
	/// A bundle ID / team ID / UDID we are willing to pass to command-line
	/// tools. Reverse-DNS and identifier charsets only, never a leading "-"
	/// (which a tool could read as an option), no path or shell metacharacters.
	public static func isSafeBundleIdentifier(_ value: String) -> Bool {
		guard !value.isEmpty, value.count <= 155, !value.hasPrefix("-") else { return false }
		let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
		return value.unicodeScalars.allSatisfy { allowed.contains($0) } && value.contains(".")
	}
	public static func isSafeIdentifierToken(_ value: String) -> Bool {
		guard !value.isEmpty, value.count <= 64, !value.hasPrefix("-") else { return false }
		let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
		return value.unicodeScalars.allSatisfy { allowed.contains($0) }
	}

	/// Rejects archive entry names that would escape the extraction directory
	/// (absolute paths, `..` traversal, or a Windows drive/volume prefix).
	public static func isSafeArchiveEntry(_ name: String) -> Bool {
		guard !name.hasPrefix("/"), !name.hasPrefix("~"), !name.contains("\\"), !name.contains(":") else { return false }
		let parts = name.split(separator: "/", omittingEmptySubsequences: false)
		return !parts.contains("..")
	}

	/// True only if `child`, fully resolved (symlinks included), stays inside
	/// `root`. Used after extraction as defence in depth.
	public static func isContained(_ child: URL, within root: URL) -> Bool {
		let r = root.standardizedFileURL.resolvingSymlinksInPath().path
		let c = child.standardizedFileURL.resolvingSymlinksInPath().path
		return c == r || c.hasPrefix(r.hasSuffix("/") ? r : r + "/")
	}

	/// Given a `unzip -Z` (zipinfo long) line, true if the entry is a type we
	/// refuse to extract: a symbolic link (whose target could escape the work
	/// directory or be followed by a later entry) or a special file (device,
	/// fifo, socket). Only regular files (`-`) and directories (`d`) are allowed.
	public static func isUnsafeZipEntryType(zipinfoLine line: String) -> Bool {
		guard let perms = line.split(separator: " ", omittingEmptySubsequences: true).first,
			  let kind = perms.first else { return false }   // header/other lines: ignored here
		switch kind {
		case "-", "d": return false
		case "l", "b", "c", "p", "s": return true            // symlink / block / char / fifo / socket
		default: return false
		}
	}

	/// Walks an extracted tree and returns the first symbolic link whose target
	/// resolves outside `root` (or any symlink at all, since iOS .app bundles
	/// are flat and should contain none). Defence in depth after extraction.
	public static func unsafeSymlink(under root: URL) -> URL? {
		let keys: [URLResourceKey] = [.isSymbolicLinkKey]
		guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
													 options: [], errorHandler: nil) else { return nil }
		for case let url as URL in e {
			let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
			guard isLink else { continue }
			// Any symlink in an iOS payload is treated as unsafe; if its target
			// escapes root it certainly is.
			return url
		}
		return nil
	}
}

/// Redacts anything account-identifying from external-tool output before it is
/// surfaced in an error or logged: email addresses, and long hex runs such as
/// device UDIDs or certificate serials.
public enum ZagRedaction {
	public static func sanitize(_ text: String) -> String {
		var result = text
		for pattern in [
			#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,   // emails
			#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#,               // modern UDIDs
			#"\b[0-9A-Fa-f]{40}\b"#,                              // 40-hex (older UDIDs/hashes)
			#"\b[0-9A-Fa-f]{16,}\b"#,                             // long hex (serials)
		] {
			if let re = try? NSRegularExpression(pattern: pattern) {
				result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<redacted>")
			}
		}
		return String(result.suffix(500))
	}
}

/// What a renewal should do, decided purely from dates and authorization —
/// never claiming an extension that will not happen.
public struct ZagRenewalDecision: Equatable, Sendable {
	public enum Action: Equatable, Sendable {
		/// A profile with a later expiry than the app's already exists on disk.
		case reuseNewerProfile
		/// Not near expiry yet; reinstall is possible but will NOT extend.
		case reuseWithoutExtension
		/// Near expiry: a fresh profile must be issued by Xcode (authorised).
		case provisionFresh
		/// Near expiry and provisioning not authorised: cannot extend.
		case blockedNeedsAuthorization
	}
	public let action: Action
	public var willExtend: Bool { action == .reuseNewerProfile || action == .provisionFresh }
}

public enum ZagRenewalPlanner {
	/// `candidateExpiry` is the best existing covering profile's expiry (nil if
	/// none on disk). `threshold` is how close to expiry triggers a refresh.
	public static func plan(previousExpiry: Date, candidateExpiry: Date?, now: Date,
							threshold: TimeInterval, allowNewProvisioning: Bool) -> ZagRenewalDecision {
		if let candidate = candidateExpiry, candidate > previousExpiry { return .init(action: .reuseNewerProfile) }
		let nearExpiry = previousExpiry.timeIntervalSince(now) <= threshold
		if !nearExpiry, candidateExpiry != nil { return .init(action: .reuseWithoutExtension) }
		return allowNewProvisioning ? .init(action: .provisionFresh) : .init(action: .blockedNeedsAuthorization)
	}
}
