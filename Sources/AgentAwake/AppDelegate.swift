import AppKit
import ServiceManagement

enum Mode: String, CaseIterable {
    case auto, always, never

    var title: String {
        switch self {
        case .auto: "While an Agent Is Working"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// How often agent logs are re-scanned.
    static let pollInterval: TimeInterval = 10
    /// Stay awake this long after the last working turn, covering the gap between a
    /// reply and your next prompt so the Mac doesn't drop off mid-conversation.
    static let grace: TimeInterval = 60
    /// On battery at or below this charge, sleep is allowed again whatever the mode,
    /// so a closed laptop in a bag doesn't run itself flat.
    static let batteryFloor = 15

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let idleSleep = IdleSleepAssertion()
    private let lidSleep = LidSleep()
    private var timer: Timer?

    private var working: [AgentSession] = []
    private var lastWorkingAt: Date?
    private var isAwake = false
    /// Awake with sleep disabled outright, so closing the lid doesn't stop it.
    private var survivesLidClose = false
    private var pausedAtBattery: Int?

    private let defaults = UserDefaults.standard

    private var mode: Mode {
        get { defaults.string(forKey: "mode").flatMap(Mode.init) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    private var lidClosedAllowed: Bool {
        get { defaults.object(forKey: "lidClosed") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lidClosed") }
    }

    private func isWatched(_ agent: any AgentSource) -> Bool {
        defaults.object(forKey: "watch.\(agent.id)") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        tick()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        // .common, so ticks keep running while a menu or alert is open: the end of a
        // turn and the battery floor must still be acted on.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        idleSleep.set(false)
        lidSleep.set(false)
    }

    private func tick() {
        let now = Date()
        working = mode == .auto ? AgentActivity.workingSessions(of: AgentActivity.all.filter(isWatched), now: now) : []
        if !working.isEmpty { lastWorkingAt = now }

        var awake =
            switch mode {
            case .never: false
            case .always: true
            case .auto: lastWorkingAt.map { now.timeIntervalSince($0) < Self.grace } ?? false
            }
        pausedAtBattery = nil
        if awake, let percent = Battery.percentOnBattery(), percent <= Self.batteryFloor {
            awake = false
            pausedAtBattery = percent
        }

        isAwake = awake
        idleSleep.set(awake)
        lidSleep.set(awake && lidClosedAllowed)
        // isDisabledByUs is false while someone else's disablesleep already does the job.
        survivesLidClose =
            awake && (lidSleep.isDisabledByUs || (lidClosedAllowed && LidSleep.systemSleepDisabled() == true))
        updateIcon()
    }

    private func updateIcon() {
        let symbol =
            if lidSleep.restoreFailed { "exclamationmark.triangle.fill" }
            else if pausedAtBattery != nil { "battery.25percent" }
            else if survivesLidClose { "cup.and.heat.waves.fill" }
            else if isAwake { "cup.and.heat.waves" }
            else if mode == .never { "moon.zzz" }
            else { "cup.and.saucer" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Agent Awake")
        statusItem.button?.toolTip = "Agent Awake: \(sleepStatus)"
    }

    private var activityStatus: String {
        switch mode {
        case .never: return "Keep-awake is off"
        case .always: return "Keeping awake until you turn it off"
        case .auto:
            guard !working.isEmpty else {
                return isAwake ? "Agent just finished" : "No agent is working"
            }
            let names = Set(working.map { session in
                session.project.map { "\(session.agent) · \($0)" } ?? session.agent
            })
            return "Working: " + names.sorted().joined(separator: ", ")
        }
    }

    private var sleepStatus: String {
        // Checked first: the Mac can't sleep, whatever the mode says.
        if lidSleep.restoreFailed { return "Sleep is still disabled and couldn't be restored" }
        if let pausedAtBattery { return "Sleep allowed: battery at \(pausedAtBattery)%" }
        guard isAwake else { return "Mac can sleep normally" }
        return survivesLidClose ? "Awake, even with the lid closed" : "Awake, but closing the lid will sleep"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        lidSleep.refreshPermission()
        tick()
        menu.removeAllItems()
        menu.addItem(disabled(activityStatus))
        menu.addItem(disabled(sleepStatus))
        if lidSleep.restoreFailed {
            menu.addItem(action("Restore Sleep Now…", #selector(restoreSleep)))
        }
        menu.addItem(.separator())

        menu.addItem(disabled("Keep the Mac Awake"))
        for option in Mode.allCases {
            let item = action(option.title, #selector(chooseMode(_:)))
            item.representedObject = option.rawValue
            item.state = option == mode ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        let lid = action("Even with the Lid Closed", #selector(toggleLidClosed))
        lid.state = lidClosedAllowed && lidSleep.isPermitted ? .on : .off
        if lidClosedAllowed && !lidSleep.isPermitted { lid.title = "Allow Keeping Awake with the Lid Closed…" }
        lid.indentationLevel = 1
        menu.addItem(lid)
        menu.addItem(.separator())

        menu.addItem(disabled("Watch Agents"))
        for agent in AgentActivity.all {
            let installed = FileManager.default.fileExists(atPath: agent.root.path)
            let item = action(installed ? agent.name : "\(agent.name) (not found)", #selector(toggleAgent(_:)))
            item.representedObject = agent.id
            item.state = isWatched(agent) ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let login = action("Start at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Quit Agent Awake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let chosen = Mode(rawValue: raw) else { return }
        mode = chosen
        lastWorkingAt = nil
        tick()
    }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        defaults.set(sender.state != .on, forKey: "watch.\(id)")
        tick()
    }

    @objc private func toggleLidClosed() {
        if lidClosedAllowed && lidSleep.isPermitted {
            lidClosedAllowed = false
        } else {
            lidClosedAllowed = true
            if !lidSleep.isPermitted { askForLidPermission() }
        }
        tick()
    }

    @objc private func restoreSleep() {
        lidSleep.restoreWithPassword()
        tick()
    }

    private func askForLidPermission() {
        let alert = NSAlert()
        alert.messageText = "Keep the Mac awake with the lid closed?"
        alert.informativeText = """
            macOS only allows this through `pmset disablesleep`, which needs admin rights. \
            Agent Awake will add one rule to \(LidSleep.sudoersFile) letting your account run \
            exactly `pmset -a disablesleep 0` and `… 1` without a password, so it can switch \
            sleep off and on as agents start and stop. It also turns on Start at Login, so \
            sleep is restored even after a forced restart.

            To remove the rule later, quit Agent Awake first, then: sudo rm \(LidSleep.sudoersFile)
            """
        alert.addButton(withTitle: "Continue…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let message = lidSleep.grantPermission() {
            showError("Couldn't set up lid-closed mode", message)
        } else if lidSleep.isPermitted, SMAppService.mainApp.status != .enabled {
            // disablesleep survives a reboot; launching at login is what restores it
            // after a crash the watchdog didn't see.
            do {
                try SMAppService.mainApp.register()
            } catch {
                showError(
                    "Couldn't turn on Start at Login",
                    "Lid-closed mode works, but turn on Start at Login from the menu so sleep is "
                        + "restored after a forced restart. \(error.localizedDescription)")
            }
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Couldn't change Start at Login", error.localizedDescription)
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
