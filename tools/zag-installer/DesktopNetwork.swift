import Foundation

enum DesktopNetworkError: Error, LocalizedError {
    case unsafeRedirect, invalidResponse, tooLarge, http(Int), filesystem

    var errorDescription: String? {
        switch self {
        case .unsafeRedirect: return "The download server redirected outside the authorized release location."
        case .invalidResponse: return "The download server returned an unexpected response."
        case .tooLarge: return "The release download exceeded the size limit."
        case .http(let status): return Self.httpMessage(status)
        case .filesystem: return "Could not write the release download. Check free disk space and permissions."
        }
    }

    static func httpMessage(_ status: Int, release: Bool = true) -> String {
        switch status {
        case 401, 403:
            return release ? "The server denied access (HTTP \(status)). Check whether the release is public or the network is blocking it."
                : "Apple denied ADI provisioning (HTTP \(status)). Check network restrictions and try again later."
        case 404:
            return release ? "The authorized release is unavailable (HTTP 404). Check whether the release asset is published."
                : "The Apple provisioning endpoint is unavailable (HTTP 404)."
        case 429: return "The server is rate limiting requests (HTTP 429). Wait and try again."
        case 500...599: return "The server is temporarily unavailable (HTTP \(status)). Try again later."
        default: return "The server returned an unexpected HTTP status (\(status))."
        }
    }

    static func transportMessage(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return "The network request failed." }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "The server name could not be resolved. Check DNS and network connectivity."
        case .notConnectedToInternet, .networkConnectionLost:
            return "The network connection is unavailable or was interrupted. Reconnect and retry."
        case .timedOut:
            return "The request timed out. Try again on a stable connection."
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return "TLS verification failed. Check the Mac's date, macOS trust settings, or an intercepting proxy."
        case .cannotConnectToHost:
            return "The server could not be reached. Check connectivity and firewall settings."
        case .cannotCreateFile, .cannotWriteToFile:
            return DesktopNetworkError.filesystem.localizedDescription
        default:
            return "The network request failed (transport code \(urlError.code.rawValue))."
        }
    }
}
