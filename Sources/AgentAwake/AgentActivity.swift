import Foundation

enum TurnState: Equatable { case working, idle }

struct AgentSession: Equatable {
    let agent: String
    let project: String?
    let log: URL
}

/// A coding agent whose activity can be read from the session logs it writes. No
/// hooks or settings are needed in the agent itself. Another agent is one more
/// conformance added to `AgentActivity.all`.
protocol AgentSource: Sendable {
    /// Stable key for the agent's on/off switch in the menu.
    var id: String { get }
    var name: String { get }
    /// Where its session logs live. If the folder is missing, the agent isn't installed.
    var root: URL { get }
    func isSessionLog(_ url: URL) -> Bool
    /// Whether the scan looks inside a folder under `root`. Saves walking folders
    /// that can't hold a session log.
    func shouldDescend(into folder: URL) -> Bool
    /// Whether its logs are JSONL that `state` can read. If not, the agent counts as
    /// working while a log is being written to, which is all its logs can show.
    var readsEntries: Bool { get }
    /// The turn state implied by the log's last entries, newest first, or nil when
    /// they don't show it.
    func state(newestFirst entries: [[String: Any]]) -> TurnState?
    func project(newestFirst entries: [[String: Any]]) -> String?
}

extension AgentSource {
    var readsEntries: Bool { true }
    func shouldDescend(into folder: URL) -> Bool { true }
}

enum AgentActivity {
    static let all: [any AgentSource] = [ClaudeCode(), GeminiCLI(), Antigravity()]

    /// A log untouched this long is not working, whatever it says: a permission
    /// prompt left waiting, or a process that died mid-turn.
    static let staleAfter: TimeInterval = 30 * 60

    /// If the last entries don't show the state, a log written this recently counts
    /// as working. Logs with an unknown format still keep the Mac awake through a turn.
    static let freshFor: TimeInterval = 3 * 60

    static func workingSessions(of sources: [any AgentSource], now: Date = Date()) -> [AgentSession] {
        sources.flatMap { workingSessions(of: $0, now: now) }
    }

    static func workingSessions(of source: any AgentSource, now: Date = Date()) -> [AgentSession] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        guard
            let walker = FileManager.default.enumerator(
                // Resolved, since the enumerator yields nothing for a root that is a symlink.
                at: source.root.resolvingSymlinksInPath(), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])
        else { return [] }

        var sessions: [AgentSession] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true, !source.shouldDescend(into: url) { walker.skipDescendants() }
            guard
                source.isSessionLog(url),
                values.isRegularFile == true,
                let modified = values.contentModificationDate
            else { continue }
            let age = now.timeIntervalSince(modified)
            guard age < staleAfter else { continue }

            var entries: [[String: Any]] = []
            var state: TurnState?
            // Retry with a larger window when one huge entry, such as a big tool
            // result, fills the first one.
            for window in [512 * 1024, 8 * 1024 * 1024] where source.readsEntries {
                guard let tail = lastEntries(of: url, window: window) else { break }
                entries = tail.entries
                state = source.state(newestFirst: entries)
                if state != nil || !tail.truncated { break }
            }
            guard (state ?? (age < freshFor ? .working : .idle)) == .working else { continue }
            sessions.append(AgentSession(agent: source.name, project: source.project(newestFirst: entries), log: url))
        }
        return sessions
    }

    /// The JSON objects on the last lines of a JSONL file, newest first.
    static func lastEntries(of url: URL, window: Int) -> (entries: [[String: Any]], truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        // Reading from mid-file, the first line is a fragment of a longer one.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let entries = lines.reversed().compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        return (entries, start > 0)
    }
}
