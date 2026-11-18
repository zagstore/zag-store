import Foundation

/// Compares requested entitlements with what a provisioning profile allows.
/// Used by certificate diagnostics, the signing audit and free-account signing.
enum ZagEntitlementCompatibility {
    struct Result {
        let checked: Int
        let issues: [String]
        let error: String?

        var title: String {
            if error != nil { return "Cannot compare entitlements" }
            return issues.isEmpty ? "No mismatches detected" : "Potential entitlement conflicts"
        }
        var summary: String {
            if let error { return error }
            return "\(checked) requested entitlement(s) checked; \(issues.count) potential conflict(s)."
        }
    }

    static func compare(requestedXML: String, profile: [String: Any]) -> Result {
        guard let bytes = requestedXML.data(using: .utf8),
              bytes.count <= 512_000 else {
            return Result(checked: 0, issues: [], error: "Entitlements input is too large or invalid.")
        }
        let decoded: Any
        do {
            decoded = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
        } catch {
            return Result(checked: 0, issues: [], error: "Enter a valid XML property list containing a dictionary of entitlements.")
        }
        guard let requested = decoded as? [String: Any] else {
            return Result(checked: 0, issues: [], error: "The entitlement plist must contain a dictionary.")
        }

        var issues: [String] = []
        for key in requested.keys.sorted() {
            guard let requestedValue = requested[key] else { continue }
            guard let allowedValue = profile[key] else {
                issues.append("\(key): not included in profile")
                continue
            }
            if !matches(requestedValue, allowedValue) {
                issues.append("\(key): requested value differs from profile")
            }
        }
        return Result(checked: requested.count, issues: issues, error: nil)
    }

    static func matches(_ requested: Any, _ allowed: Any) -> Bool {
        // App ID, keychain and group entitlements can include a trailing
        // wildcard. A wildcard is not a general-purpose glob expression.
        if let requested = requested as? String, let allowed = allowed as? String {
            if allowed == requested { return true }
            if allowed.hasSuffix("*"), allowed.filter({ $0 == "*" }).count == 1 {
                return requested.hasPrefix(String(allowed.dropLast()))
            }
            return false
        }
        if let requested = requested as? [String], let allowed = allowed as? [String] {
            return requested.allSatisfy { item in
                allowed.contains { matches(item, $0) }
            }
        }
        if let requested = requested as? [String: Any],
           let allowed = allowed as? [String: Any] {
            return requested.allSatisfy { key, value in
                guard let permitted = allowed[key] else { return false }
                return matches(value, permitted)
            }
        }
        if let lhs = requested as? NSNumber, let rhs = allowed as? NSNumber {
            return CFGetTypeID(lhs) == CFGetTypeID(rhs) && lhs == rhs
        }
        if let lhs = requested as? Data, let rhs = allowed as? Data {
            return lhs == rhs
        }
        if let lhs = requested as? Date, let rhs = allowed as? Date {
            return lhs == rhs
        }
        return false
    }
}
