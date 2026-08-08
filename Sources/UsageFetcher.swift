import Foundation

enum UsageFetcherError: LocalizedError {
    case unauthorized
    case httpStatus(Int, String)
    case badPayload
    case transport(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Unauthorized — try running `grok login`."
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body)"
        case .badPayload:
            return "Unexpected billing response from Grok."
        case .transport(let message):
            return message
        case .timedOut:
            return "Timed out fetching usage."
        }
    }
}

/// Fetches billing / quota metadata only (not chat/completions).
enum UsageFetcher {
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let monthlyURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private static let clientVersion = "0.2.118"

    private static let overallTimeout: TimeInterval = 12

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func fetch(token: String, subscriptionTier: Int?) async throws -> UsageSnapshot {
        async let creditsData = getJSON(url: creditsURL, token: token)
        async let monthlyData = optionalGetJSON(url: monthlyURL, token: token)

        let credits = try await creditsData
        let monthly = await monthlyData

        return try parse(creditsRoot: credits, monthlyRoot: monthly, subscriptionTier: subscriptionTier)
    }

    // MARK: - HTTP

    private static func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("xai-grok-cli/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(clientVersion, forHTTPHeaderField: "x-grok-client-version")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("macos-grok-usage-bar", forHTTPHeaderField: "x-grok-client-identifier")
        return request
    }

    private static func getJSON(url: URL, token: String) async throws -> [String: Any] {
        let request = authorizedRequest(url: url, token: token)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTimeout(seconds: overallTimeout) {
                try await session.data(for: request)
            }
        } catch is TimeoutError {
            throw UsageFetcherError.timedOut
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw UsageFetcherError.timedOut
        } catch {
            throw UsageFetcherError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageFetcherError.transport("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageFetcherError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageFetcherError.httpStatus(http.statusCode, String(body.prefix(180)))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageFetcherError.badPayload
        }
        return root
    }

    private static func optionalGetJSON(url: URL, token: String) async -> [String: Any]? {
        try? await getJSON(url: url, token: token)
    }

    // MARK: - Parse

    private static func parse(
        creditsRoot: [String: Any],
        monthlyRoot: [String: Any]?,
        subscriptionTier: Int?
    ) throws -> UsageSnapshot {
        guard let config = creditsRoot["config"] as? [String: Any] else {
            throw UsageFetcherError.badPayload
        }

        var periodType: String?
        var periodStart: Date?
        var periodEnd: Date?

        if let current = config["currentPeriod"] as? [String: Any] {
            periodType = current["type"] as? String
            periodStart = parseDate(current["start"])
            periodEnd = parseDate(current["end"])
        }
        if periodStart == nil {
            periodStart = parseDate(config["billingPeriodStart"])
        }
        if periodEnd == nil {
            periodEnd = parseDate(config["billingPeriodEnd"])
        }

        let usedPercent: Double
        if let percent = doubleValue(config["creditUsagePercent"]) {
            usedPercent = percent
        } else if periodStart != nil || periodEnd != nil || config["currentPeriod"] != nil {
            usedPercent = 0
        } else if
            let monthly = moneyCents(config["monthlyLimit"]),
            let used = moneyCents(config["used"] ?? (config["usage"] as? [String: Any])?["totalUsed"]),
            monthly > 0
        {
            usedPercent = min(100, Double(used) / Double(monthly) * 100)
        } else {
            throw UsageFetcherError.badPayload
        }

        var products: [ProductUsage] = []
        if let rawProducts = config["productUsage"] as? [[String: Any]] {
            products = rawProducts.compactMap { item in
                guard let product = item["product"] as? String else { return nil }
                let percent = doubleValue(item["usagePercent"]) ?? 0
                return ProductUsage(product: product, usagePercent: percent)
            }
            .sorted { $0.usagePercent > $1.usagePercent }
        }

        let prepaid = moneyCents(config["prepaidBalance"])
        let unified = (config["isUnifiedBillingUser"] as? Bool) ?? false

        var monthlyLimit: Int?
        var monthlyUsed: Int?
        if let monthlyConfig = monthlyRoot?["config"] as? [String: Any] {
            monthlyLimit = moneyCents(monthlyConfig["monthlyLimit"])
            monthlyUsed = moneyCents(monthlyConfig["used"])
        }

        return UsageSnapshot(
            usedPercent: usedPercent,
            periodType: periodType,
            periodStart: periodStart,
            periodEnd: periodEnd,
            productUsage: products,
            prepaidBalanceCents: prepaid,
            isUnifiedBilling: unified,
            monthlyLimitCents: monthlyLimit,
            monthlyUsedCents: monthlyUsed,
            subscriptionTier: subscriptionTier,
            fetchedAt: Date(),
            source: "cli-chat-proxy"
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let n = Double(s) { return n }
        return nil
    }

    private static func moneyCents(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        if let obj = value as? [String: Any] {
            if let n = obj["val"] as? Int { return n }
            if let n = obj["val"] as? Double { return Int(n) }
            if let n = obj["val"] as? NSNumber { return n.intValue }
        }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Timeout

private struct TimeoutError: Error {}

private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let ns = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
