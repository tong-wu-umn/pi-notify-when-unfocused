import Foundation

public struct TitleSummary: Sendable, Equatable {
    public var blocked = 0
    public var working = 0
    /// Finished and not yet acknowledged.
    public var attention = 0
    public var idle = 0
    public var unknown = 0

    public var total: Int { blocked + working + attention + idle + unknown }
    public var hasWork: Bool { blocked + working + attention > 0 }

    public init() {}

    public init(_ sessions: [Session]) {
        for session in sessions {
            switch session.displayState {
            case .blocked: blocked += 1
            case .working: working += 1
            case .done: attention += 1
            case .idle: idle += 1
            case .unknown: unknown += 1
            }
        }
    }
}

/// Renders the menu bar title, the tooltip, and menu row text.
///
/// Menu bar space is the scarcest resource in this app: the title is always a bounded
/// per-state count, never one glyph per session.
public enum TitleFormatter {
    public static let prefix = "π"

    public static func summary(_ sessions: [Session]) -> TitleSummary {
        TitleSummary(sessions)
    }

    public static func title(_ sessions: [Session], showIdle: Bool) -> String {
        let counts = summary(sessions)
        var parts: [String] = []
        if counts.blocked > 0 { parts.append("\(clamp(counts.blocked))!") }
        if counts.working > 0 { parts.append("\(clamp(counts.working))▶") }
        if counts.attention > 0 { parts.append("\(clamp(counts.attention))○") }
        if showIdle, counts.idle > 0 { parts.append("\(clamp(counts.idle))·") }
        if counts.unknown > 0 { parts.append("\(clamp(counts.unknown))?") }
        guard !parts.isEmpty else { return prefix }
        return "\(prefix) \(parts.joined())"
    }

    public static func tooltip(_ sessions: [Session], now: Date) -> String {
        let counts = summary(sessions)
        guard counts.total > 0 else { return "\(prefix) — no active sessions" }

        var sections: [String] = []
        func describe(_ state: SessionState, _ label: String) {
            let matching = sessions.filter { $0.displayState == state }
            guard !matching.isEmpty else { return }
            let names = matching.prefix(4).map { session -> String in
                var text = session.label
                if state == .blocked, let since = session.waitingSince {
                    text += " \(DurationLabel.compact(from: since, to: now))"
                } else if state == .working, let started = session.runStartedAt {
                    text += " \(DurationLabel.compact(from: started, to: now))"
                }
                return text
            }
            let suffix = matching.count > names.count ? ", +\(matching.count - names.count) more" : ""
            sections.append("\(matching.count) \(label) (\(names.joined(separator: ", "))\(suffix))")
        }
        describe(.blocked, "blocked")
        describe(.working, "working")
        describe(.done, "finished")
        describe(.idle, "idle")
        describe(.unknown, "unknown")
        return "\(prefix) — \(sections.joined(separator: " · "))"
    }

    /// `▶ project — bash +1 · 12m · deepseek-flash · 42%`
    public static func rowTitle(_ session: Session, now: Date) -> String {
        let detail = session.detailLine(now: now)
        let marker = session.focused ? "•" : " "
        let title = "\(session.displayState.glyph)\(marker) \(session.label)"
        return detail.isEmpty ? title : "\(title) — \(detail)"
    }

    /// One-line summary used in the submenu header and the details window.
    public static func detailText(_ session: Session, now: Date) -> String {
        var lines: [String] = []
        lines.append("label:      \(session.label)")
        lines.append("state:      \(session.state.rawValue)\(session.needsAttention ? " (needs attention)" : "")")
        lines.append("source:     \(session.source.rawValue)")
        lines.append("project:    \(session.project)")
        lines.append("cwd:        \(session.cwd)")
        if let pane = session.herdr?.paneId { lines.append("pane:       \(pane)") }
        if let file = session.sessionFile { lines.append("session:    \(file)") }
        if let id = session.sessionId { lines.append("session id: \(id)") }
        if let mode = session.mode { lines.append("mode:       \(mode)") }
        if let model = session.model { lines.append("model:      \(model)") }
        if let thinking = session.thinking { lines.append("thinking:   \(thinking)") }
        if let tokens = session.contextTokens, let window = session.contextWindow {
            let percent = session.contextPercent.map { " (\($0)%)" } ?? ""
            lines.append("context:    \(tokens)/\(window)\(percent)")
        }
        if !session.activeTools.isEmpty {
            let tools = session.activeTools.map { "\($0.name)" }.joined(separator: ", ")
            lines.append("tools:      \(tools)")
        }
        if let started = session.runStartedAt {
            lines.append("running:    \(DurationLabel.compact(from: started, to: now))")
        }
        if let waiting = session.waitingSince {
            lines.append("waiting:    \(DurationLabel.compact(from: waiting, to: now))")
        }
        if let settled = session.settledAt {
            lines.append("finished:   \(DurationLabel.compact(from: settled, to: now)) ago")
        }
        if let label = session.stateLabel, !label.isEmpty { lines.append("label:      \(label)") }
        if let prompt = session.lastUserPrompt, !prompt.isEmpty { lines.append("prompt:     \(prompt)") }
        lines.append("updated:    \(session.updatedAt.formatted(date: .omitted, time: .standard))")
        if session.simulated { lines.append("simulated:  true") }
        return lines.joined(separator: "\n")
    }

    private static func clamp(_ count: Int) -> String {
        count > 9 ? "9+" : "\(count)"
    }
}
