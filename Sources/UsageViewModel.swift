import AppKit
import Foundation

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var identity: AuthIdentity?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    /// Latest successful status.x.ai snapshot (nil = not fetched or last fetch failed).
    @Published private(set) var serviceStatus: ServiceStatusSnapshot?

    private var fetchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var didStart = false
    private var lastFetchAttemptAt: Date?

    /// Panel-open / opportunistic refresh threshold (when data is good).
    private let staleAfter: TimeInterval = 15 * 60
    /// Background poll while awake (~72 requests/day if never sleeps).
    private let backgroundPollInterval: TimeInterval = 20 * 60
    /// When not signed in / Grok missing, re-check more often so `grok login` shows up soon.
    private let setupPollInterval: TimeInterval = 2 * 60
    /// Declared outages: re-check status more often so recovery clears the banner quickly.
    private let outagePollInterval: TimeInterval = 5 * 60

    /// Bumped every minute so the menu bar countdown stays live without a network call.
    @Published private(set) var clockTick: Date = Date()

    var hasActiveOutage: Bool {
        serviceStatus?.hasActiveIncident == true
    }

    var menuBarTitle: String {
        _ = clockTick
        let outage = hasActiveOutage
        switch state {
        case .loaded(let snap):
            let bar = formatBar(snap)
            return outage ? "⚠ \(bar)" : bar
        case .unavailable:
            // Prefer outage glyph over the calm dash when xAI is declaring issues.
            return outage ? "⚠" : "—"
        case .failed:
            return outage ? "⚠" : "!"
        case .idle, .loading:
            return outage ? "⚠" : "…"
        }
    }

    var menuBarAccessibilityLabel: String {
        _ = clockTick
        var parts: [String] = []
        if let status = serviceStatus, status.hasActiveIncident {
            parts.append("xAI status issue: \(status.headline)")
        }
        switch state {
        case .loaded(let snap):
            let reset = formatCountdown(snap.resetsIn) ?? "unknown"
            parts.append(
                "Grok \(Int(snap.usedPercent.rounded()))% used, \(snap.cycleLabel.lowercased()) pool, resets in \(reset)"
            )
        case .unavailable(let title, let hint):
            parts.append("GrokBar: \(title). \(hint)")
        case .failed(let message):
            parts.append("Grok usage error: \(message)")
        default:
            if parts.isEmpty {
                parts.append("Loading Grok usage")
            }
        }
        return parts.joined(separator: ". ")
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        // Always try to stay registered for login; never surface this in UI.
        LoginItemService.ensureEnabled()
        loadCacheIntoState()
        refreshIfStale()
        scheduleBackgroundPoll()
        scheduleClockTick()
    }

    func panelDidOpen() {
        start()
        refreshIfStale()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        isRefreshing = false
    }

    func refresh() {
        refresh(force: true)
    }

    func refreshIfStale() {
        if !isStale { return }
        refresh(force: false)
    }

    private var isStale: Bool {
        if hasActiveOutage { return true }
        if case .loaded(let snap) = state {
            if Date().timeIntervalSince(snap.fetchedAt) < staleAfter {
                return false
            }
        }
        // Setup / failed states should re-check on panel open even if we recently tried.
        if case .unavailable = state { return true }
        if case .failed = state { return true }
        if let last = lastFetchAttemptAt, Date().timeIntervalSince(last) < staleAfter {
            return false
        }
        return true
    }

    private func refresh(force: Bool) {
        if isRefreshing { return }
        if !force, !isStale { return }

        let hadLoadedData: Bool = {
            if case .loaded = state { return true }
            return false
        }()

        if !hadLoadedData {
            // Keep unavailable message visible while re-checking rather than a spinner flash
            // after the first setup diagnosis — only spin from idle.
            if case .idle = state {
                state = .loading
            } else if case .failed = state {
                state = .loading
            }
        }

        isRefreshing = true
        lastFetchAttemptAt = Date()

        fetchTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRefreshing = false
                    self.fetchTask = nil
                }
            }

            let result = await Task.detached(priority: .utility) {
                await Self.fetchInBackground()
            }.value

            guard let self, !Task.isCancelled else { return }
            await self.apply(result: result, hadLoadedData: hadLoadedData)
        }
    }

    private func loadCacheIntoState() {
        guard let cached = UsageCache.load() else { return }
        if identity == nil, let email = cached.email {
            identity = AuthIdentity(
                email: email,
                teamID: nil,
                principalType: nil,
                authMode: nil,
                accessToken: "",
                expiresAt: nil,
                tier: cached.snapshot.subscriptionTier
            )
        }
        if case .loaded = state { return }
        // Cache is only a bootstrap; a missing auth file on first live fetch will
        // replace this with a clear unavailable state.
        state = .loaded(cached.snapshot)
    }

    private func apply(
        result: BackgroundFetch,
        hadLoadedData: Bool
    ) async {
        // Status page is independent of auth — always take the latest successful snapshot.
        if let status = result.serviceStatus {
            self.serviceStatus = status
        }

        switch result.usage {
        case .success(let (identity, snapshot)):
            self.identity = identity
            self.state = .loaded(snapshot)
            self.lastError = nil
            UsageCache.save(snapshot, email: identity.email)

        case .failure(let error):
            let classified = classify(error, outage: result.serviceStatus)
            self.lastError = classified.menuMessage

            switch classified.kind {
            case .setup:
                // Auth gone / never signed in: don't keep showing a stale percentage.
                self.identity = nil
                self.state = .unavailable(title: classified.menuMessage, hint: classified.hint)
                UsageCache.clear()

            case .transient:
                // Keep last good snapshot in the bar; only fail hard with no data.
                if !hadLoadedData {
                    if case .loaded = state {
                        // keep
                    } else {
                        state = .failed(classified.menuMessage)
                    }
                }

            case .hard:
                if !hadLoadedData {
                    if case .loaded = state {
                        // keep
                    } else {
                        state = .failed(classified.menuMessage)
                    }
                }
            }
        }
    }

    private enum FailureKind {
        case setup
        case transient
        case hard
    }

    private struct ClassifiedError {
        var kind: FailureKind
        var menuMessage: String
        var hint: String
    }

    private func classify(_ error: Error, outage: ServiceStatusSnapshot?) -> ClassifiedError {
        let outageHint: String? = {
            guard let outage, outage.hasActiveIncident else { return nil }
            return "xAI status: \(outage.headline). See status.x.ai"
        }()

        if let auth = error as? AuthStoreError {
            var hint = auth.recoveryHint
            if let outageHint, !auth.isSetupIssue {
                hint = outageHint
            }
            return ClassifiedError(
                kind: auth.isSetupIssue ? .setup : .transient,
                menuMessage: auth.errorDescription ?? "Not signed in to Grok.",
                hint: hint
            )
        }
        if let fetch = error as? UsageFetcherError {
            if fetch.isAuthIssue {
                return ClassifiedError(
                    kind: .setup,
                    menuMessage: "Grok session expired.",
                    hint: "Run `grok login` again. GrokBar will recover on the next check."
                )
            }
            if fetch.isTransient {
                return ClassifiedError(
                    kind: .transient,
                    menuMessage: outageHint != nil
                        ? "Usage unreachable (possible outage)."
                        : (fetch.errorDescription ?? "Network error."),
                    hint: outageHint ?? "Will retry automatically."
                )
            }
            return ClassifiedError(
                kind: .hard,
                menuMessage: fetch.errorDescription ?? "Couldn’t load usage.",
                hint: outageHint ?? "Will retry automatically."
            )
        }
        return ClassifiedError(
            kind: .transient,
            menuMessage: error.localizedDescription,
            hint: outageHint ?? "Will retry automatically."
        )
    }

    private struct BackgroundFetch: Sendable {
        var usage: Result<(AuthIdentity, UsageSnapshot), Error>
        var serviceStatus: ServiceStatusSnapshot?
    }

    private nonisolated static func fetchInBackground() async -> BackgroundFetch {
        async let statusTask: ServiceStatusSnapshot? = {
            try? await StatusFetcher.fetch()
        }()

        let usage: Result<(AuthIdentity, UsageSnapshot), Error>
        do {
            var identity = try await AuthStore.loadValidIdentity()

            do {
                let snapshot = try await UsageFetcher.fetch(
                    token: identity.accessToken,
                    subscriptionTier: identity.tier
                )
                usage = .success((identity, snapshot))
            } catch let fetch as UsageFetcherError {
                if case .unauthorized = fetch {
                    // Token rejected — try one refresh, then surface session expiry cleanly.
                    do {
                        let cred = try AuthStore.loadCredential()
                        let refreshed = try await AuthStore.refreshCredential(cred)
                        identity = refreshed.identity
                        let snapshot = try await UsageFetcher.fetch(
                            token: identity.accessToken,
                            subscriptionTier: identity.tier
                        )
                        usage = .success((identity, snapshot))
                    } catch let auth as AuthStoreError {
                        usage = .failure(auth)
                    } catch {
                        usage = .failure(AuthStoreError.sessionExpired)
                    }
                } else {
                    usage = .failure(fetch)
                }
            }
        } catch {
            usage = .failure(error)
        }

        let status = await statusTask
        return BackgroundFetch(usage: usage, serviceStatus: status)
    }

    func openUsagePage() {
        if let url = URL(string: "https://grok.com/?_s=usage") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBillingPage() {
        if let url = URL(string: "https://grok.com/?_s=billing") {
            NSWorkspace.shared.open(url)
        }
    }

    func openStatusPage() {
        // Prefer first incident deep-link when available; otherwise the overview.
        if let link = serviceStatus?.activeIncidents.first?.link {
            NSWorkspace.shared.open(link)
            return
        }
        NSWorkspace.shared.open(StatusFetcher.statusPageURL)
    }

    func quit() {
        stop()
        NSApp.terminate(nil)
    }

    private var currentPollInterval: TimeInterval {
        if hasActiveOutage {
            return outagePollInterval
        }
        if case .unavailable = state {
            return setupPollInterval
        }
        return backgroundPollInterval
    }

    private func scheduleBackgroundPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Re-read interval each cycle (setup / outage poll faster than healthy data).
                let interval = await MainActor.run { self?.currentPollInterval ?? 20 * 60 }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.refresh(force: true)
            }
        }
    }

    private func scheduleClockTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.clockTick = Date()
            }
        }
    }

    private func formatBar(_ snap: UsageSnapshot) -> String {
        let pct = Int(snap.usedPercent.rounded())
        if let countdown = formatCountdown(snap.resetsIn, compact: true) {
            return "\(pct)% \(countdown)"
        }
        return "\(pct)%"
    }
}
