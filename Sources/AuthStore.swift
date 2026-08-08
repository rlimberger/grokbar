import Foundation

enum AuthStoreError: LocalizedError {
    case missingAuthFile(URL)
    case invalidAuthJSON
    case noAccessToken
    case noRefreshToken
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAuthFile(let url):
            return "Missing Grok auth file at \(url.path). Run `grok login` once."
        case .invalidAuthJSON:
            return "Could not parse ~/.grok/auth.json."
        case .noAccessToken:
            return "No Grok access token found. Run `grok login`."
        case .noRefreshToken:
            return "No refresh token available. Run `grok login`."
        case .refreshFailed(let detail):
            return "Token refresh failed: \(detail)"
        }
    }
}

/// One OIDC credential row from `~/.grok/auth.json`.
struct AuthCredential {
    var scopeKey: String
    var entry: [String: Any]
    var accessToken: String
    var refreshToken: String?
    var clientID: String?
    var issuer: String?
    var expiresAt: Date?

    var identity: AuthIdentity {
        AuthIdentity(
            email: entry["email"] as? String,
            teamID: entry["team_id"] as? String,
            principalType: entry["principal_type"] as? String,
            authMode: entry["auth_mode"] as? String,
            accessToken: accessToken,
            expiresAt: expiresAt,
            tier: JWTClaims.tier(from: accessToken)
        )
    }

    func needsRefresh(leeway: TimeInterval = 5 * 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= leeway
    }
}

/// Reads and refreshes credentials shared with the Grok Build CLI.
enum AuthStore {
    static var grokHome: URL {
        if let custom = ProcessInfo.processInfo.environment["GROK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    static var authFileURL: URL {
        grokHome.appendingPathComponent("auth.json")
    }

    static func loadCredential() throws -> AuthCredential {
        let url = authFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthStoreError.missingAuthFile(url)
        }

        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthStoreError.invalidAuthJSON
        }

        var bestScope: String?
        var bestEntry: [String: Any]?
        var bestScore = -1

        for (scope, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let key = (entry["key"] as? String) ?? ""
            let refresh = (entry["refresh_token"] as? String) ?? ""
            guard !key.isEmpty || !refresh.isEmpty else { continue }

            var score = 0
            if scope.contains("auth.x.ai") { score += 10 }
            if (entry["auth_mode"] as? String) == "oidc" { score += 5 }
            if !refresh.isEmpty { score += 3 }
            if !key.isEmpty { score += 1 }
            if entry["expires_at"] != nil { score += 1 }
            if score > bestScore {
                bestScore = score
                bestScope = scope
                bestEntry = entry
            }
        }

        guard let scopeKey = bestScope, let entry = bestEntry else {
            throw AuthStoreError.noAccessToken
        }

        let token = (entry["key"] as? String) ?? ""
        return AuthCredential(
            scopeKey: scopeKey,
            entry: entry,
            accessToken: token,
            refreshToken: entry["refresh_token"] as? String,
            clientID: entry["oidc_client_id"] as? String,
            issuer: entry["oidc_issuer"] as? String,
            expiresAt: parseDate(entry["expires_at"])
        )
    }

    static func loadValidIdentity() async throws -> AuthIdentity {
        var cred = try loadCredential()
        if cred.needsRefresh() {
            cred = try await refreshCredential(cred)
        }
        if cred.accessToken.isEmpty {
            if cred.refreshToken != nil {
                cred = try await refreshCredential(cred)
            } else {
                throw AuthStoreError.noAccessToken
            }
        }
        return cred.identity
    }

    static func refreshCredential(_ cred: AuthCredential) async throws -> AuthCredential {
        guard let refreshToken = cred.refreshToken, !refreshToken.isEmpty else {
            throw AuthStoreError.noRefreshToken
        }

        let clientID = cred.clientID ?? "b1a00492-073a-47ea-816f-4c329264a828"
        let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("macos-grok-usage-bar/1.0", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthStoreError.refreshFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthStoreError.refreshFailed("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthStoreError.refreshFailed("HTTP \(http.statusCode) \(body.prefix(160))")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String,
            !access.isEmpty
        else {
            throw AuthStoreError.refreshFailed("Missing access_token")
        }

        var updatedEntry = cred.entry
        updatedEntry["key"] = access
        if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
            updatedEntry["refresh_token"] = newRefresh
        }
        if let expiresIn = json["expires_in"] as? Int {
            updatedEntry["expires_at"] = isoFractional(Date().addingTimeInterval(TimeInterval(expiresIn)))
        } else if let expiresIn = json["expires_in"] as? Double {
            updatedEntry["expires_at"] = isoFractional(Date().addingTimeInterval(expiresIn))
        }

        try writeEntry(scopeKey: cred.scopeKey, entry: updatedEntry)

        return AuthCredential(
            scopeKey: cred.scopeKey,
            entry: updatedEntry,
            accessToken: access,
            refreshToken: updatedEntry["refresh_token"] as? String,
            clientID: clientID,
            issuer: cred.issuer,
            expiresAt: parseDate(updatedEntry["expires_at"])
        )
    }

    private static func writeEntry(scopeKey: String, entry: [String: Any]) throws {
        let url = authFileURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = existing
        }
        root[scopeKey] = entry

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private static func isoFractional(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? Double {
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            return Date(timeIntervalSince1970: number)
        }
        if let number = value as? Int {
            return parseDate(Double(number))
        }
        guard let raw = value as? String, !raw.isEmpty else { return nil }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: raw) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}

// MARK: - JWT

enum JWTClaims {
    /// Best-effort read of the unsigned JWT payload (no signature verification needed for display).
    static func tier(from accessToken: String) -> Int? {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        if pad > 0 { payload += String(repeating: "=", count: pad) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let n = json["tier"] as? Int { return n }
        if let n = json["tier"] as? Double { return Int(n) }
        if let n = json["tier"] as? NSNumber { return n.intValue }
        return nil
    }
}
