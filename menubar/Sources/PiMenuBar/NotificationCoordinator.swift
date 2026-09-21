import AppKit
import PiMenuBarCore
import UserNotifications

/// Owns PiMenuBar's native notifications: permission, delivery, reminders, and the
/// actions the user can take on them.
///
/// This is the single delivery owner. The root `notify-when-unfocused` extension routes
/// its banners through the terminal (OSC 777), which is why macOS attributes them to
/// Ghostty and why Ghostty's rate limiter and "clear on activation" apply. Posting from
/// this bundled app instead means the sender is PiMenuBar, the app is essentially never
/// frontmost (so the banner is not suppressed), and the native Focus / Mark seen actions
/// can reuse the same code as the menu rows.
///
/// The decision to alert at all lives in `PiMenuBarCore.NotificationPolicy`; this type
/// executes its actions and reports the outcome back.
@MainActor
final class NotificationCoordinator: NSObject {
    private let store: SessionStore
    private let config: () -> MenuBarConfig
    private let client: HerdrClient
    private let routesPath: String
    private let resolver = FocusResolver()

    private var policy = NotificationPolicy()
    private var routes: NotificationRouteStore
    private var candidates: [Candidate] = []
    private var active: [AttentionGeneration: Session] = [:]
    private var timer: Timer?
    private var lastConfig = NotificationConfig()
    private var center: UNUserNotificationCenter?
    private var lastStatusCheck: Date?
    /// Re-reading the authorization status more often than this is pointless and costs a
    /// call into the notification daemon on every session event.
    private let statusCheckInterval: TimeInterval = 30

    private(set) var status: NotificationStatus = .disabled

    /// Menu repaint (status line, permission state).
    var onChange: (() -> Void)?
    /// A notification action wants the session focused, exactly like clicking a row.
    var onFocusSession: ((Session) -> Void)?
    /// A notification action acknowledged a completion.
    var onAcknowledgeSession: ((Session) -> Void)?

    init(store: SessionStore, client: HerdrClient, config: @escaping () -> MenuBarConfig, routesPath: String = MenuBarConfig.notificationRoutesPath) {
        self.store = store
        self.client = client
        self.config = config
        self.routesPath = routesPath
        self.routes = NotificationRouteStore.load(path: routesPath)
        super.init()
        lastConfig = config().notifications
        policy.config = lastConfig
        status = lastConfig.enabled ? .permissionRequired : .disabled
    }

    // MARK: - Lifecycle

    func start() {
        guard lastConfig.enabled else {
            setStatus(.disabled)
            return
        }
        configureCategories()
        Task { await refreshStatus() }
    }

    /// Called for every merged-session change, every reminder deadline, and after each
    /// delivery attempt.
    func reconcile() {
        let notifications = config().notifications
        if notifications != lastConfig {
            let wasEnabled = lastConfig.enabled
            lastConfig = notifications
            policy.config = notifications
            // Any change re-baselines: a settings edit must never replay old waits.
            policy.reset()
            cancelTimer()
            active.removeAll()
            candidates.removeAll()
            if !notifications.enabled {
                removeEverything()
                setStatus(.disabled)
                return
            }
            if !wasEnabled {
                configureCategories()
                Task { await refreshStatus() }
            }
        }

        guard notifications.enabled else {
            setStatus(.disabled)
            return
        }

        candidates = NotificationPolicy.candidates(
            sessions: store.sessions,
            acknowledgements: store.acknowledgements.entries,
            config: notifications
        )
        active = [:]  // rebuilt below; duplicate keys must not be able to crash the app
        for candidate in candidates {
            active[candidate.generation] = candidate.session
        }

        let outcome = policy.reconcile(candidates: candidates, now: Date())
        if outcome.didPrime {
            Log.shared.info("notifications: baseline established (\(candidates.count) waiting, none alerted)")
        }
        for action in outcome.actions {
            switch action {
            case let .cancel(generation):
                removeNotification(for: generation)
            case let .attempt(attempt):
                Task { await deliver(attempt) }
            }
        }
        refreshStatusIfStale()
        reschedule()
    }

    // MARK: - Delivery

