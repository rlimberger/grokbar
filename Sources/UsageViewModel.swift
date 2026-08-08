import AppKit
import Foundation
import ServiceManagement

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var identity: AuthIdentity?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published var launchAtLogin = false
    @Published private(set) var loginItemMessage: String?

    private var fetchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var didStart = false
    private var lastFetchAttemptAt: Date?

    /// Panel-open / opportunistic refresh threshold.
    private let staleAfter: TimeInterval = 15 * 60
    /// Background poll while awake (~72 requests/day if never sleeps).
    private let backgroundPollInterval: TimeInterval = 20 * 60

    /// Bumped every minute so the menu bar countdown stays live without a network call.
    @Published private(set) var clockTick: Date = Date()

    var menuBarTitle: String {
        // Depend on clockTick so SwiftUI re-evaluates countdown text.
        _ = clockTick
        switch state {
        case .loaded(let snap):
            return formatBar(snap)
        case .failed:
            return "!"
        case .idle, .loading:
            return "…"
        }
    }

    var menuBarAccessibilityLabel: String {
        _ = clockTick
        switch state {
        case .loaded(let snap):
            let reset = formatCountdown(snap.resetsIn) ?? "unknown"
            return "Grok \(Int(snap.usedPercent.rounded()))% used, \(snap.cycleLabel.lowercased()) pool, resets in \(reset)"
        case .failed(let message):
            return "Grok usage error: \(message)"
        default:
            return "Loading Grok usage"
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        refreshLoginItemState()
        loadCacheIntoState()
        refreshIfStale()
        scheduleBackgroundPoll()
        scheduleClockTick()
    }

    func panelDidOpen() {
        start()
        refreshLoginItemState()
        refreshIfStale()
    }

    func refreshLoginItemState() {
        launchAtLogin = LoginItemService.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            launchAtLogin = LoginItemService.isEnabled
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                loginItemMessage = "Allow Grok Usage in System Settings → General → Login Items."
            } else if enabled, !launchAtLogin {
                loginItemMessage = "Could not enable Launch at Login."
            } else {
                loginItemMessage = nil
            }
        } catch {
            launchAtLogin = LoginItemService.isEnabled
            loginItemMessage = error.localizedDescription
        }
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
        if case .loaded(let snap) = state {
            if Date().timeIntervalSince(snap.fetchedAt) < staleAfter {
                return false
            }
        }
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
            state = .loading
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
        state = .loaded(cached.snapshot)
    }

    private func apply(
        result: Result<(AuthIdentity, UsageSnapshot), Error>,
        hadLoadedData: Bool
    ) async {
        switch result {
        case .success(let (identity, snapshot)):
            self.identity = identity
            self.state = .loaded(snapshot)
            self.lastError = nil
            UsageCache.save(snapshot, email: identity.email)

        case .failure(let error):
            let message = friendlyMessage(for: error)
            self.lastError = message
            if !hadLoadedData {
                if case .loaded = state {
                    // keep cache
                } else {
                    state = .failed(message)
                }
            }
        }
    }

    private nonisolated static func fetchInBackground() async -> Result<(AuthIdentity, UsageSnapshot), Error> {
        do {
            var identity = try await AuthStore.loadValidIdentity()

            do {
                let snapshot = try await UsageFetcher.fetch(
                    token: identity.accessToken,
                    subscriptionTier: identity.tier
                )
                return .success((identity, snapshot))
            } catch let fetch as UsageFetcherError {
                if case .unauthorized = fetch {
                    let cred = try AuthStore.loadCredential()
                    let refreshed = try await AuthStore.refreshCredential(cred)
                    identity = refreshed.identity
                    let snapshot = try await UsageFetcher.fetch(
                        token: identity.accessToken,
                        subscriptionTier: identity.tier
                    )
                    return .success((identity, snapshot))
                }
                throw fetch
            }
        } catch {
            return .failure(error)
        }
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

    func quit() {
        stop()
        NSApp.terminate(nil)
    }

    private func scheduleBackgroundPoll() {
        pollTask?.cancel()
        let interval = backgroundPollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
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

    private func friendlyMessage(for error: Error) -> String {
        if let auth = error as? AuthStoreError {
            return auth.localizedDescription
        }
        if let fetch = error as? UsageFetcherError {
            return fetch.localizedDescription
        }
        return error.localizedDescription
    }
}
