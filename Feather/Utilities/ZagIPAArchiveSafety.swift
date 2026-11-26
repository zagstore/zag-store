import Foundation
import Minizip

enum ZagIPAArchiveSafety {
	enum Failure: LocalizedError {
		case invalidArchive
		var errorDescription: String? { "The IPA contains an invalid file list and could not be opened." }
	}

	static func isSafePath(_ name: String) -> Bool {
		let path = name.replacingOccurrences(of: "\\", with: "/")
		guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
		let segments = path.split(separator: "/")
		return !segments.isEmpty && !segments.contains { $0 == ".." || $0 == "." }
	}

	/// Check the same ZIP directory the extractor uses, without decompressing
	/// any files. The caller owns the archive inside a private work directory.
	static func validate(_ archive: URL) throws {
		guard let file = archive.path.withCString({ unzOpen64($0) }) else { throw Failure.invalidArchive }
		defer { unzClose(file) }
		var status = unzGoToFirstFile(file)
		var total: UInt64 = 0
		var entries = 0
		while status == UNZ_OK {
			entries += 1
			var info = unz_file_info64()
			guard entries <= 150_000,
				  unzGetCurrentFileInfo64(file, &info, nil, 0, nil, 0, nil, 0) == UNZ_OK,
				  (1...4096).contains(info.size_filename) else { throw Failure.invalidArchive }
			let (size, overflow) = total.addingReportingOverflow(UInt64(info.uncompressed_size))
			guard !overflow, size <= 16 * 1024 * 1024 * 1024 else { throw Failure.invalidArchive }
			total = size
			let length = Int(info.size_filename)
			var name = [CChar](repeating: 0, count: length + 1)
			guard unzGetCurrentFileInfo64(file, &info, &name, UInt(name.count), nil, 0, nil, 0) == UNZ_OK,
				  let path = String(bytes: name.prefix(length).map { UInt8(bitPattern: $0) }, encoding: .utf8),
				  isSafePath(path) else { throw Failure.invalidArchive }
			status = unzGoToNextFile(file)
		}
		guard status == UNZ_END_OF_LIST_OF_FILE, entries > 0 else { throw Failure.invalidArchive }
	}
}
