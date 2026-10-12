import Foundation

// Plain assertions, no XCTest, so it runs with only the command line tools.
// `./build.sh test`

var failures = 0
@MainActor func check(_ condition: Bool, _ name: String, line: UInt = #line) {
    if !condition {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

/// Entries given oldest first, as they appear in the file.
func state(_ source: any AgentSource, _ lines: [String]) -> TurnState? {
    let entries = lines.reversed().map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    return source.state(newestFirst: entries)
}

// MARK: Claude Code

let claude = ClaudeCode()
let prompt = #"{"type":"user","cwd":"/work/api","message":{"content":"fix the bug"}}"#
let toolUse = #"{"type":"assistant","cwd":"/work/api","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#
let toolResult = #"{"type":"user","cwd":"/work/api","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
let endTurn = #"{"type":"assistant","cwd":"/work/api","message":{"stop_reason":"end_turn"}}"#
let handBack = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"SubagentHandback"}]}}"#

check(state(claude, [prompt, endTurn]) == .idle, "reply finished")
check(state(claude, [prompt, toolUse]) == .working, "tool running")
check(state(claude, [prompt, toolUse, toolResult]) == .working, "tool result waiting for the model")
check(state(claude, [prompt, toolUse, toolUse, toolResult, toolResult]) == .working, "parallel tool results")
check(state(claude, [prompt]) == .working, "prompt sent")
check(
    state(claude, [#"{"type":"user","message":{"content":[{"type":"text","text":"fix it"}]}}"#]) == .working,
    "prompt sent as blocks")
check(
    state(claude, [#"{"type":"assistant","message":{"stop_reason":null}}"#]) == .working, "still streaming")
check(
    state(claude, [prompt, #"{"type":"assistant","isApiErrorMessage":true,"message":{"stop_reason":"stop_sequence"}}"#])
        == .idle, "API error ended the turn")
check(
    state(claude, [prompt, toolUse, #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#])
        == .idle, "Esc at a permission prompt")
check(
    state(claude, [prompt, #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#])
        == .idle, "Esc")
check(
    state(claude, [endTurn, #"{"type":"user","message":{"content":"<command-name>/compact</command-name>"}}"#,
        #"{"type":"user","message":{"content":"<local-command-stdout>Compacted</local-command-stdout>"}}"#]) == .idle,
    "local slash command")
check(
    state(claude, [endTurn, #"{"type":"user","message":{"content":"<command-name>/model</command-name>"}}"#]) == .idle,
    "local slash command with no output logged")
check(
    state(claude, [prompt, toolUse, toolResult, #"{"type":"user","isMeta":true,"message":{"content":"[Image: 800x600]"}}"#])
        == .working, "a mid-turn meta note doesn't end the turn")
check(
    state(claude, [endTurn, #"{"type":"user","isMeta":true,"message":{"content":"Another Claude session sent a message"}}"#])
        == .working, "a meta entry that starts a turn")
check(
    state(claude, [endTurn, #"{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>…"}}"#,
        #"{"type":"user","message":{"content":"<command-name>/model</command-name>"}}"#]) == .idle,
    "an older meta entry is skipped")
check(
    state(claude, [prompt, toolUse, #"{"type":"user","message":{"content":[{"type":"tool_result","content":"[Request interrupted by user]"}]}}"#])
        == .working, "a tool result quoting an interrupt is still a tool result")
check(state(claude, [prompt, handBack, toolResult]) == .idle, "subagent handed its report back")
check(state(claude, [toolResult]) == .working, "tool result whose call is out of the window")
check(state(claude, [#"{"type":"attachment"}"#, #"{"type":"system"}"#]) == nil, "bookkeeping only")
check(claude.project(newestFirst: [["type": "x"], ["cwd": "/work/api"]]) == "api", "project from cwd")

// MARK: Scanning a folder

let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-awake-tests-\(getpid())")

@MainActor func write(_ path: String, _ lines: [String], age: TimeInterval) {
    let url = root.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
}

write("claude/-work-api/long-tool.jsonl", [prompt, toolUse, #"{"type":"attachment"}"#], age: 5 * 60)
write("claude/-work-api/finished.jsonl", [prompt, endTurn, #"{"type":"system"}"#], age: 10)
write("claude/-work-old/stale.jsonl", [prompt, toolUse], age: 31 * 60)
write("claude/-work-api/finished/subagents/running.jsonl", [prompt, toolUse], age: 10 * 60)
write("claude/-work-api/finished/subagents/done.jsonl", [prompt, handBack, toolResult], age: 20)
write("claude/-work-odd/unreadable-fresh.jsonl", ["not json", #"{"type":"mystery"}"#], age: 30)
write("claude/-work-odd/unreadable-old.jsonl", ["not json"], age: 4 * 60)
// A last entry bigger than the first read window must still be found.
let huge = #"{"type":"assistant","cwd":"/w/big","message":{"stop_reason":"end_turn","content":""#
    + String(repeating: "x", count: 600 * 1024) + #""}}"#
write("claude/-w-big/huge.jsonl", [prompt, huge], age: 10)

func names(_ sessions: [AgentSession]) -> [String] { sessions.map(\.log.lastPathComponent).sorted() }

let claudeFound = AgentActivity.workingSessions(of: ClaudeCode(root: root.appendingPathComponent("claude")))
check(
    names(claudeFound) == ["long-tool.jsonl", "running.jsonl", "unreadable-fresh.jsonl"],
    "claude sessions, got \(names(claudeFound))")
check(
    claudeFound.map { $0.project ?? "-" }.sorted() == ["-", "api", "api"],
    "claude projects, got \(claudeFound.map { $0.project ?? "-" })")

write("gemini/abc123/chats/session-1.json", ["{}"], age: 30)
write("gemini/abc123/chats/session-2.json", ["{}"], age: 4 * 60)
write("gemini/abc123/logs.json", ["{}"], age: 5)
let geminiFound = AgentActivity.workingSessions(of: GeminiCLI(root: root.appendingPathComponent("gemini")))
check(names(geminiFound) == ["session-1.json"], "gemini sessions, got \(names(geminiFound))")

write("antigravity/conversations/c1.pb", ["x"], age: 20)
write("antigravity/brain/c2/task.md", ["x"], age: 40)
write("antigravity/brain/c3/plan.md", ["x"], age: 5 * 60)
write("antigravity/code_tracker/active/proj/file.ts", ["x"], age: 5)
write("antigravity/log/cli.log", ["x"], age: 5)
write("antigravity/cli.log", ["x"], age: 5)
write("antigravity/conversation_summaries.db-wal", ["x"], age: 50)
write("antigravity/conversation_summaries.db-shm", ["x"], age: 5)
let antigravityFound = AgentActivity.workingSessions(of: Antigravity(root: root.appendingPathComponent("antigravity")))
check(
    names(antigravityFound) == ["c1.pb", "conversation_summaries.db-wal", "task.md"],
    "antigravity sessions, got \(names(antigravityFound))")

check(AgentActivity.workingSessions(of: ClaudeCode(root: root.appendingPathComponent("missing"))).isEmpty, "no folder")

let link = root.appendingPathComponent("linked-antigravity")
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("antigravity"))
check(
    names(AgentActivity.workingSessions(of: Antigravity(root: link))) == names(antigravityFound),
    "a symlinked root is followed")

try? FileManager.default.removeItem(at: root)
print(failures == 0 ? "all tests passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