    private func deliver(_ attempt: NotificationPolicy.Attempt) async {
        let notifications = config().notifications
        guard notifications.enabled, let session = active[attempt.generation] else {
            policy.recordAttempt(attempt.generation, delivered: false, now: Date())
            reschedule()
            return
        }

        if status == .permissionRequired {
            await requestAuthorization()
        }
        guard status.canDeliver else {
            // Denied or not yet granted: consume the attempt rather than retrying in a
            // loop, and let the menu explain why nothing appeared.
            policy.recordAttempt(attempt.generation, delivered: false, now: Date())
            reschedule()
            return
        }

        let verdict = await resolver.resolve(
            session: session,
            defaultTerminalBundleId: config().terminalBundleId,
            preciseFocus: notifications.preciseFocus,
            herdrFresh: client.snapshotIsFresh,
            selectedPaneId: client.snapshot?.focusedPaneId
        )

        // The focus probe is asynchronous: the prompt may have been answered, the app
        // disabled, or another alert delivered while it ran.
        guard active[attempt.generation] != nil,
              config().notifications.enabled,
              policy.authorize(attempt, now: Date())
        else {
            policy.recordAttempt(attempt.generation, delivered: false, now: Date())
            reschedule()
            return
        }

        if verdict.focused {
            Log.shared.debug("notifications: quiet \(attempt.generation.kind.rawValue) for \(session.label) — \(verdict.reason)")
            policy.recordAttempt(attempt.generation, delivered: false, now: Date())
        } else {
            post(attempt, session: session, verdict: verdict)
            policy.recordAttempt(attempt.generation, delivered: true, now: Date())
        }
        reschedule()
    }

    private func post(_ attempt: NotificationPolicy.Attempt, session: Session, verdict: FocusVerdict) {
        guard let center = centerIfSupported() else { return }
        let route = routes.ensureRoute(for: attempt.generation, session: session, now: Date())
        routes.prune(now: Date())
        if !routes.write(to: routesPath) {
            Log.shared.warn("notifications: could not persist routes to \(routesPath)")
        }

        let content = UNMutableNotificationContent()
        content.title = attempt.content.title
        content.body = attempt.content.body
        content.categoryIdentifier = attempt.content.category
        content.userInfo = route.userInfo
        if config().notifications.sound { content.sound = .default }

        center.add(UNNotificationRequest(identifier: route.requestId, content: content, trigger: nil)) { error in
            if let error {
                Log.shared.warn("notifications: could not post: \(error.localizedDescription)")
            }
        }
        Log.shared.info(
            "notifications: posted \(attempt.generation.kind.rawValue)\(attempt.isReminder ? " reminder" : "") for \(session.label) (\(verdict.reason))"
        )
    }

    /// Removes a banner whose wait is over: answered prompt, acknowledged completion,
    /// session gone, or notifications switched off.
    private func removeNotification(for generation: AttentionGeneration) {
        guard let route = routes.remove(generation: generation) else { return }
        routes.write(to: routesPath)
        guard let center = centerIfSupported() else { return }
        center.removeDeliveredNotifications(withIdentifiers: [route.requestId])
        center.removePendingNotificationRequests(withIdentifiers: [route.requestId])
    }

