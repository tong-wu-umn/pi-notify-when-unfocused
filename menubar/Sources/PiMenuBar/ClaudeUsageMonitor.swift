import Foundation
import PiMenuBarCore

enum ClaudeUsageFetchError: Error, Equatable {
    case http(Int)
    case network(String)
    case invalidResponse
}

/// One HTTPS GET against the endpoint the `/usage` screen uses. No token is ever logged.
///
/// The session is ephemeral on purpose: no cookies, no cached response, no shared state
/// with the rest of the app.
enum ClaudeUsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    static func request(token: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        request.setValue("PiMenuBar/\(version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func fetch(token: String, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request(token: token))
            switch validate(data: data, response: response) {
            case let .success(data): return data
            case let .failure(error): throw error
            }
        } catch let error as ClaudeUsageFetchError {
            throw error
        } catch {
            throw ClaudeUsageFetchError.network(error.localizedDescription)
        }
    }

    /// The probe runs before AppKit's run loop, so it uses a blocking bridge rather than
    /// an async entry point (which would complicate `main.swift`).
    static func fetchSync(token: String) -> Result<Data, ClaudeUsageFetchError> {
        let box = FetchBox()
        let semaphore = DispatchSemaphore(value: 0)
        let session = makeSession()
        let task = session.dataTask(with: request(token: token)) { data, response, error in
            if let error {
                box.set(.failure(.network(error.localizedDescription)))
            } else {
                box.set(validate(data: data, response: response))
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return .failure(.network("timed out"))
        }
        session.finishTasksAndInvalidate()
        return box.get() ?? .failure(.network("no response"))
    }

    private static func validate(data: Data?, response: URLResponse?) -> Result<Data, ClaudeUsageFetchError> {
        guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
        guard (200..<300).contains(http.statusCode) else { return .failure(.http(http.statusCode)) }
        guard let data else { return .failure(.network("empty response")) }
        return .success(data)
    }
}

