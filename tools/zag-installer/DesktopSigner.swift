import Foundation
import Security
import Zsign

func stop(_ message: String, _ status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let args = CommandLine.arguments
guard args.count >= 3 else { stop("Missing desktop signer arguments") }

if args[1] == "read" || args[1] == "write" {
    guard args.count == 3, args[2].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
        stop("Invalid Keychain item scope")
    }
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.zagstore.desktop-installer.v1",
        kSecAttrAccount as String: args[2],
        kSecAttrSynchronizable as String: false,
    ]
    if args[1] == "read" {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { exit(3) }
        guard status == errSecSuccess, let data = item as? Data else { stop("Keychain read failed") }
        FileHandle.standardOutput.write(data)
    } else {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            let attributes = query.merging(changes) { current, _ in current }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { stop("Keychain write failed") }
    }
    exit(0)
}

guard args[1] == "sign", args.count == 6 else { stop("Invalid desktop signing arguments") }
do {
    let certificate = try Data(contentsOf: URL(fileURLWithPath: args[4]))
    let manifest = try Data(contentsOf: URL(fileURLWithPath: args[5]))
    let components = try PropertyListDecoder().decode([String: [String: Data]].self, from: manifest)
    var key = FileHandle.standardInput.readDataToEndOfFile()
    defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
    var error: NSString?
    guard ZagSignComponents(args[2], certificate, key, "", nil,
                            components, args[3], [], &error) else {
        stop("Strict Zsign signing failed")
    }
} catch {
    stop("Desktop signer could not read its inputs")
}
