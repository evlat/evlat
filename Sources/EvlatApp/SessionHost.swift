import AppKit
import Darwin

/// Where a session runs: the app `[Go to session]` brings forward.
///
/// A port of v1's `SessionHost`, living in `EvlatApp` because every lookup
/// under it is Darwin or AppKit. The walk itself is pure over the lookups in
/// `Probe`, so each chain measured on a real machine is a table in the tests.
/// Nothing here asks for a permission: `sysctl` (parent, argument area),
/// `proc_pidpath`, `Bundle` and `NSRunningApplication` read what any process
/// may read of its user's own. Choosing the tab or the split inside the app
/// would need one, and is out of scope.
///
/// **Not cached.** It is resolved when the card comes up and again on the
/// click: the app may have quit or come back in between.
enum SessionHost: Equatable {
    /// Found and running: it can be brought forward.
    case app(App)
    /// The session's app is known but not running. Said, never opened: the
    /// session went with it.
    case closed(name: String)
    /// No pid, or a chain that reaches no app: `screen`, tmux, ssh.
    case notFound

    struct App: Equatable {
        let bundleID: String
        let name: String
        let pid: Int32
    }

    /// The lookups the walk makes, injected so the walk has no Darwin in it.
    struct Probe {
        /// A process's parent; `nil` when there is no such process.
        var parent: (Int32) -> Int32?
        /// The process as an app, only when it is a `.regular` one: shells
        /// and the agent are not apps, and Electron helpers are `.accessory`.
        var regularApp: (Int32) -> App?
        /// The process's executable, to find the bundle it ships in.
        var executablePath: (Int32) -> String?
        /// An `.app` bundle's id and display name, read from its `Info.plist`.
        var bundle: (String) -> (bundleID: String, name: String)?
        /// The running `.regular` app with that bundle id.
        var running: (String) -> App?
    }

    /// A guard against a broken chain; real chains are under ten.
    static let maxSteps = 64

    /// Two passes over the same walk:
    ///  1. up the parents from the agent, the first `.regular` app wins;
    ///  2. failing that, the **outermost** `.app` bundle an ancestor was
    ///     launched from, then that bundle's running app. Orca's pty server
    ///     is a helper parented to launchd — the walk never reaches the app,
    ///     but the helper's path still names `Orca.app`. The farthest
    ///     ancestor is asked first, since it is what hosts the terminal, and
    ///     the agent's own process is not asked at all: Claude Code ships as
    ///     `~/.local/share/claude/ClaudeCode.app/…/claude`, which is the
    ///     agent's bundle, not its terminal (seen on the live `--list`).
    /// The walk ends at launchd, at a process that is its own parent, at one
    /// that cannot be read, or at the step limit.
    static func resolve(pid: Int32?, _ probe: Probe) -> SessionHost {
        guard var current = pid else { return .notFound }
        var paths: [String] = []
        for _ in 0..<maxSteps {
            guard current > 1 else { break }
            if let app = probe.regularApp(current) { return .app(app) }
            if current != pid, let path = probe.executablePath(current) { paths.append(path) }
            guard let up = probe.parent(current), up != current else { break }
            current = up
        }
        for path in paths.reversed() {
            guard let bundlePath = outermostApp(in: path),
                  let bundle = probe.bundle(bundlePath) else { continue }
            if let app = probe.running(bundle.bundleID) { return .app(app) }
            return .closed(name: bundle.name)
        }
        return .notFound
    }

    /// The outermost `.app` directory in a path: a helper inside
    /// `Orca.app/Contents/Frameworks/Orca Helper.app` belongs to `Orca.app`.
    static func outermostApp(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.count > 4 && $0.hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components[...index]))
    }

    /// `--list`'s word for it. Names only: the pid stays out of anything that
    /// ends up pasted into a bug report.
    var diagnostic: String {
        switch self {
        case .app(let app): return "\(app.name) (\(app.bundleID))"
        case .closed(let name): return "\(name) (closed)"
        case .notFound: return "no terminal"
        }
    }

    // MARK: - The real lookups

    static let live = Probe(parent: parentPID, regularApp: regularApp,
                            executablePath: executablePath, bundle: bundle, running: runningApp)

    static func resolve(pid: Int32?) -> SessionHost { resolve(pid: pid, live) }

    /// The same path v1 measured (macOS 26.4.1): from a
    /// background `LSUIElement` app this brings the target forward. Evlat
    /// itself is not activated.
    @discardableResult
    static func activate(_ app: App) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid),
              !running.isTerminated else { return false }
        return running.activate(options: [.activateAllWindows])
    }

    /// `sysctl` answers an unknown pid with success and an empty result, so
    /// the size is checked too.
    static func parentPID(_ pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// `proc_pidpath` fails (`ENOENT`) once the file the process was started
    /// from has been replaced — an app that updated itself under a running
    /// helper, as Orca's pty server was on this machine. The path it was
    /// started with is still in its argument area (`KERN_PROCARGS2`), which
    /// is also readable without a permission for the user's own processes.
    static func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a macro Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        return launchPath(pid)
    }

    /// The executable path at the head of `KERN_PROCARGS2`: an `argc`, then
    /// the path the process was exec'd with.
    static func launchPath(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let start = MemoryLayout<Int32>.size
        let end = buffer[start..<size].firstIndex(of: 0) ?? size
        let path = String(decoding: buffer[start..<end], as: UTF8.self)
        return path.hasPrefix("/") ? path : nil
    }

    static func regularApp(_ pid: Int32) -> App? {
        guard pid > 0, let running = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app(running)
    }

    static func runningApp(_ bundleID: String) -> App? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .lazy.compactMap(app).first
    }

    private static func app(_ running: NSRunningApplication) -> App? {
        guard running.activationPolicy == .regular, !running.isTerminated,
              let id = running.bundleIdentifier else { return nil }
        return App(bundleID: id, name: running.localizedName ?? id, pid: running.processIdentifier)
    }

    /// A bundle with no window to bring forward (`LSUIElement`,
    /// `LSBackgroundOnly`) is nobody's terminal: it is skipped rather than
    /// reported "closed". The case seen live was a session whose parent was
    /// another `claude` started from `ClaudeCode.app`, parented to launchd.
    static func bundle(_ path: String) -> (bundleID: String, name: String)? {
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return nil }
        let plist = bundle.infoDictionary ?? [:]
        if plist["LSUIElement"] as? Bool == true || plist["LSBackgroundOnly"] as? Bool == true {
            return nil
        }
        let info = bundle.localizedInfoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return (id, name)
    }
}
