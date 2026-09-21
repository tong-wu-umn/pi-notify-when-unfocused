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
        let hide = config.hideWhenEmpty && sessions.isEmpty
        if statusItem.isVisible == hide { statusItem.isVisible = !hide }
        if force || title != lastTitle {
            lastTitle = title
            statusItem.button?.attributedTitle = attributedTitle(title, sessions: sessions)
        }
        statusItem.button?.toolTip = tooltip(sessions)
        if isMenuOpen { rebuildMenu() }
    }

    /// One colour per state so the item reads at a glance; the glyphs already differ, so
    /// the title stays usable when macOS overrides menu bar tinting.
    private func attributedTitle(_ title: String, sessions: [Session]) -> NSAttributedString {
        let counts = TitleFormatter.summary(sessions)
        let base = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attributed = NSMutableAttributedString(string: title, attributes: [.font: base])
        let color: NSColor
        if counts.blocked > 0 {
            color = .systemRed
        } else if counts.attention > 0 {
            color = .systemOrange
        } else if counts.working > 0 {
            color = .labelColor
        } else {
            color = .secondaryLabelColor
        }
        attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: attributed.length))
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

    private func addAction(_ title: String, _ selector: Selector, key: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        onRefresh?()
    }

    @objc private func revealLog() { onRevealLog?() }
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