/// The URLSession completion handler is `@Sendable`, so the result crosses back through a
/// locked box instead of captured mutable locals.
private final class FetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, ClaudeUsageFetchError>?

    func set(_ result: Result<Data, ClaudeUsageFetchError>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() -> Result<Data, ClaudeUsageFetchError>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// What the menu and title should show. Stale values stay on screen with the reason they
/// are old; a failure with no cached value gets `unavailable` rather than a fake zero.
enum ClaudeUsageState: Sendable, Equatable {
    case disabled
    case noCredentials
    case fresh(ClaudeUsageSnapshot)
    case stale(ClaudeUsageSnapshot, note: String)
    case unavailable(note: String)

    var snapshot: ClaudeUsageSnapshot? {
        switch self {
        case .disabled, .noCredentials, .unavailable: return nil
        case let .fresh(snapshot): return snapshot
        case let .stale(snapshot, _): return snapshot
        }
    }
}

/// Owns the timer and the request. Rendering and the keychain stay elsewhere.
@MainActor
final class ClaudeUsageMonitor {
    private(set) var state: ClaudeUsageState = .disabled
    var onChange: (() -> Void)?

    private let config: () -> MenuBarConfig
    private var timer: Timer?
    private var session: URLSession?
    private var refreshTask: Task<Void, Never>?
    private var lastSnapshot: ClaudeUsageSnapshot?
    private var lastAttempt: Date?
    private var isRunning = false
    private var isRefreshing = false

    /// Menu-open refreshes never happen more often than this, so opening the menu a few
    /// times in a row cannot turn into a burst of keychain and network calls.
    private let minimumRefreshGap: TimeInterval = 60

    init(config: @escaping () -> MenuBarConfig) {
        self.config = config
    }

    /// Cache first (instant), then one live refresh, then the timer. Disabled means no
    /// keychain access at all: the user has not opted in yet.
    func start() {
        guard !isRunning else { return }
        lastSnapshot = ClaudeUsageCache.load()
        guard config().claudeUsage.enabled else {
            state = .disabled
            onChange?()
            return
        }
        isRunning = true
        session = ClaudeUsageClient.makeSession()
        state = lastSnapshot.map { .fresh($0) } ?? .unavailable(note: "waiting for first refresh")
        scheduleTimer()
        onChange?()
        refresh()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        session?.invalidateAndCancel()
        session = nil
        isRefreshing = false
    }

    /// Called on every config reload. Enabling starts the poll and asks for the keychain
    /// once; disabling stops both immediately.
    func reconfigure() {
        guard config().claudeUsage.enabled else {
            stop()
            state = .disabled
            onChange?()
            return
        }
        if isRunning {
            scheduleTimer()
        } else {
            start()
        }
    }

    /// Menu-open hook: refresh only when the numbers are older than `maxAge`, and never
    /// sooner than the minimum gap after the previous attempt.
    func refreshIfStale(maxAge: TimeInterval) {
        guard isRunning, config().claudeUsage.enabled else { return }
        let now = Date()
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumRefreshGap { return }
        if let fetchedAt = lastSnapshot?.fetchedAt, now.timeIntervalSince(fetchedAt) < maxAge { return }
        refresh()
    }

    /// Explicit "Refresh usage now": bypasses the staleness check but not an in-flight
    /// request.
    func refreshNow() {
        guard config().claudeUsage.enabled else { return }
        refresh()
    }

    private func refresh() {
        guard isRunning, config().claudeUsage.enabled, !isRefreshing else { return }
        lastAttempt = Date()
        isRefreshing = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        defer {
            isRefreshing = false
            refreshTask = nil
            // Repaint even on failure so a note ("offline", "re-authenticate") lands.
            onChange?()
        }

        let usageConfig = config().claudeUsage
        let credential: ClaudeCredential.Value
        switch ClaudeCredential.load() {
        case let .success(value):
            credential = value
        case let .failure(failure):
            switch failure {
            case .notFound:
                update(lastSnapshot.map { .stale($0, note: "no credentials") } ?? .noCredentials)
                Log.shared.debug("claude usage: no Claude Code credentials in the keychain")
            case .malformed:
                update(lastSnapshot.map { .stale($0, note: "credentials unreadable") }
                    ?? .unavailable(note: "credentials unreadable"))
                Log.shared.warn("claude usage: keychain credentials are malformed")
            case let .unreadable(status):
                update(lastSnapshot.map { .stale($0, note: "keychain error \(status)") }
                    ?? .unavailable(note: "keychain error \(status)"))
                Log.shared.warn("claude usage: keychain read failed (\(status))")
            }
            return
        }

        // Refreshing the token ourselves would consume the CLI's single-use refresh token
        // and could log it out. Report it and let the CLI rotate the value.
        if credential.isExpired {
            update(lastSnapshot.map { .stale($0, note: "token expired — open Claude Code") }
                ?? .unavailable(note: "token expired — open Claude Code"))
            Log.shared.info("claude usage: access token expired; not refreshing")
            return
        }

        let session = session ?? ClaudeUsageClient.makeSession()
        let data: Data
        do {
            data = try await ClaudeUsageClient.fetch(token: credential.token, session: session)
        } catch let error as ClaudeUsageFetchError {
            guard isRunning else { return }
            if case let .http(code) = error, code == 401 {
                // The CLI may have rotated the token since this process started. Re-read
                // the keychain exactly once; do not loop on a genuinely bad token.
                if case let .success(renewed) = ClaudeCredential.load(),
                   renewed.token != credential.token,
                   !renewed.isExpired {
                    do {
                        let retried = try await ClaudeUsageClient.fetch(token: renewed.token, session: session)
                        apply(data: retried, warningPercent: usageConfig.warningPercent)
                        return
                    } catch let retryError as ClaudeUsageFetchError {
                        fail(retryError, context: "after token re-read")
                        return
                    } catch {
                        fail(.network(error.localizedDescription), context: "after token re-read")
                        return
                    }
                }
            }
            fail(error, context: nil)
            return
        } catch {
            guard isRunning else { return }
            fail(.network(error.localizedDescription), context: nil)
            return
        }

        guard isRunning else { return }
        apply(data: data, warningPercent: usageConfig.warningPercent)
    }

    private func apply(data: Data, warningPercent: Int) {
        guard isRunning else { return }
        do {
            let snapshot = try ClaudeUsageParser.parse(data, now: Date(), warningPercent: warningPercent)
            lastSnapshot = snapshot
            update(.fresh(snapshot))
            ClaudeUsageCache.save(snapshot)
            Log.shared.info("claude usage: \(describe(snapshot))")
        } catch {
            update(lastSnapshot.map { .stale($0, note: "unexpected response") }
                ?? .unavailable(note: "unexpected response"))
            Log.shared.warn("claude usage: response was not JSON")
        }
    }

    private func fail(_ error: ClaudeUsageFetchError, context: String?) {
        let suffix = context.map { " (\($0))" } ?? ""
        let note: String
        switch error {
        case let .http(code) where code == 401:
            note = "re-authenticate"
        case let .http(code) where code == 429 || (500..<600).contains(code):
            note = "offline"
        case let .http(code):
            note = "HTTP \(code)"
        case .network:
            note = "offline"
        case .invalidResponse:
            note = "unexpected response"
        }
        update(lastSnapshot.map { .stale($0, note: note) } ?? .unavailable(note: note))
        let message = "claude usage: \(note)\(suffix) — \(error)"
        if case .http(401) = error {
            Log.shared.warn(message)
        } else {
            Log.shared.debug(message)
        }
    }

    private func update(_ newState: ClaudeUsageState) {
        guard isRunning else { return }
        state = newState
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(config().claudeUsage.refreshIntervalMs) / 1000
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval * 0.1
        self.timer = timer
    }

    private func describe(_ snapshot: ClaudeUsageSnapshot) -> String {
        let session = snapshot.session.map { "5h \($0.percent)% (\($0.severity.rawValue))" } ?? "5h -"
        let weekly = snapshot.weekly.map { "7d \($0.percent)% (\($0.severity.rawValue))" } ?? "7d -"
        return "\(session) · \(weekly)"
    }
}
