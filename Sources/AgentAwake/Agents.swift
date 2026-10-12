import Foundation

private let home = FileManager.default.homeDirectoryForCurrentUser

private func lastPathComponent(_ path: String?) -> String? {
    path.map { URL(fileURLWithPath: $0).lastPathComponent }
}

/// Claude Code: the VS Code extension and the terminal CLI both write
/// `~/.claude/projects/<project>/<session>.jsonl`, and their subagents write
/// `<session>/subagents/*.jsonl`. This is Claude Code's internal format, not a
/// public API.
struct ClaudeCode: AgentSource {
    let id = "claude-code"
    let name = "Claude Code"
    var root = home.appendingPathComponent(".claude/projects", isDirectory: true)

    func isSessionLog(_ url: URL) -> Bool { url.pathExtension == "jsonl" }

    func state(newestFirst entries: [[String: Any]]) -> TurnState? {
        var answersTool = false
        var newest = true
        for entry in entries {
            let type = entry["type"] as? String
            // Titles, attachments and hook summaries don't show the state.
            guard type == "user" || type == "assistant" else { continue }
            defer { newest = false }
            // isMeta entries are notes Claude Code adds: mostly mid-turn (an image's
            // size, a skill's text), and some that start a turn (a message from
            // another session, the resume after a subagent hands back). The newest
            // one means a turn is under way; older ones say nothing, and the
            // local-command caveat always has its command entry after it.
            if entry["isMeta"] as? Bool == true {
                if newest { return .working }
                continue
            }
            let message = entry["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []

            if type == "assistant" {
                // A subagent ends by handing its report back through a tool call;
                // the result of that call is the last thing it writes.
                if answersTool {
                    let handsBack = blocks.contains { $0["type"] as? String == "tool_use" && $0["name"] as? String == "SubagentHandback" }
                    return handsBack ? .idle : .working
                }
                // tool_use: a tool is running or waiting for permission.
                // stop_sequence: what Claude Code writes for an API error that ended the turn.
                let stop = message?["stop_reason"] as? String ?? ""
                return ["end_turn", "stop_sequence", "refusal"].contains(stop) ? .idle : .working
            }

            // Only the entry's own text is read, never a tool_result's content: a tool
            // can return anything, transcripts included.
            let texts =
                (message?["content"] as? String).map { [$0] }
                ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if texts.contains(where: { text in Self.localOnlyPrefixes.contains { text.hasPrefix($0) } }) {
                return .idle
            }
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                answersTool = true  // which tool it answered decides; read the call before it
                continue
            }
            return .working  // a prompt
        }
        return answersTool ? .working : nil
    }

    /// User entries that never start a model turn: Esc, and local slash commands
    /// (/compact, /model, ...), which log their output with no reply after it.
    private static let localOnlyPrefixes = [
        "[Request interrupted by user",
        "<command-name>",
        "<local-command-stdout>",
        "<local-command-stderr>",
    ]

    func project(newestFirst entries: [[String: Any]]) -> String? {
        lastPathComponent(entries.lazy.compactMap { $0["cwd"] as? String }.first)
    }
}

/// Gemini CLI: `~/.gemini/tmp/<project hash>/chats/session-*.json`, one JSON
/// document rewritten as the chat goes. It isn't JSONL, so only write times count.
struct GeminiCLI: AgentSource {
    let id = "gemini-cli"
    let name = "Gemini CLI"
    var root = home.appendingPathComponent(".gemini/tmp", isDirectory: true)
    let readsEntries = false

    func isSessionLog(_ url: URL) -> Bool {
        url.pathExtension == "json" && url.deletingLastPathComponent().lastPathComponent == "chats"
    }

    func state(newestFirst entries: [[String: Any]]) -> TurnState? { nil }
    func project(newestFirst entries: [[String: Any]]) -> String? { nil }
}

/// Antigravity, the app and its VS Code extension (`agy --app_data_dir=antigravity`):
/// conversations go to `~/.gemini/antigravity/conversations` (protobuf) and a
/// `conversation_summaries.db`, the agent's notes and plans to
/// `brain/<conversation>/`, so only write times count. Left out: `cli.log`, written
/// every minute even when idle, and `code_tracker`, which the editor updates for
/// your own edits too.
struct Antigravity: AgentSource {
    let id = "antigravity"
    let name = "Antigravity"
    var root = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
    let readsEntries = false
    private static let folders: Set = ["conversations", "brain"]

    func isSessionLog(_ url: URL) -> Bool {
        let inside = pathInside(url)
        guard let first = inside.first else { return false }
        // Not the -shm file: SQLite touches it on reads too, so an idle but open
        // Antigravity would look busy.
        return Self.folders.contains(first)
            || (inside.count == 1 && ["conversation_summaries.db", "conversation_summaries.db-wal"].contains(first))
    }

    func shouldDescend(into folder: URL) -> Bool {
        let inside = pathInside(folder)
        return inside.first.map(Self.folders.contains) ?? true
    }

    private func pathInside(_ url: URL) -> ArraySlice<String> {
        url.standardizedFileURL.pathComponents.dropFirst(root.resolvingSymlinksInPath().pathComponents.count)
    }

    func state(newestFirst entries: [[String: Any]]) -> TurnState? { nil }
    func project(newestFirst entries: [[String: Any]]) -> String? { nil }
}
