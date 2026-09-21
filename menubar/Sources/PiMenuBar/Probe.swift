import Foundation
import PiMenuBarCore

/// `PiMenuBar --probe`: runs the real pipeline once and prints what the menu bar would
/// show, then exits. No status item, no daemon, no writes.
///
/// This is the integration check for the parts that unit tests cannot cover: socket
/// discovery in a non-terminal environment, the live herdr handshake, registry decoding,
/// and the merge. `--probe --json` prints the merged sessions as JSON.
enum Probe {
    @MainActor
    static func run(arguments: [String]) -> Int32 {
        let config = MenuBarConfig.load()
        let registryDir = config.resolvedRegistryDir
        let scan = RegistryReader.scan(directory: registryDir, config: config, collectGarbage: false)
        let print = { (line: String) in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

        print("PiMenuBar probe")
        print("  config:       \(MenuBarConfig.configPath)\(FileManager.default.fileExists(atPath: MenuBarConfig.configPath) ? "" : " (absent, defaults)")")
        print("  registry dir: \(registryDir)")
        print("  registry:     \(scan.records.count) record(s), \(scan.issues.count) issue(s)")
        for issue in scan.issues {
            print("    ✗ \(issue.path): \(issue.reason)")
        }

        let resolution = HerdrSocketDiscovery.resolve(
            configuredPath: config.resolvedHerdrSocketPath,
            registry: scan.records
        )
        print("  herdr socket candidates:")
        for candidate in resolution.attempted {
            let mark = candidate.path == resolution.chosen?.path ? "→" : " "
            print("    \(mark) \(candidate.path)  [\(candidate.source)]")
        }
        if resolution.usableCount > 1 {
            print("    ⚠ \(resolution.usableCount) usable sockets; using \(resolution.chosen?.path ?? "none")")
        }
        var snapshot: HerdrSnapshot?
        var snapshotNote = "not attempted (no usable socket)"
        if let chosen = resolution.chosen {
            do {
                let frame = try HerdrTransport.request(
                    socketPath: chosen.path,
                    request: try HerdrCoding.encodeLine(HerdrRequests.snapshot(id: "probe"))
                )
                let envelope = try HerdrTransport.decodeResult(frame, as: HerdrSnapshotEnvelope.self)
                snapshot = envelope.snapshot
                let protocolVersion = envelope.snapshot.protocol.map(String.init) ?? "?"
                snapshotNote = "ok — herdr \(envelope.snapshot.version ?? "?") protocol \(protocolVersion), \(envelope.snapshot.agents.count) agent(s)"
                if let version = envelope.snapshot.protocol, version != herdrSupportedProtocolVersion {
                    snapshotNote += " ⚠ unsupported (expected \(herdrSupportedProtocolVersion))"
                }
            } catch {
                snapshotNote = "failed: \(error)"
            }
        }
        print("  herdr snapshot: \(snapshotNote)")
        // Inert on purpose: the probe never touches UserNotifications or asks for
        // permission, but it does report how the native-notification policy is configured
        // so "why is nothing arriving" is answerable without the GUI.
        let notifications = config.notifications
        if notifications.enabled {
            print(
                "  notifications: enabled — prompts:\(notifications.notifyOnPrompts ? "on" : "off") "
                    + "idle:\(notifications.notifyOnIdle ? "on" : "off") "
                    + "minRun:\(notifications.idleMinRunMs)ms reminders:\(notifications.reminders) "
                    + "dedupe:\(notifications.dedupeMs)ms preciseFocus:\(notifications.preciseFocus ? "on" : "off")"
            )
        } else {
            print("  notifications: off (opt in with \"notifications\": {\"enabled\": true} in ~/.pi/agent/menubar.json)")
        }

        // The same live focus check the menu and the notifier use, so `--probe` reports the
        // badge and title the running app would show rather than herdr's pane selection.
        let merged = SessionMerger.merge(MergeInput(
            registry: scan.records,
            herdr: snapshot,
            herdrFresh: snapshot != nil,
            acknowledgements: AcknowledgementStore.load(path: MenuBarConfig.acknowledgementsPath).entries,
            now: Date()
        ))
        let sessions = SessionFocus.withAttention(
            merged,
            acknowledgements: AcknowledgementStore.load(path: MenuBarConfig.acknowledgementsPath).entries,
            herdrSnapshot: snapshot,
            herdrFresh: snapshot != nil,
            defaultTerminalBundleId: config.terminalBundleId
        ).sessions

        if arguments.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = sessions.map { session -> [String: String] in
                [
                    "key": session.key,
                    "label": session.label,
                    "project": session.project,
                    "state": session.state.rawValue,
                    "display": session.displayState.rawValue,
                    "attention": session.needsAttention ? "yes" : "no",
                    "source": session.source.rawValue,
                    "pane": session.herdr?.paneId ?? "",
                    "model": session.model ?? "",
                    "detail": session.detailLine(now: Date()),
                ]
            }
            if let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            print("")
            print("Title:   \(TitleFormatter.title(sessions, showIdle: config.showIdle))")
            print("Tooltip: \(TitleFormatter.tooltip(sessions, now: Date()))")
            print("")
            if sessions.isEmpty {
                print("No sessions. (Nothing published yet?)")
            }
            for group in SessionGrouping.groups(sessions) {
                print("\(group.title.uppercased())")
                for tab in group.tabs {
                    print("  \(tab.title)")
                    for session in tab.sessions {
                        print("    \(TitleFormatter.rowTitle(session, now: Date()))")
                        print("        key=\(session.key)")
                        print("        source=\(session.source.rawValue) attention=\(session.needsAttention) pane=\(session.herdr?.paneId ?? "-") seq=\(session.herdr?.stateChangeSeq.map(String.init) ?? "-")")
                    }
                }
            }
        }

        // Non-zero when the pipeline could not see herdr, so scripts can assert on it.
        return snapshot == nil && resolution.chosen == nil ? 2 : 0
    }
}
