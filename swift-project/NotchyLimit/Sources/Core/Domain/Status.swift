import Foundation

/// Whether stored credentials are usable.
public enum AuthStatus: String, Codable, Hashable {
    case notConfigured
    case valid
    case expired
}

/// Latest sync state, surfaced in compact + diagnostics views.
public enum SyncStatus: Hashable {
    case idle
    case syncing
    case ok(at: Date)
    case error(ProviderError)
}

/// Categorised provider errors so the UI can react meaningfully.
public enum ProviderError: Error, Hashable, CustomStringConvertible {
    case missingCredentials
    case expiredCredentials(String)
    case unauthorized          // 401/403
    case rateLimited           // 429
    case transport(String)     // network down etc.
    case decoding(String)      // schema drift
    case server(Int)           // 5xx
    case unknown(String)

    public var description: String {
        switch self {
        case .missingCredentials: return "Missing credentials"
        case .expiredCredentials(let m): return m
        case .unauthorized:       return "Authentication expired"
        case .rateLimited:        return "Rate limited"
        // transport and unknown intentionally omit the raw message —
        // URLError.localizedDescription can contain request URLs (with orgId)
        // and system paths. Fixed strings prevent accidental PII exposure in UI.
        case .transport:          return "Network error — check your connection."
        case .decoding(let m):    return "Response schema changed: \(m)"
        case .server(let code):   return "Server error (\(code))"
        case .unknown:            return "An unexpected error occurred."
        }
    }

    public var isAuthIssue: Bool {
        switch self {
        case .unauthorized, .missingCredentials, .expiredCredentials: return true
        default: return false
        }
    }
}
