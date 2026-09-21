import Foundation
import PiMenuBarCore

/// herdr socket client.
///
/// Owns two connections, as the protocol requires: short-lived request sockets for
/// snapshots and focus, and one long-lived socket that becomes a read-only event stream
/// after `events.subscribe`. Because events carry no sequence number and are never
/// replayed, the snapshot is the source of truth: connect runs
/// snapshot → subscribe → snapshot to close the gap, structural events trigger a
/// debounced re-snapshot, and a slow poll re-syncs even while connected.
@MainActor
final class HerdrClient {
    struct Status: Equatable {
        var available = false
        var protocolVersion: Int?
        var socketPath: String?
        var socketSource: String?
        var message: String?
        var usableSocketCount = 0
        var lastSnapshotAt: Date?
        var lastEventAt: Date?

        var isStale: Bool { lastSnapshotAt == nil }
    }

    private(set) var snapshot: HerdrSnapshot?
    private(set) var status = Status()
    var onChange: (() -> Void)?

    private let config: () -> MenuBarConfig
    private let registryRecords: () -> [RegistryRecord]
    private let queue = DispatchQueue(label: "PiMenuBar.herdr", qos: .utility)

    private var stream: HerdrEventStream?
    private var streamGeneration = 0
    private var resyncWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var reconnectAttempt = 0
    private var stopped = true

    init(config: @escaping () -> MenuBarConfig, registryRecords: @escaping () -> [RegistryRecord]) {
        self.config = config
        self.registryRecords = registryRecords
    }

    /// A snapshot is only trusted while it is recent; otherwise the registry wins.
    var snapshotIsFresh: Bool {
        guard let at = status.lastSnapshotAt else { return false }
        return Date().timeIntervalSince(at) < Double(config().pollIntervalMs) / 1000 * 2
    }