    private func removeEverything() {
        cancelTimer()
        let hadRoutes = !routes.routes.isEmpty
        routes = NotificationRouteStore()
        if hadRoutes { routes.write(to: routesPath) }
        guard let center = centerIfSupported() else { return }
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    // MARK: - Deadlines

    private func reschedule() {
        cancelTimer()
        guard config().notifications.enabled, let deadline = policy.nextDeadline else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        timer.tolerance = 0.2
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Permission

    private func configureCategories() {
        guard let center = centerIfSupported() else {
            setStatus(.unsupported)
            return
        }
        let focus = UNNotificationAction(
            identifier: NotificationActionIdentifier.focus,
            title: "Focus session",
            options: [.foreground]
        )
        let seen = UNNotificationAction(identifier: NotificationActionIdentifier.seen, title: "Mark seen")
        center.setNotificationCategories([
            // A blocked prompt is only actionable by looking at it, so "Mark seen" is not
            // offered; both categories report a dismissal.
            UNNotificationCategory(
                identifier: NotificationCategory.prompt,
                actions: [focus],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(
                identifier: NotificationCategory.completion,
                actions: [focus, seen],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(identifier: NotificationCategory.test, actions: [], intentIdentifiers: [], options: []),
        ])
    }

    /// Requests authorization. Only called when the user enabled notifications and an
    /// alert is actually due, or from the menu's test item.
    func requestAuthorization() async {
        guard let center = centerIfSupported() else {
            setStatus(.unsupported)
            return
        }
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.shared.warn(
                "notifications: could not ask for permission (\(error.localizedDescription)); enable PiMenuBar in System Settings → Notifications"
            )
            granted = false
        }
        Log.shared.info("notifications: authorization \(granted ? "granted" : "not granted")")
        await refreshStatus()
    }

    /// Sends a banner immediately, requesting authorization first when needed.
    func sendTestNotification() async {
        guard config().notifications.enabled else { return }
        if status == .permissionRequired { await requestAuthorization() }
        guard status.canDeliver, let center = centerIfSupported() else { return }
        let content = UNMutableNotificationContent()
        let test = NotificationContentBuilder.testContent()
        content.title = test.title
        content.body = test.body
        content.categoryIdentifier = test.category
        if config().notifications.sound { content.sound = .default }
        let identifier = NotificationContentBuilder.requestIdPrefix + "test"
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            Log.shared.info("notifications: test notification posted")
        } catch {
            Log.shared.warn("notifications: could not post test notification: \(error.localizedDescription)")
        }
    }

    /// The user can change the authorization in System Settings while the app runs, so
    /// the cached verdict is refreshed occasionally — but not on every session event.
    private func refreshStatusIfStale() {
        if let last = lastStatusCheck, Date().timeIntervalSince(last) < statusCheckInterval { return }
        Task { await refreshStatus() }
    }

    private func refreshStatus() async {
        lastStatusCheck = Date()
        guard config().notifications.enabled else {
            setStatus(.disabled)
            return
        }
        guard let center = centerIfSupported() else {
            setStatus(.unsupported)
            return
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied: setStatus(.denied)
        case .notDetermined: setStatus(.permissionRequired)
        default: setStatus(.ready)
        }
    }

    private func setStatus(_ newStatus: NotificationStatus) {
        guard newStatus != status else { return }
        status = newStatus
        // Menu bar apps have no window to explain themselves in, so every permission
        // transition is worth one log line.
        Log.shared.info("notifications: \(newStatus.rawValue)")
        onChange?()
    }

    /// `UNUserNotificationCenter.current()` requires a bundle identifier; `swift run`
    /// from a bare executable would trap, so the app never touches it unless it is
    /// running as a bundle. `--probe` never reaches this type at all.
    private func centerIfSupported() -> UNUserNotificationCenter? {
        if let center { return center }
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let created = UNUserNotificationCenter.current()
        created.delegate = self
        center = created
        return center
    }

    // MARK: - Actions

    fileprivate func handle(actionIdentifier: String, routeId: String?) {
        guard let routeId, let route = routes[routeId] else { return }
        switch actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            // Dismissing means "stop nagging me about this wait". It is explicitly not
            // proof that the user looked at the session, so the badge stays.
            if let generation = route.generation {
                policy.stopReminders(generation)
            }
            routes.remove(id: routeId)
            routes.write(to: routesPath)
            reschedule()
        case UNNotificationDefaultActionIdentifier, NotificationActionIdentifier.focus:
            guard let session = store.session(for: route.sessionKey) else {
                Log.shared.info("notifications: session for route \(route.id) is gone")
                return
            }
            onFocusSession?(session)
        case NotificationActionIdentifier.seen:
            guard let session = store.session(for: route.sessionKey) else {
                Log.shared.info("notifications: session for route \(route.id) is gone")
                return
            }
            onAcknowledgeSession?(session)
        default:
            break
        }
    }
}

extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    /// `UNUserNotificationCenterDelegate` callbacks are not main-actor isolated, and the
    /// completion handlers are not `Sendable`, so nothing here hops actors while holding
    /// one. The presentation options are derived from the notification itself (`sound` is
    /// already baked into the content), which keeps the callback fully synchronous.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Only `String`s cross the actor boundary; the handler is answered on this thread
        // after the hop has been queued, so the system is never kept waiting on a focus
        // action or a disk write.
        let actionIdentifier = response.actionIdentifier
        let routeId = response.notification.request.content.userInfo[NotificationRouteStore.userInfoKey] as? String
        Task { @MainActor in
            self.handle(actionIdentifier: actionIdentifier, routeId: routeId)
        }
        completionHandler()
    }
}
