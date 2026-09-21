import AppKit
import PiMenuBarCore

/// Loads `~/.pi/agent/menubar.json` and reloads it when the file changes, keeping the
/// last good value if the new one is malformed.
@MainActor
final class ConfigLoader {
    private(set) var current: MenuBarConfig
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private let path: String
    private let queue = DispatchQueue(label: "PiMenuBar.config", qos: .utility)

    var onChange: (() -> Void)?

    init(path: String = MenuBarConfig.configPath) {
        self.path = path
        current = MenuBarConfig.load(path: path)
    }

    func start() {
        let directory = (path as NSString).deletingLastPathComponent
        descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        // Nonisolated on purpose: the source fires on `queue`, so the block must not
        // inherit `@MainActor` from this class (that would trap in
        // `dispatch_assert_queue`). See RegistryWatcher for the same pattern.
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in self?.reload() }
        }
        source.setCancelHandler { @Sendable [descriptor = descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    func reload() {
        let reloaded = MenuBarConfig.load(path: path)
        guard reloaded != current else { return }
        current = reloaded
        Log.shared.configure(level: reloaded.logLevel)
        Log.shared.info("config reloaded from \(path)")
        onChange?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var configLoader: ConfigLoader!
    private var store: SessionStore!
    private var client: HerdrClient!
    private var registry: RegistryWatcher!
    private var statusItem: StatusItemController!
    private let focuser = Focuser()
    private var instanceLock: InstanceLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two status items is a bug the user cannot undo without the Dock, so refuse to
        // start twice.
        guard let lock = InstanceLock.acquire(path: MenuBarConfig.lockPath) else {
            Log.shared.warn("another PiMenuBar instance holds \(MenuBarConfig.lockPath); exiting")
            NSApp.terminate(nil)
            return
        }
        instanceLock = lock

        configLoader = ConfigLoader()
        Log.shared.configure(level: configLoader.current.logLevel)
        Log.shared.info("PiMenuBar starting (pid \(ProcessInfo.processInfo.processIdentifier))")

        store = SessionStore(config: { [weak self] in self?.configLoader.current ?? MenuBarConfig() })
        registry = RegistryWatcher(config: { [weak self] in self?.configLoader.current ?? MenuBarConfig() })
        client = HerdrClient(
            config: { [weak self] in self?.configLoader.current ?? MenuBarConfig() },
            registryRecords: { [weak self] in self?.registry.records ?? [] }
        )
        statusItem = StatusItemController(
            store: store,
            client: client,
            config: { [weak self] in self?.configLoader.current ?? MenuBarConfig() },
            acknowledgements: { [weak self] in self?.store.acknowledgements ?? AcknowledgementStore() }
        )

        wire()
        registry.start()
        client.start()
        configLoader.start()
        store.recompute(registry: registry.records, herdrSnapshot: client.snapshot, herdrFresh: client.snapshotIsFresh)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.persist()
        client?.stop()
        registry?.stop()
        configLoader?.stop()
        Log.shared.info("PiMenuBar stopping")
        instanceLock?.release()
    }

    private func wire() {
        // Any change in either source re-merges and repaints.
        let recompute: () -> Void = { [weak self] in
            guard let self else { return }
            self.store.recompute(
                registry: self.registry.records,
                herdrSnapshot: self.client.snapshot,
                herdrFresh: self.client.snapshotIsFresh
            )
        }
        registry.onChange = recompute
        client.onChange = recompute
        store.onChange = { [weak self] in self?.statusItem.scheduleRender() }
        configLoader.onChange = { [weak self] in
            guard let self else { return }
            self.client.reconnect(reason: "config change")
            self.registry.scan()
            recompute()
        }

        statusItem.onRefresh = { [weak self] in
            guard let self else { return }
            self.registry.scan()
            self.client.refreshSnapshot(reason: "manual refresh")
        }
        statusItem.onRevealLog = { Self.reveal(path: Log.shared.filePath) }
        statusItem.onRevealConfig = { Self.reveal(path: MenuBarConfig.configPath) }
        statusItem.onRevealRegistry = { Self.reveal(path: self.configLoader.current.resolvedRegistryDir) }
        statusItem.onAcknowledge = { [weak self] session in
            self?.store.acknowledge(session)
        }
        statusItem.onFocus = { [weak self] session in
            guard let self else { return }
            Task { @MainActor in
                let outcome = await self.focuser.focus(
                    session,
                    via: self.client,
                    defaultBundleId: self.configLoader.current.terminalBundleId
                )
                switch outcome {
                case let .focused(label):
                    Log.shared.info("focused \(label) (pane \(session.herdr?.paneId ?? "?"))")
                    self.store.acknowledge(session)
                case let .partial(note):
                    Log.shared.warn("partially focused \(session.label): \(note)")
                    if session.herdr != nil { self.store.acknowledge(session) }
                case let .failed(reason):
                    Log.shared.error("could not focus \(session.label): \(reason)")
                }
            }
        }
    }

    private static func reveal(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

/// `flock`-based single instance guard.
final class InstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(path: String) -> InstanceLock? {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return InstanceLock(descriptor: descriptor)
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
