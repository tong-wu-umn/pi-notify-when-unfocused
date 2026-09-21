import Foundation
import PiMenuBarCore

/// Watches the registry directory and publishes decoded records.
///
/// A `DispatchSource` on the directory replaces polling: the extension's atomic rename
/// is a directory-level event, so a scan happens exactly when something changed. A slow
/// safety timer covers coalesced or missed events and expires rows whose writer died.
@MainActor
final class RegistryWatcher {
    private let config: () -> MenuBarConfig
    private let queue = DispatchQueue(label: "PiMenuBar.registry", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var debounceWork: DispatchWorkItem?
    private var safetyTimer: Timer?

    /// Records plus the issues worth showing in the log.
    private(set) var records: [RegistryRecord] = []
    private(set) var lastIssues: [RegistryIssue] = []
    private(set) var lastScanAt: Date?

    var onChange: (() -> Void)?

    init(config: @escaping () -> MenuBarConfig) {
        self.config = config
    }

    func start() {
        let directory = config().resolvedRegistryDir
        try? RegistryReader.ensureDirectory(directory)
        scan()
        attachWatch(directory)
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        safetyTimer?.tolerance = 5
    }

    func stop() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        debounceWork?.cancel()
        source?.cancel()
        source = nil
        if directoryDescriptor >= 0 {
            close(directoryDescriptor)
            directoryDescriptor = -1
        }
    }

    /// Re-reads the directory (the watcher handles this automatically; exposed for tests
    /// and the manual Refresh item).
    func scan() {
        let snapshotConfig = config()
        let directory = snapshotConfig.resolvedRegistryDir
        queue.async { [weak self] in
            let scan = RegistryReader.scan(directory: directory, config: snapshotConfig)
            Task { @MainActor in
                guard let self else { return }
                self.apply(scan)
            }
        }
    }

    private func apply(_ scan: RegistryScan) {
        lastScanAt = Date()
        // Only rebuild when something the UI cares about changed; heartbeats arrive every
        // 15s per session and must not cause menu churn.
        let changed = scan.records.count != records.count
            || zip(scan.records, records).contains { $0.updatedAt != $1.updatedAt || $0.state != $1.state }
            || Set(scan.records.map(\.mergeKey)) != Set(records.map(\.mergeKey))
        records = scan.records
        lastIssues = scan.issues
        for issue in scan.issues {
            Log.shared.warn("registry: \(issue.path): \(issue.reason)")
        }
        for path in scan.removedPaths {
            Log.shared.debug("registry: removed stale \(path)")
        }
        if changed {
            onChange?()
        }
    }

    private func attachWatch(_ directory: String) {
        source?.cancel()
        if directoryDescriptor >= 0 {
            close(directoryDescriptor)
            directoryDescriptor = -1
        }
        directoryDescriptor = open(directory, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            Log.shared.warn("registry: cannot watch \(directory); falling back to the safety timer")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
            queue: queue
        )
        // `DispatchSourceHandler` is a plain (non-`@Sendable`) block, so a closure
        // literal written here would inherit this type's `@MainActor` isolation and
        // trap in `dispatch_assert_queue` the first time the source fires on `queue`.
        // Marking the literal `@Sendable` keeps it nonisolated; the hop to the main
        // actor happens explicitly inside.
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in self?.scheduleScan() }
        }
        source.setCancelHandler { @Sendable [descriptor = directoryDescriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
    }

    private func scheduleScan() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}
