import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// A PreventUserIdleSystemSleep assertion: the Mac doesn't idle-sleep, the display
/// still can. macOS releases it if the process dies, so it can't outlive the app.
@MainActor
final class IdleSleepAssertion {
    private var id: IOPMAssertionID = 0

    func set(_ held: Bool) {
        if held, id == 0 {
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Agent Awake: a coding agent is working" as CFString,
                &newID)
            if result == kIOReturnSuccess { id = newID }
        } else if !held, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

/// `pmset disablesleep`, the only switch that keeps a MacBook running with the lid
/// closed. It is system-wide and needs root, so it goes through a sudoers rule that
/// allows exactly `pmset -a disablesleep 0|1` without a password, installed once
/// from the menu.
///
/// Unlike an assertion it outlives the app, and even a reboot, so a crash would
/// leave the Mac unable to sleep. Three guards: a marker file holding our pid while
/// we have sleep disabled, a detached watchdog that restores sleep when this pid
/// exits, and a launch-time check for a marker left behind. A disablesleep someone
/// else set (no marker) is never touched.
@MainActor
final class LidSleep {
    static let sudoersFile = "/etc/sudoers.d/agent-awake"
    private static let pmset = "/usr/bin/pmset"

    private let marker: URL
    private(set) var isPermitted = false
    private(set) var isDisabledByUs = false
    /// Sleep is disabled because of us and putting it back failed, for example
    /// because the sudoers rule was removed. The menu offers a password fallback.
    private(set) var restoreFailed = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentAwake", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        marker = support.appendingPathComponent("sleep-disabled.pid")
        refreshPermission()
        if FileManager.default.fileExists(atPath: marker.path) {
            // A previous run crashed with sleep disabled and nothing restored it.
            isDisabledByUs = true
            set(false)
        }
        startWatchdog()
    }

    /// `sudo -l` alone isn't enough: it skips the password check when the user has
    /// any other NOPASSWD rule, and then an admin's `%admin ALL` matches pmset too.
    func refreshPermission() {
        isPermitted =
            FileManager.default.fileExists(atPath: Self.sudoersFile)
            && run("/usr/bin/sudo", ["-n", "-l", Self.pmset, "-a", "disablesleep", "1"]) == 0
    }

    /// Disables or restores system sleep. Called every tick, so a failed call or a
    /// manual `pmset` change is corrected on the next one.
    func set(_ disabled: Bool) {
        if disabled {
            guard isPermitted, Self.systemSleepDisabled() == false else { return }
            do {
                try String(getpid()).write(to: marker, atomically: true, encoding: .utf8)
            } catch {
                return  // never disable sleep without the marker that undoes it
            }
            isDisabledByUs = pmsetDisableSleep(true)
            if !isDisabledByUs { try? FileManager.default.removeItem(at: marker) }
        } else if isDisabledByUs {
            // Sleep may be back even though our call failed: restored by hand with
            // `sudo pmset`, or by the password fallback.
            if pmsetDisableSleep(false) || Self.systemSleepDisabled() == false {
                restored()
            } else {
                restoreFailed = true
                refreshPermission()
            }
        }
    }

    /// The fallback when the passwordless rule can't restore sleep: the standard
    /// admin prompt runs the same command.
    func restoreWithPassword() {
        if case .succeeded = runAsAdmin("\(Self.pmset) -a disablesleep 0") { restored() }
    }

    /// Installs the sudoers rule through the standard macOS admin-password prompt.
    /// Returns an error message, or nil on success or when the user cancels.
    func grantPermission() -> String? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return "Unexpected user name \"\(user)\"."
        }
        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.pmset) -a disablesleep 0, \(Self.pmset) -a disablesleep 1"
        // The file is staged in the root-owned sudoers.d itself, not a temp folder
        // other processes running as the user could tamper with. sudo skips names
        // containing a dot, so the staged copy is inert until the rename. visudo
        // checks it first: a malformed file would break sudo for every admin.
        let shell = """
            f=$(/usr/bin/mktemp /private/etc/sudoers.d/.agent-awake.XXXXXX) || exit 1
            echo '\(rule)' > "$f" && /bin/chmod 0440 "$f" && /usr/sbin/chown root:wheel "$f" \
            && /usr/sbin/visudo -cf "$f" && /bin/mv -f "$f" \(Self.sudoersFile)
            s=$?; /bin/rm -f "$f"; exit $s
            """
        let result = runAsAdmin(shell)
        refreshPermission()
        switch result {
        case .cancelled: return nil
        case .failed(let message): return message
        case .succeeded: return isPermitted ? nil : "The rule was installed but sudo still asks for a password."
        }
    }

    /// The system's current setting, or nil if pmset couldn't be read.
    static func systemSleepDisabled() -> Bool? {
        // Without the header the output isn't a settings listing (powerd unavailable,
        // say), and the absent SleepDisabled line below would wrongly read as false.
        guard let output = capture("/usr/bin/pmset", ["-g"]), output.contains("System-wide power settings") else {
            return nil
        }
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: \.isWhitespace).last == "1"
        }
        return false  // the line is absent while sleep is enabled
    }

    private func restored() {
        isDisabledByUs = false
        restoreFailed = false
        try? FileManager.default.removeItem(at: marker)
    }

    private func pmsetDisableSleep(_ disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", Self.pmset, "-a", "disablesleep", disabled ? "1" : "0"]) == 0
    }

    private enum AdminResult {
        case succeeded, cancelled
        case failed(String)
    }

    /// Runs a shell command as root behind the standard macOS password prompt.
    private func runAsAdmin(_ shell: String) -> AdminResult {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&error)
        guard let error else { return .succeeded }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "The admin command failed.")
    }

    private func startWatchdog() {
        // Exits as soon as this app does. It restores sleep only if the marker still
        // names this pid, so it can't undo a newer instance's setting.
        let script = """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 2; done
            [ "$(/bin/cat "$2" 2>/dev/null)" = "$1" ] || exit 0
            /usr/bin/sudo -n \(Self.pmset) -a disablesleep 0 && /bin/rm -f "$2"
            """
        spawn("/bin/sh", ["-c", script, "agent-awake-watchdog", String(getpid()), marker.path], detached: true)
    }
}

/// Battery charge when running on battery; nil on AC power or a Mac with no battery.
enum Battery {
    static func percentOnBattery() -> Int? {
        guard
            let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return current * 100 / max
        }
        return nil
    }
}

/// Runs a command and waits with a plain waitpid. Process.waitUntilExit spins the
/// run loop, which would let the SIGTERM handler quit the app in the middle of a
/// pmset call, before the result is recorded.
@discardableResult
private func run(_ path: String, _ arguments: [String]) -> Int32 {
    guard let pid = spawn(path, arguments, detached: false) else { return -1 }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        // Any other failure leaves status unset; reading 0 there would turn a failed
        // restore into a "restored" that deletes the marker.
        guard errno == EINTR else { return -1 }
    }
    // WIFEXITED / WEXITSTATUS, which Swift doesn't import.
    return status & 0x7f == 0 ? (status >> 8) & 0xff : -1
}

private func capture(_ path: String, _ arguments: [String]) -> String? {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = arguments
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Starts a process with its stdio on /dev/null. A detached one gets its own
/// session, so it outlives this process and a signal sent to our process group
/// (Ctrl-C in a terminal) doesn't reach it.
@discardableResult
private func spawn(_ path: String, _ arguments: [String], detached: Bool) -> pid_t? {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    if detached { posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    return posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0 ? pid : nil
}