    func start() {
        stopped = false
        connect()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Double(config().pollIntervalMs) / 1000, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot(reason: "safety poll") }
        }
        pollTimer?.tolerance = 5
    }

    func stop() {
        stopped = true
        pollTimer?.invalidate()
        pollTimer = nil
        resyncWork?.cancel()
        resyncWork = nil
        streamGeneration += 1
        stream?.cancel()
        stream = nil
    }

    /// Re-resolves the socket and reconnects. Used after herdr restarts or a config change.
    func reconnect(reason: String) {
        Log.shared.info("herdr: reconnecting (\(reason))")
        streamGeneration += 1
        stream?.cancel()
        stream = nil
        reconnectAttempt = 0
        connect()
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard !stopped else { return }
        let config = self.config()
        let records = registryRecords()
        let resolution = HerdrSocketDiscovery.resolve(
            configuredPath: config.resolvedHerdrSocketPath,
            registry: records
        )

        guard let chosen = resolution.chosen else {
            let attempted = resolution.attempted.map(\.path).joined(separator: ", ")
            updateStatus {
                $0.available = false
                $0.message = "no herdr socket (\(attempted.isEmpty ? "no candidates" : attempted))"
            }
            scheduleReconnect()
            return
        }

        status.socketPath = chosen.path
        status.socketSource = chosen.source
        status.usableSocketCount = resolution.usableCount

        let generation = streamGeneration
        queue.async { [weak self] in
            let outcome = Self.performHandshake(socketPath: chosen.path)
            Task { @MainActor in
                guard let self, self.streamGeneration == generation, !self.stopped else { return }
                switch outcome {
                case let .success(snapshot, stream):
                    self.handleConnected(snapshot: snapshot, stream: stream, path: chosen.path)
                case let .failure(message):
                    Log.shared.warn("herdr: handshake failed on \(chosen.path): \(message)")
                    self.updateStatus {
                        $0.available = false
                        $0.message = message
                    }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private enum HandshakeOutcome: Sendable {
        case success(HerdrSnapshot, HerdrEventStream)
        case failure(String)
    }

    /// Runs off the main actor: snapshot, subscribe, snapshot again.
    nonisolated private static func performHandshake(socketPath: String) -> HandshakeOutcome {
        do {
            let first = try fetchSnapshot(socketPath: socketPath)
            guard let version = first.protocol else {
                return .failure("snapshot did not report a protocol version")
            }
            guard version == herdrSupportedProtocolVersion else {
                return .failure("unsupported herdr protocol \(version) (expected \(herdrSupportedProtocolVersion))")
            }

            let stream = try HerdrEventStream(socketPath: socketPath)
            let subscriptions = HerdrSubscription.global(HerdrSubscription.structuralTypes)
                + first.agents.map { HerdrSubscription(type: HerdrEventKind.agentStatusChanged, paneId: $0.paneId) }
            try stream.send(try HerdrCoding.encodeLine(HerdrRequests.subscribe(id: requestID("subscribe"), subscriptions)))

            // Wait for the ack before trusting the stream, so events cannot be missed
            // between the first snapshot and an accepted subscription.
            let deadline = Date().addingTimeInterval(3)
            var acknowledged = false
            while !acknowledged, Date() < deadline {
                let frames = try stream.nextFrames(timeout: max(0.1, deadline.timeIntervalSinceNow))
                for frame in frames {
                    if let response = try? HerdrCoding.decodeFrame(frame, as: HerdrResponse<HerdrSubscribeAck>.self),
                       response.result?.type == "subscription_started" {
                        acknowledged = true
                    } else if let error = try? HerdrCoding.decodeFrame(frame, as: HerdrResponse<HerdrSubscribeAck>.self),
                              let herdrError = error.error {
                        return .failure("subscribe rejected: \(herdrError.code)")
                    }
                }
            }
            guard acknowledged else { return .failure("subscribe was not acknowledged") }

            // Second snapshot closes the snapshot/subscribe race.
            let second = try fetchSnapshot(socketPath: socketPath)
            return .success(second, stream)
        } catch {
            return .failure("\(error)")
        }
    }

    nonisolated private static func fetchSnapshot(socketPath: String) throws -> HerdrSnapshot {
        let frame = try HerdrTransport.request(
            socketPath: socketPath,
            request: try HerdrCoding.encodeLine(HerdrRequests.snapshot(id: requestID("snapshot")))
        )
        let envelope = try HerdrTransport.decodeResult(frame, as: HerdrSnapshotEnvelope.self)
        return envelope.snapshot
    }

    nonisolated private static func requestID(_ kind: String) -> String {
        "pimenubar:\(kind):\(UUID().uuidString.prefix(8))"
    }

    private func handleConnected(snapshot: HerdrSnapshot, stream: HerdrEventStream, path: String) {
        self.snapshot = snapshot
        status.available = true
        status.protocolVersion = snapshot.protocol
        status.lastSnapshotAt = Date()
        let agentCount = snapshot.agents.count
        status.message = status.usableSocketCount > 1
            ? "\(status.usableSocketCount) herdr sockets exist; using \(status.socketSource ?? path)"
            : nil
        reconnectAttempt = 0
        self.stream = stream
        Log.shared.info("herdr: connected to \(path) (\(status.socketSource ?? "?")) protocol \(snapshot.protocol.map(String.init) ?? "?") with \(agentCount) agents")
        if status.usableSocketCount > 1 {
            Log.shared.warn("herdr: multiple usable sockets found; only \(path) is used")
        }
        onChange?()
        readEvents(from: stream, generation: streamGeneration)
    }

    private func readEvents(from stream: HerdrEventStream, generation: Int) {
        let queue = self.queue
        queue.async { [weak self] in
            while true {
                let frames: [Data]
                do {
                    frames = try stream.nextFrames(timeout: 30)
                } catch {
                    Task { @MainActor in
                        guard let self, self.streamGeneration == generation, !self.stopped else { return }
                        Log.shared.warn("herdr: event stream ended (\(error)); reconnecting")
                        self.stream = nil
                        self.updateStatus { $0.available = false; $0.message = "event stream ended: \(error)" }
                        self.scheduleReconnect()
                    }
                    return
                }
                let events = frames.compactMap { try? HerdrCoding.decodeFrame($0, as: HerdrEvent.self) }
                Task { @MainActor in
                    guard let self, self.streamGeneration == generation, !self.stopped else { return }
                    self.handle(events: events)
                }
            }
        }
    }

    private func handle(events: [HerdrEvent]) {
        guard !events.isEmpty else { return }
        status.lastEventAt = Date()
        var requiresResnapshot = false
        for event in events {
            guard let kind = HerdrEventKind.kind(for: event.event) else {
                Log.shared.debug("herdr: ignoring unknown event \(event.event)")
                continue
            }
            if HerdrEventKind.requiresResnapshot.contains(kind) {
                requiresResnapshot = true
            }
            // A completion carries no state_change_seq on the event, and the badge rule
            // needs it, so re-snapshot on status changes too (they are low frequency).
            if kind == HerdrEventKind.agentStatusChanged {
                requiresResnapshot = true
            }
            if kind == HerdrEventKind.paneUpdated, let pane = event.data?.pane {
                apply(pane: pane)
            }
        }
        if requiresResnapshot {
            scheduleResnapshot()
        }
        onChange?()
    }

    /// Applies a `pane.updated` payload locally for immediate feedback; the next snapshot
    /// reconciles everything else.
    private func apply(pane: HerdrPane) {
        guard var snapshot else { return }
        var agents = snapshot.agents.filter { $0.paneId != pane.paneId }
        if pane.agent != nil {
            agents.append(HerdrAgent(
                agent: pane.agent,
                agentSession: pane.agentSession,
                agentStatus: pane.agentStatus,
                cwd: pane.cwd,
                focused: pane.focused,
                paneId: pane.paneId,
                tabId: pane.tabId,
                workspaceId: pane.workspaceId,
                revision: nil,
                stateChangeSeq: nil,
                terminalTitle: pane.terminalTitle,
                stateLabels: pane.stateLabels,
                tokens: pane.tokens
            ))
        }
        snapshot = HerdrSnapshot(
            version: snapshot.version,
            protocolVersion: snapshot.protocol,
            focusedWorkspaceId: snapshot.focusedWorkspaceId,
            focusedTabId: snapshot.focusedTabId,
            focusedPaneId: snapshot.focusedPaneId,
            workspaces: snapshot.workspaces,
            tabs: snapshot.tabs,
            panes: snapshot.panes,
            agents: agents
        )
        self.snapshot = snapshot
    }

    func refreshSnapshot(reason: String) {
        guard !stopped else { return }
        guard let path = status.socketPath else {
            connect()
            return
        }
        let generation = streamGeneration
        queue.async { [weak self] in
            let result = Result { try Self.fetchSnapshot(socketPath: path) }
            Task { @MainActor in
                guard let self, self.streamGeneration == generation, !self.stopped else { return }
                switch result {
                case let .success(snapshot):
                    self.snapshot = snapshot
                    self.status.lastSnapshotAt = Date()
                    self.status.available = true
                    if !self.status.isStale { self.status.message = nil }
                    Log.shared.debug("herdr: snapshot refreshed (\(reason))")
                    self.onChange?()
                case let .failure(error):
                    Log.shared.warn("herdr: snapshot failed (\(reason)): \(error)")
                    self.status.message = "snapshot failed: \(error)"
                    self.onChange?()
                }
            }
        }
    }

    private func scheduleResnapshot() {
        resyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refreshSnapshot(reason: "event") }
        }
        resyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnectAttempt += 1
        let delay = min(5.0, 0.5 * pow(2.0, Double(min(reconnectAttempt, 4))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.connect()
            }
        }
    }

    private func updateStatus(_ mutate: (inout Status) -> Void) {
        var copy = status
        mutate(&copy)
        guard copy != status else { return }
        status = copy
        onChange?()
    }

    // MARK: - Focus

    enum FocusOutcome: Equatable {
        case focused(paneId: String)
        case partiallyFocused(paneId: String, note: String)
        case failed(String)
    }

    /// Absolute focus for a herdr pane. `herdr pane focus` is directional only, so
    /// `agent.focus` by pane id is the only primitive that can target a specific pane.
    func focus(paneId: String, workspaceId: String?, tabId: String?) async -> FocusOutcome {
        guard let path = status.socketPath else { return .failed("no herdr socket") }
        let result = await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let frame = try HerdrTransport.request(
                        socketPath: path,
                        request: try HerdrCoding.encodeLine(HerdrRequests.focusAgent(id: Self.requestID("focus"), paneId: paneId))
                    )
                    _ = try HerdrTransport.decodeResult(frame, as: HerdrFocusAck.self)
                    continuation.resume(returning: Result<Void, Error>.success(()))
                } catch let error as HerdrRequestError where error.code == "agent_not_found" {
                    // The agent may have exited but the pane still exists; fall back to
                    // selecting the workspace and tab, which cannot pick the exact pane.
                    var note = "agent not found; selected workspace/tab instead"
                    do {
                        if let workspaceId {
                            let frame = try HerdrTransport.request(
                                socketPath: path,
                                request: try HerdrCoding.encodeLine(HerdrRequests.focusWorkspace(id: Self.requestID("ws"), workspaceId: workspaceId))
                            )
                            _ = try HerdrTransport.decodeResult(frame, as: HerdrFocusAck.self)
                        }
                        if let tabId {
                            let frame = try HerdrTransport.request(
                                socketPath: path,
                                request: try HerdrCoding.encodeLine(HerdrRequests.focusTab(id: Self.requestID("tab"), tabId: tabId))
                            )
                            _ = try HerdrTransport.decodeResult(frame, as: HerdrFocusAck.self)
                        }
                    } catch {
                        note = "agent not found; workspace/tab focus also failed: \(error)"
                    }
                    continuation.resume(returning: Result<Void, Error>.failure(FocusFallback(reason: note)))
                } catch {
                    continuation.resume(returning: Result<Void, Error>.failure(error))
                }
            }
        }
        switch result {
        case .success:
            refreshSnapshot(reason: "focus")
            return .focused(paneId: paneId)
        case let .failure(error as FocusFallback):
            refreshSnapshot(reason: "focus-fallback")
            return .partiallyFocused(paneId: paneId, note: error.reason)
        case let .failure(error):
            return .failed("\(error)")
        }
    }

    private struct FocusFallback: Error { let reason: String }
}

/// herdr acknowledges focus requests without a meaningful payload.
struct HerdrFocusAck: Decodable, Sendable {
    let type: String?
    let paneId: String?
    let workspaceId: String?
    let tabId: String?
}
