# Agent Awake

A menu bar app that keeps a Mac awake while a coding agent is working, even with the
lid closed. When the agent finishes, the Mac sleeps normally again.

I made it for myself. Use it or fork it if it's useful to you.

## Install

Download `AgentAwake-x.y.z.zip` from [Releases](../../releases/latest), unzip it, and
move `AgentAwake.app` to `~/Applications` or `/Applications` **before opening it**. A
first launch from Downloads runs from a temporary path, which Start at Login could
end up pointing at. It runs on Apple silicon and Intel Macs with macOS 14 or later.

**macOS will refuse to open it the first time.** The app is ad-hoc signed by an
unverified developer and not notarized by Apple. Notarizing needs a paid Apple
Developer account ($99 a year), and I'm not paying that for a small side project.
To open it anyway, do either of these once:

- Open the app, dismiss the warning, then go to **System Settings → Privacy &
  Security** and click **Open Anyway**. It asks for your password, and the button
  appears only for about an hour after the blocked open.
- Or run `xattr -dr com.apple.quarantine /path/to/AgentAwake.app`.

If you'd rather not trust a downloaded binary, build it yourself from source (below).
A build made on your own Mac never triggers the warning.

## How it decides

It reads the logs each agent already writes, so nothing needs installing in the agent
itself. Each agent can be switched on or off from the menu.

| Agent | Log | A turn is running while |
|---|---|---|
| Claude Code (VS Code extension and CLI) | `~/.claude/projects/**/*.jsonl` | its last entry is a prompt, tool call or tool result. A finished reply, Esc, API error or local slash command ends it. Subagents are read the same way. |
| Gemini CLI | `~/.gemini/tmp/*/chats/*.json` | the chat file was written in the last 3 minutes |
| Antigravity (the app and its VS Code extension) | `~/.gemini/antigravity`: `conversations/`, `brain/`, `conversation_summaries.db` | a conversation or its notes were written in the last 3 minutes |

These are the agents' internal formats, not public APIs. If Claude Code's changes, its
logs fall back to the same 3-minute rule. The Gemini CLI and Antigravity rules haven't
been checked against a live session yet. For any other agent, use *Always* and *Never*
from the menu, or add an `AgentSource` in `Sources/AgentAwake/Agents.swift`.

Two limits keep a stuck session from holding the Mac awake forever. A log untouched for
30 minutes stops counting (a forgotten permission prompt, or a window closed
mid-turn). And the Mac stays awake for only 60 seconds after the last working turn.

## Menu

- **Keep the Mac Awake:** *While an Agent Is Working* (default), *Always*, or *Never*.
  - **Even with the Lid Closed:** on by default. Needs a one-time admin setup (below).
- **Watch Agents:** Claude Code, Gemini CLI, Antigravity.
- **Start at Login**

| Icon | State |
|---|---|
| filled steaming cup | awake, and stays awake with the lid closed |
| outline steaming cup | awake, but closing the lid will sleep |
| empty cup | watching; no agent is working, so the Mac can sleep |
| moon | off |
| battery | paused for low battery |
| warning | sleep couldn't be restored; the menu offers a fix |

On battery at 15% or below it lets the Mac sleep whatever the mode, so a closed laptop
in a bag doesn't run itself flat.

## Lid closed

No power assertion survives closing the lid. The only switch is
`pmset -a disablesleep 1`, which needs root. The first time you turn the option on, the
app asks for your admin password once. It then installs this rule in
`/etc/sudoers.d/agent-awake`, after checking it with `visudo`:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

That lets the app switch sleep off and back on as turns start and end, with no prompts.
It also turns on Start at Login.

Unlike an assertion, the setting outlives the app and even a restart. Sleep is
restored:

- when the app quits,
- by a small watchdog process if the app crashes,
- on the next launch if both of those fail.

If restoring ever fails, the icon turns into a warning and the menu offers *Restore
Sleep Now…*. The app never touches a `disablesleep` it didn't set.

To remove the rule, **quit Agent Awake first**, then run
`sudo rm /etc/sudoers.d/agent-awake`. To reset sleep by hand, run
`sudo pmset -a disablesleep 0`.

## Build

Needs Xcode or the command line tools, and macOS 14 or later.

```sh
./build.sh          # build, ad-hoc sign, install to ~/Applications and launch
./build.sh test     # detection tests
./build.sh release  # universal app, zipped into build/ for a GitHub release
~/Applications/AgentAwake.app/Contents/MacOS/AgentAwake --scan   # what it sees right now
```

## License

MIT
