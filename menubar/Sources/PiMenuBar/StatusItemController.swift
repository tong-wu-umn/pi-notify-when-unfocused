import AppKit
import PiMenuBarCore

/// Owns the status item, its title, and the dropdown.
///
/// Rendering rules live in `PiMenuBarCore.TitleFormatter` so they are unit tested; this
/// type only turns them into AppKit objects and keeps the rebuild rate bounded (herdr can
/// emit events far faster than a menu bar should repaint).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let store: SessionStore
    private let config: () -> MenuBarConfig
    private let client: HerdrClient
    private let acknowledgements: () -> AcknowledgementStore
    private var lastTitle: String?
    private var pendingRender: DispatchWorkItem?
    private var durationTimer: Timer?
    private var isMenuOpen = false

    var onRefresh: (() -> Void)?
    var onToggleSimulated: (() -> Void)?
    var onRevealLog: (() -> Void)?
    var onRevealConfig: (() -> Void)?
    var onRevealRegistry: (() -> Void)?
    var onFocus: ((Session) -> Void)?
    var onAcknowledge: ((Session) -> Void)?
    var notificationStatus: (() -> NotificationStatus)?
    var onTestNotification: (() -> Void)?
    var onOpenNotificationSettings: (() -> Void)?
    var claudeUsage: (() -> ClaudeUsageState)?
    var onRefreshClaudeUsage: (() -> Void)?
    /// Menu-open hook for a bounded usage refresh (the monitor applies the min-gap).
    var onMenuOpened: (() -> Void)?

    init(store: SessionStore, client: HerdrClient, config: @escaping () -> MenuBarConfig, acknowledgements: @escaping () -> AcknowledgementStore) {
        self.store = store
        self.client = client
        self.config = config
        self.acknowledgements = acknowledgements
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .noImage
        render(force: true)
    }

    // MARK: - Title

    /// Coalesces bursts of updates to at most ~4 renders per second.
    func scheduleRender() {
        guard pendingRender == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRender = nil
            self?.render(force: false)
        }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func render(force: Bool) {
        let config = self.config()
        let sessions = store.sessions
        let title = TitleFormatter.title(sessions, showIdle: config.showIdle)
        let usage = usageTitle(config: config)
        let displayTitle = usage.map { "\(title) · \($0.suffix)" } ?? title
        let renderKey = "\(displayTitle)|\(usage?.severity.rawValue ?? "none")"
        let hide = config.hideWhenEmpty && sessions.isEmpty
        if statusItem.isVisible == hide { statusItem.isVisible = !hide }
        if force || renderKey != lastTitle {
            lastTitle = renderKey
            statusItem.button?.attributedTitle = attributedTitle(
                displayTitle,
                baseTitle: title,
                usage: usage
            )
        }
        statusItem.button?.toolTip = tooltip(sessions)
        if isMenuOpen { rebuildMenu() }
    }

    /// `π 2▶ · 78%`, but only when both the config and a snapshot allow it.
    private func usageTitle(config: MenuBarConfig) -> (suffix: String, severity: ClaudeUsageLimit.Severity)? {
        guard config.claudeUsage.showInTitle,
              let snapshot = claudeUsage?().snapshot
        else { return nil }
        let suffix = ClaudeUsageFormat.titleSuffix(snapshot)
        guard !suffix.isEmpty else { return nil }
        return (suffix, ClaudeUsageFormat.titleSeverity(snapshot))
    }

    /// One colour per state so the item reads at a glance; the glyphs already differ, so
    /// the title stays usable when the colour is unavailable.
    ///
    /// Neutral states carry **no** foreground colour on purpose. A colour set inside
    /// `attributedTitle` is drawn verbatim — AppKit re-tints a plain status item title
    /// for the menu bar's appearance, but not an attributed one. `labelColor` and
    /// `secondaryLabelColor` therefore resolved against the app's appearance instead of
    /// the bar's and came out near-black on a tinted (dark/blue) menu bar: barely
    /// visible. Leaving the attribute off makes AppKit draw the text exactly like a
    /// plain status item title, so it matches the neighbouring system items in every
    /// appearance. Alert states keep their explicit colour: they read on both light and
    /// dark bars, and being seen is the entire point of them.
    private func attributedTitle(
        _ title: String,
        baseTitle: String,
        usage: (suffix: String, severity: ClaudeUsageLimit.Severity)?
    ) -> NSAttributedString {
        let counts = TitleFormatter.summary(store.sessions)
        let base = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attributed = NSMutableAttributedString(string: title, attributes: [.font: base])
        let alert: NSColor?
        if counts.blocked > 0 {
            alert = .systemRed
        } else if counts.attention > 0 {
            alert = .systemOrange
        } else {
            alert = nil
        }
        if let alert {
            attributed.addAttribute(
                .foregroundColor,
                value: alert,
                range: NSRange(location: 0, length: (baseTitle as NSString).length)
            )
        }
        // Only the usage tail gets a severity colour; the rest of the title keeps the
        // "no colour unless alerting" rule described above.
        if let usage, usage.severity != .normal {
            let start = (baseTitle as NSString).length
            attributed.addAttribute(
                .foregroundColor,
                value: usage.severity == .critical ? NSColor.systemRed : NSColor.systemOrange,
                range: NSRange(location: start, length: attributed.length - start)
            )
        }
        return attributed
    }

    private func tooltip(_ sessions: [Session]) -> String {
        var lines = [TitleFormatter.tooltip(sessions, now: Date())]
        if let message = client.status.message {
            lines.append("herdr: \(message)")
        }
        if !client.status.available {
            lines.append("herdr: unavailable — showing registry data only")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        startDurationTimer()
        onMenuOpened?()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        durationTimer?.invalidate()
        durationTimer = nil
    }

    /// Durations in an open menu tick once per second; nothing else refreshes while open.
    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isMenuOpen else { return }
                self.rebuildMenu()
            }
        }
    }

    private func rebuildMenu() {
        let config = self.config()
        let sessions = store.sessions
        let now = Date()
        menu.removeAllItems()

        let header = TitleFormatter.tooltip(sessions, now: now)
        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No active pi sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            var rows = 0
            var truncated = 0
            for group in SessionGrouping.groups(sessions) {
                let groupItem = NSMenuItem(title: group.title.uppercased(), action: nil, keyEquivalent: "")
                groupItem.isEnabled = false
                menu.addItem(groupItem)
                for tab in group.tabs {
                    if group.tabs.count > 1 {
                        let tabItem = NSMenuItem(title: "   \(tab.title)", action: nil, keyEquivalent: "")
                        tabItem.isEnabled = false
                        menu.addItem(tabItem)
                    }
                    for session in tab.sessions {
                        if rows >= config.maxRows { truncated += 1; continue }
                        rows += 1
                        menu.addItem(row(for: session, now: now))
                    }
                }
            }
            if truncated > 0 {
                let more = NSMenuItem(title: "\(truncated) more session\(truncated == 1 ? "" : "s")…", action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }
            if client.status.usableSocketCount > 1 {
                let warn = NSMenuItem(title: "⚠ multiple herdr sockets; using \(client.status.socketSource ?? "?")", action: nil, keyEquivalent: "")
                warn.isEnabled = false
                menu.addItem(warn)
            }
            if !client.status.available, let message = client.status.message {
                let warn = NSMenuItem(title: "⚠ herdr: \(message)", action: nil, keyEquivalent: "")
                warn.isEnabled = false
                menu.addItem(warn)
            }
        }

        menu.addItem(.separator())
        addNotificationItems()
        addClaudeUsageItems()
        addAction("Refresh now", #selector(refreshNow), key: "r")
        addAction("Open config…", #selector(revealConfig), key: "")
        addAction("Open registry folder", #selector(revealRegistry), key: "")
        addAction("Open log", #selector(revealLog), key: "")
        menu.addItem(.separator())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "PiMenuBar \(version) — \(sessions.count) session\(sessions.count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        addAction("Quit PiMenuBar", #selector(quit), key: "q")
    }

    private func row(for session: Session, now: Date) -> NSMenuItem {
        let item = NSMenuItem(title: TitleFormatter.rowTitle(session, now: now), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let focus = NSMenuItem(title: "Focus and acknowledge", action: #selector(focusSession(_:)), keyEquivalent: "")
        focus.target = self
        focus.representedObject = session.key
        focus.isEnabled = session.herdr != nil
        submenu.addItem(focus)

        let details = NSMenuItem(title: "Show details…", action: #selector(showDetails(_:)), keyEquivalent: "")
        details.target = self
        details.representedObject = session.key
        submenu.addItem(details)

        if session.state == .done {
            let mark = NSMenuItem(title: "Mark completed seen", action: #selector(acknowledgeSession(_:)), keyEquivalent: "")
            mark.target = self
            mark.representedObject = session.key
            submenu.addItem(mark)
        }

        submenu.addItem(.separator())
        if let file = session.sessionFile {
            let copySession = NSMenuItem(title: "Copy session path", action: #selector(copyValue(_:)), keyEquivalent: "")
            copySession.target = self
            copySession.representedObject = file
            submenu.addItem(copySession)
        }
        let copyCwd = NSMenuItem(title: "Copy working directory", action: #selector(copyValue(_:)), keyEquivalent: "")
        copyCwd.target = self
        copyCwd.representedObject = session.cwd
        submenu.addItem(copyCwd)
        if let pane = session.herdr?.paneId {
            let copyPane = NSMenuItem(title: "Copy pane id", action: #selector(copyValue(_:)), keyEquivalent: "")
            copyPane.target = self
            copyPane.representedObject = pane
            submenu.addItem(copyPane)
        }

        item.submenu = submenu
        item.toolTip = TitleFormatter.detailText(session, now: now)
        if session.needsAttention {
            item.attributedTitle = NSAttributedString(
                string: TitleFormatter.rowTitle(session, now: now),
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        return item
    }

    /// Notification state, test delivery, and a way into System Settings. Kept in the
    /// menu (not only in the log) because "why did I not get a banner" is otherwise
    /// invisible for an accessory app with no window.
    private func addNotificationItems() {
        let status = notificationStatus?() ?? .disabled
        let line = NSMenuItem(title: "Notifications: \(status.label)", action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)

        let test = NSMenuItem(title: "Send test notification", action: #selector(testNotification), keyEquivalent: "")
        test.target = self
        test.isEnabled = status.canRequestPermission
        menu.addItem(test)

        addAction("Open Notification Settings…", #selector(openNotificationSettings), key: "")
    }

    private func addAction(_ title: String, _ selector: Selector, key: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    /// `Claude Code usage — 12:46` plus one disabled row per limit. The section disappears
    /// entirely when the feature is off, so an upgrade never adds a row nobody asked for.
    private func addClaudeUsageItems() {
        guard let state = claudeUsage?(), state != .disabled else { return }
        menu.addItem(.separator())

        let header = NSMenuItem(title: claudeUsageHeader(state), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let snapshot = state.snapshot {
            let lines = ClaudeUsageFormat.menuLines(snapshot, now: Date())
            if lines.isEmpty {
                let none = NSMenuItem(title: "no limits reported by the API", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for (text, severity) in lines {
                // A real (no-op) action keeps `autoenablesItems` from disabling the row;
                // disabled menu text is dimmed, which made the orange nearly invisible.
                let item = NSMenuItem(title: text, action: #selector(usageRowNoop), keyEquivalent: "")
                item.target = self
                // Monospaced so the padded percent and reset columns actually line up.
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                ]
                if let color = usageColor(severity) {
                    attributes[.foregroundColor] = color
                }
                item.attributedTitle = NSAttributedString(string: text, attributes: attributes)
                menu.addItem(item)
            }
        }

        addAction("Refresh usage now", #selector(refreshClaudeUsage), key: "")
    }

    private func claudeUsageHeader(_ state: ClaudeUsageState) -> String {
        switch state {
        case .disabled:
            return ""
        case .noCredentials:
            return "Claude Code usage — no credentials (open Claude Code once)"
        case let .fresh(snapshot):
            return "Claude Code usage — \(clock(snapshot.fetchedAt))"
        case let .stale(snapshot, note):
            return "Claude Code usage — \(clock(snapshot.fetchedAt)) · \(note)"
        case let .unavailable(note):
            return "Claude Code usage — \(note)"
        }
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Warning/critical text needs a darker ink on the light menu background. The system
    /// orange/red are tuned for the dark menu bar and wash out on light gray; keep the
    /// vivid system colours for dark appearance, where they read well.
    private func usageColor(_ severity: ClaudeUsageLimit.Severity) -> NSColor? {
        func isDark(_ appearance: NSAppearance) -> Bool {
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        switch severity {
        case .normal:
            return nil
        case .warning:
            return NSColor(name: nil) { appearance in
                isDark(appearance)
                    ? NSColor.systemOrange
                    : NSColor(srgbRed: 0.60, green: 0.20, blue: 0.02, alpha: 1)
            }
        case .critical:
            return NSColor(name: nil) { appearance in
                isDark(appearance)
                    ? NSColor.systemRed
                    : NSColor(srgbRed: 0.72, green: 0.11, blue: 0.11, alpha: 1)
            }
        }
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        onRefresh?()
    }

    @objc private func refreshClaudeUsage() {
        onRefreshClaudeUsage?()
    }

    /// Usage rows are informational. They nevertheless need an action because a nil-action
    /// item is auto-disabled (and therefore dimmed) by `NSMenu.autoenablesItems`.
    @objc private func usageRowNoop() {}

    @objc private func revealLog() { onRevealLog?() }
    @objc private func testNotification() { onTestNotification?() }
    @objc private func openNotificationSettings() { onOpenNotificationSettings?() }
    @objc private func revealConfig() { onRevealConfig?() }
    @objc private func revealRegistry() { onRevealRegistry?() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let session = store.session(for: key) else { return }
        onFocus?(session)
    }

    @objc private func acknowledgeSession(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let session = store.session(for: key) else { return }
        onAcknowledge?(session)
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    @objc private func showDetails(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let session = store.session(for: key) else { return }
        let alert = NSAlert()
        alert.messageText = session.label
        alert.informativeText = "Merged state as PiMenuBar sees it."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = TitleFormatter.detailText(session, now: Date())
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }
}
