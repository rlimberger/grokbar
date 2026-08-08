import Foundation

/// Official xAI status feed: https://status.x.ai/feed.xml
enum StatusFetcherError: Error {
    case transport(String)
    case badPayload
    case timedOut
}

struct ServiceIncident: Equatable, Sendable, Identifiable {
    var id: String
    /// Raw RSS title, e.g. "[Grok (Web)] Temporarily Unavailable".
    var title: String
    /// Bracketed service name when present.
    var service: String?
    /// Short human line without the service prefix.
    var summary: String
    var status: String
    var severity: String?
    var link: URL?
    var publishedAt: Date?

    var isResolved: Bool {
        let s = status.lowercased()
        return s == "resolved" || s == "completed"
    }

    /// Compact menu-bar / one-line label.
    var shortLabel: String {
        if let service, !service.isEmpty {
            return service
        }
        return summary
    }
}

struct ServiceStatusSnapshot: Equatable, Sendable {
    var activeIncidents: [ServiceIncident]
    var fetchedAt: Date
    var source: String

    var hasActiveIncident: Bool { !activeIncidents.isEmpty }

    /// Best single line for the menu bar / panel header.
    var headline: String {
        guard let first = activeIncidents.first else {
            return "All systems operational"
        }
        if activeIncidents.count == 1 {
            return first.summary
        }
        return "\(activeIncidents.count) active issues on xAI"
    }
}

/// Reads https://status.x.ai/feed.xml (public RSS). HTML status pages are often
/// Cloudflare-gated; the feed is the reliable machine-readable surface.
enum StatusFetcher {
    static let statusPageURL = URL(string: "https://status.x.ai/")!
    static let feedURL = URL(string: "https://status.x.ai/feed.xml")!

    private static let overallTimeout: TimeInterval = 10

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Returns active (non-resolved) incidents. Empty list means no declared issues.
    /// Throws only on hard fetch/parse failure — callers should treat that as unknown, not outage.
    static func fetch() async throws -> ServiceStatusSnapshot {
        let request: URLRequest = {
            var r = URLRequest(url: feedURL)
            r.httpMethod = "GET"
            r.timeoutInterval = 8
            r.cachePolicy = .reloadIgnoringLocalCacheData
            r.setValue("application/rss+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
            r.setValue("grokbar/1.0", forHTTPHeaderField: "User-Agent")
            return r
        }()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withThrowingTimeout(seconds: overallTimeout) {
                try await session.data(for: request)
            }
        } catch is StatusTimeoutError {
            throw StatusFetcherError.timedOut
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw StatusFetcherError.timedOut
        } catch {
            throw StatusFetcherError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StatusFetcherError.transport("Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StatusFetcherError.transport("HTTP \(http.statusCode)")
        }

        let incidents = try parseFeed(data: data)
        let active = incidents.filter { !$0.isResolved }
        return ServiceStatusSnapshot(
            activeIncidents: active,
            fetchedAt: Date(),
            source: "status.x.ai/feed.xml"
        )
    }

    // MARK: - Parse

    private static func parseFeed(data: Data) throws -> [ServiceIncident] {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [.documentTidyXML])
        } catch {
            throw StatusFetcherError.badPayload
        }

        let nodes: [XMLNode]
        do {
            nodes = try doc.nodes(forXPath: "//item")
        } catch {
            throw StatusFetcherError.badPayload
        }

        var incidents: [ServiceIncident] = []
        incidents.reserveCapacity(nodes.count)

        for node in nodes {
            guard let element = node as? XMLElement else { continue }
            let title = text(element, "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }

            let linkRaw = text(element, "link")
            let guid = text(element, "guid") ?? linkRaw ?? title
            let description = text(element, "description") ?? ""
            let pubDate = parseRSSDate(text(element, "pubDate"))

            let categories = element.elements(forName: "category")
                .compactMap { $0.stringValue?.lowercased() }

            let statusFromDesc = firstMatch(
                #"Status:\s*([^<\n]+)"#,
                in: description
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let severityFromDesc = firstMatch(
                #"Severity:\s*([^<\n]+)"#,
                in: description
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Prefer explicit Status in body; fall back to RSS categories.
            let status: String
            if let statusFromDesc, !statusFromDesc.isEmpty {
                status = statusFromDesc
            } else if categories.contains("resolved") {
                status = "RESOLVED"
            } else if let first = categories.first(where: { $0 != "available" }) {
                status = first
            } else {
                status = "unknown"
            }

            let severity = severityFromDesc
                ?? categories.first(where: {
                    ["outage", "disruption", "degraded", "major", "critical", "partial"].contains($0)
                })

            let (service, summary) = splitTitle(title)
            let link = linkRaw.flatMap { URL(string: $0) }

            incidents.append(
                ServiceIncident(
                    id: guid,
                    title: title,
                    service: service,
                    summary: summary,
                    status: status,
                    severity: severity,
                    link: link,
                    publishedAt: pubDate
                )
            )
        }

        // Active first, then most recently published.
        return incidents.sorted { a, b in
            if a.isResolved != b.isResolved { return !a.isResolved && b.isResolved }
            let da = a.publishedAt ?? .distantPast
            let db = b.publishedAt ?? .distantPast
            return da > db
        }
    }

    private static func text(_ element: XMLElement, _ name: String) -> String? {
        element.elements(forName: name).first?.stringValue
    }

    private static func splitTitle(_ title: String) -> (service: String?, summary: String) {
        // "[Grok (Web)] Temporarily Unavailable"
        if title.hasPrefix("["),
           let close = title.firstIndex(of: "]")
        {
            let service = String(title[title.index(after: title.startIndex)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var rest = String(title[title.index(after: close)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.hasPrefix("-") {
                rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return (service.isEmpty ? nil : service, rest.isEmpty ? title : rest)
        }
        return (nil, title)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    private static func parseRSSDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // RFC 822 variants used by RSS
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

// MARK: - Timeout (local copy so this file stays standalone)

private struct StatusTimeoutError: Error {}

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
            throw StatusTimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
