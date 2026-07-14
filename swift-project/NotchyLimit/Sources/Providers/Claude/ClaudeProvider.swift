import Foundation

/// Claude provider. Tries a user-saved setup token, then CLI OAuth, then the
/// browser session cookie.
///
/// Auth resolution order on every fetch:
///   1. Notchy Keychain token from `claude setup-token` → Bearer token
///   2. Claude Code Keychain / `~/.claude/credentials.json` → Bearer token
///   3. Keychain session cookie (full account access, fallback)
///
/// Both paths hit the same internal `/api/organizations/{org}/usage` endpoint.
/// If OAuth resolves the org ID and the Bearer request succeeds, the cookie is
/// never read from the keychain at all.
final class ClaudeProvider: UsageProvider {
    let id: ProviderId = .claude
    let displayName: String = "Claude"
    let requiresCookie: Bool = false   // OAuth makes cookie optional
    let isAvailable: Bool = true

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - UsageProvider

    func validateCredentials() async throws {
        _ = try await resolveAuthContext()
    }

    func fetchUsage() async throws -> ServiceUsageSnapshot {
        let ctx = try await resolveAuthContext()

        // OAuth token (Claude Code) → api.anthropic.com/api/oauth/usage.
        // Session cookie (claude.ai) → claude.ai/api/organizations/{org}/usage.
        // Both return the same five_hour / seven_day / seven_day_sonnet shape.
        let data: Data
        switch ctx.auth {
        case .bearer:
            data = try await get(url: ClaudeEndpoint.oauthUsage, auth: ctx.auth, oauthUsage: true)
        case .cookie:
            data = try await get(url: ClaudeEndpoint.usage(orgId: ctx.orgId), auth: ctx.auth)
        }

        do {
            let dto = try JSONDecoder().decode(ClaudeUsageDTO.self, from: data)
            return try ClaudeUsageMapper.snapshot(from: dto)
        } catch let e as ProviderError { throw e }
        catch { throw ProviderError.decoding(error.localizedDescription) }
    }

    /// Current auth tier — used by diagnostics + onboarding hint.
    var activeAuthTier: ClaudeAuthTier {
        if let stored: ClaudeCredential = AuthService.shared.loadCredential(for: .claude),
           stored.isBearerToken {
            return .setupToken
        }
        return ClaudeOAuthCredential.isAvailable() ? ClaudeAuthTier.oauth : ClaudeAuthTier.cookie
    }

    // MARK: - Auth resolution

    private enum Auth {
        case bearer(String)
        case cookie(String)
    }

    private struct AuthContext {
        let auth: Auth
        let orgId: String
    }

    /// Tries OAuth, falls back to cookie. Throws `missingCredentials` if neither
    /// is available, or the specific auth error from whichever tier was attempted.
    private func resolveAuthContext() async throws -> AuthContext {
        let stored: ClaudeCredential? = AuthService.shared.loadCredential(for: .claude)

        // ── Tier 1: User-saved setup token ─────────────────────────────────
        if let token = stored?.bearerToken {
            return AuthContext(auth: .bearer(token), orgId: "")
        }

        // ── Tier 2: Claude Code OAuth ──────────────────────────────────────
        if let oauthCred = ClaudeOAuthCredential.readFromDisk() {
            guard !oauthCred.isLikelyExpired else {
                if stored?.cookie.isEmpty == false {
                    return try await cookieAuthContext()
                } else {
                    throw ProviderError.expiredCredentials(
                        "Claude CLI token expired. Run `claude setup-token` and paste the token in Notchy for a more reliable setup."
                    )
                }
            }
            // Claude Code stores the org id alongside the token — use it directly
            // and skip the bootstrap round-trip.
            if let orgId = oauthCred.orgId {
                return AuthContext(auth: .bearer(oauthCred.accessToken), orgId: orgId)
            }
            // The OAuth usage endpoint does not require an organization id.
            // Avoid the claude.ai bootstrap shape, which is not stable for OAuth.
            return AuthContext(auth: .bearer(oauthCred.accessToken), orgId: "")
        }

        // ── Tier 3: Session cookie ─────────────────────────────────────────
        return try await cookieAuthContext()
    }

    private func cookieAuthContext() async throws -> AuthContext {
        let cookie = try currentCookie()
        if let orgFromCookie = ClaudeCredential(cookie: cookie).orgIdFromCookie {
            return AuthContext(auth: .cookie(cookie), orgId: orgFromCookie)
        }
        let orgId = try await bootstrapOrgId(auth: .cookie(cookie))
        return AuthContext(auth: .cookie(cookie), orgId: orgId)
    }

    private func bootstrapOrgId(auth: Auth) async throws -> String {
        let data = try await get(url: ClaudeEndpoint.bootstrap, auth: auth)
        do {
            let dto = try JSONDecoder().decode(ClaudeBootstrapDTO.self, from: data)
            guard let orgId = dto.account?.lastActiveOrgId,
                  UUID(uuidString: orgId) != nil else {
                throw ProviderError.decoding("bootstrap missing or invalid lastActiveOrgId")
            }
            return orgId
        } catch let e as ProviderError { throw e }
        catch { throw ProviderError.decoding("bootstrap parse: \(error.localizedDescription)") }
    }

    private func currentCookie() throws -> String {
        guard let cred: ClaudeCredential = AuthService.shared.loadCredential(for: .claude),
              !cred.cookie.isEmpty else {
            throw ProviderError.missingCredentials
        }
        return cred.cookie
    }

    // MARK: - HTTP

    private func get(url: URL, auth: Auth, oauthUsage: Bool = false) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"

        switch auth {
        case .cookie(let c):
            for (k, v) in ClaudeEndpoint.headers(cookie: c) { request.setValue(v, forHTTPHeaderField: k) }
        case .bearer(let t):
            let headers = oauthUsage ? ClaudeEndpoint.oauthUsageHeaders(token: t)
                                     : ClaudeEndpoint.bearerHeaders(token: t)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unknown("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw ProviderError.unauthorized
        case 429:       throw ProviderError.rateLimited
        case 500...:    throw ProviderError.server(http.statusCode)
        default:        throw ProviderError.unknown("HTTP \(http.statusCode)")
        }
    }
}
