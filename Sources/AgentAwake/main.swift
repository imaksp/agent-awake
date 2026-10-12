import AppKit

// `AgentAwake --scan` prints the sessions it currently counts as working, for every
// agent whether or not it is switched on in the menu, and exits: a quick way to
// check the detection without the menu bar.
if CommandLine.arguments.contains("--scan") {
    let sessions = AgentActivity.workingSessions(of: AgentActivity.all)
    if sessions.isEmpty { print("no agent is working") }
    for session in sessions { print("\(session.agent)\t\(session.project ?? "-")\t\(session.log.path)") }
    exit(0)
}

// One instance only: two would fight over the same pmset setting.
if let id = Bundle.main.bundleIdentifier,
    NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1
{
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)

    // SIGTERM (`pkill`, a reinstall, logout) quits through applicationWillTerminate,
    // so sleep is restored straight away rather than by the watchdog.
    signal(SIGTERM, SIG_IGN)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    terminate.setEventHandler { NSApp.terminate(nil) }
    terminate.resume()

    withExtendedLifetime((delegate, terminate)) { app.run() }
}
