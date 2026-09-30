import AppKit
import Darwin

/// Where a session runs: the app `[Go to session]` brings forward.
///
/// A port of v1's `SessionHost`, living in `EvlatApp` because every lookup
/// under it is Darwin or AppKit. The walk itself is pure over the lookups in
/// `Probe`, so each chain measured on a real machine is a table in the tests.
/// Nothing here asks for a permission: `sysctl` (parent, argument area),
/// `proc_pidpath`, `Bundle` and `NSRunningApplication` read what any process
/// may read of its user's own. Choosing the tab inside the app would need
/// one (Accessibility, Apple Events) — except where the app publishes its own
/// link to the tab: see `TabLink`.
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
        /// The session's own tab in that app, when the app publishes a link
        /// to it (`TabLink`); activation then opens it instead.
        var tab: URL? = nil
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
        /// A process's environment as it was at `exec`, `NAME=value` lines.
        var environment: (Int32) -> [String] = { _ in [] }
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
        guard let agent = pid else { return .notFound }
        switch walk(pid: agent, probe) {
        case .app(var app):
            // The agent's environment is read only for an app that has a
            // tab link, and only its own variables are kept.
            if TabLink.of(app.bundleID) != nil {
                app.tab = TabLink.url(bundleID: app.bundleID, environment: probe.environment(agent))
            }
            return .app(app)
        case let other:
            return other
        }
    }

    private static func walk(pid: Int32, _ probe: Probe) -> SessionHost {
        var current = pid
        var paths: [String] = []
        for _ in 0..<maxSteps {
            guard current > 1 else { break }
            if let app = probe.regularApp(current) { return .app(app) }
            if current != pid, let path = probe.executablePath(current) { paths.append(path) }
            guard let up = probe.parent(current), up != current else { break }
            current = up
        }
        for path in paths.reversed() {
            let bundle = outermostApp(in: path).flatMap(probe.bundle) ?? helperBundle(path)
            guard let bundle else { continue }
            if let app = probe.running(bundle.bundleID) { return .app(app) }
            return .closed(name: bundle.name)
        }
        return .notFound
    }

    /// Hosts whose terminal server lives outside their bundle. iTerm copies
    /// its server to `~/Library/Application Support/iTerm2/iTermServer-<version>`
    /// and parents it to launchd, so no path in the chain names `iTerm.app`
    /// (seen live with 3.7.3, server 3.4.23). The directory is iTerm's own
    /// under the user's Application Support, matched whole.
    static func helperBundle(_ path: String) -> (bundleID: String, name: String)? {
        let tail = (path as NSString).pathComponents.suffix(4)
        guard tail.count == 4, Array(tail.prefix(3)) == ["Library", "Application Support", "iTerm2"],
              tail.last?.hasPrefix("iTermServer-") == true else { return nil }
        return ("com.googlecode.iterm2", "iTerm2")
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
                            executablePath: executablePath, bundle: bundle, running: runningApp,
                            environment: environment)

    static func resolve(pid: Int32?) -> SessionHost { resolve(pid: pid, live) }

    /// The same path v1 measured (macOS 26.4.1): from a
    /// background `LSUIElement` app this brings the target forward. Evlat
    /// itself is not activated.
    ///
    /// With a tab link the link is opened instead, by the running copy's own
    /// bundle: a development build and an installed copy of the same app can
    /// both be on the machine, and the default handler may not be the one
    /// the session is in. The app selects the tab and comes forward itself;
    /// if the open fails, the app is still brought forward.
    @discardableResult
    static func activate(_ app: App) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid),
              !running.isTerminated, !WindowStage.isOffstage else { return false }
        if let tab = app.tab, let bundle = running.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([tab], withApplicationAt: bundle, configuration: configuration) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async { running.activate(options: [.activateAllWindows]) }
            }
            return true
        }
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
        guard let buffer = procArgs(pid) else { return nil }
        let start = MemoryLayout<Int32>.size
        let end = buffer[start...].firstIndex(of: 0) ?? buffer.endIndex
        let path = String(decoding: buffer[start..<end], as: UTF8.self)
        return path.hasPrefix("/") ? path : nil
    }

    /// The environment the process was `exec`'d with (`KERN_PROCARGS2`, the
    /// same area as `launchPath`): what the agent inherited from its
    /// terminal, not what it set since — which is what a tab link is.
    static func environment(_ pid: Int32) -> [String] {
        procArgs(pid).map(environment(procArgs:)) ?? []
    }

    /// `KERN_PROCARGS2`, whole: an `argc`, the executable path, NUL padding,
    /// `argc` arguments, then the environment up to an empty string.
    static func procArgs(_ pid: Int32) -> [UInt8]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return Array(buffer[..<size])
    }

    /// The environment in a `KERN_PROCARGS2` buffer. Pure; a short or
    /// truncated buffer gives what it holds, never reads past it.
    static func environment(procArgs buffer: [UInt8]) -> [String] {
        let head = MemoryLayout<Int32>.size
        guard buffer.count > head else { return [] }
        let argc = buffer[0..<head].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var index = buffer[head...].firstIndex(of: 0) ?? buffer.endIndex
        while index < buffer.endIndex, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        var skipped = 0
        while index < buffer.endIndex {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.endIndex
            if end == index { break }
            if skipped < argc {
                skipped += 1
            } else {
                strings.append(String(decoding: buffer[index..<end], as: UTF8.self))
            }
            index = end + 1
        }
        return strings
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

/// Apps that tell the agent which of their tabs it runs in, in a variable
/// it inherits. Opening the tab's link is the app's own way to select it —
/// no permission — and every handler here only shows: no byte reaches the
/// shell, nothing runs.
///
/// - Bateri, Metalterm and Warp hand each shell its tab's link ready made
///   (Bateri's `open_urls`, Metalterm's `tab/`, Warp's `WARP_FOCUS_URL`).
/// - iTerm hands it `ITERM_SESSION_ID` (`w0t0p0:<UUID>`), and
///   `iterm2:reveal?sessionid=` that whole value reveals the session: iTerm
///   splits it at the `:` and looks the UUID up (`revealSessionID:`), so the
///   UUID alone finds nothing. Of iTerm's URL commands this is the only one
///   used — others run commands.
/// - Claude's desktop app hands its Claude Code sessions their own id, and
///   `claude://code/continue?session=<id>` opens that session — the link its
///   own "Continue" menu and Spotlight entries use. An id it no longer knows
///   opens its Claude Code home, never another session. Undocumented: if it
///   changes, the app still comes forward.
/// - cmux hands each shell `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`, and
///   `cmux://workspace/<id>/surface/<id>` selects that tab — its navigation
///   link (`CmuxNavigationURLRequest` in cmux's source; seen working on
///   0.64.25). Its socket refuses a process started outside cmux, so the
///   link is the one way in.
///
/// The value is checked, not trusted: it is whatever the agent's environment
/// says, and `metalterm://tab/restart` is an action, not a tab. Bateri's ids
/// are UUIDs, Metalterm's 16 hex digits, Warp's 32, iTerm's a UUID after its
/// position, Claude's `local_` and a UUID (the app accepts
/// `local_[A-Za-z0-9-]{1,64}`), cmux's two UUIDs.
///
/// Terminal and Ghostty publish nothing an app can open: choosing their tab
/// takes Apple Events, a permission, so they are only brought forward.
struct TabLink {
    /// Read in this order; every one must be there.
    let variables: [String]
    /// The link, from the variables' values; `nil` when they are not one.
    let link: ([Substring]) -> URL?

    init(variable: String, link: @escaping (Substring) -> URL?) {
        variables = [variable]
        self.link = { values in values.first.flatMap(link) }
    }

    init(variables: [String], link: @escaping ([Substring]) -> URL?) {
        self.variables = variables
        self.link = link
    }

    static let known: [String: TabLink] = [
        // Bateri ships as `dev.bateri.bateri` (seen installed); the older
        // id stays for copies built before the change.
        "dev.bateri.bateri": ready(variable: "BATERI_TAB_URL", prefix: "bateri://tab/"),
        "io.github.bateri.bateri": ready(variable: "BATERI_TAB_URL", prefix: "bateri://tab/"),
        "dev.metalterm.Metalterm": ready(variable: "METALTERM_TAB_URL", prefix: "metalterm://tab/"),
        "dev.warp.Warp-Stable": ready(variable: "WARP_FOCUS_URL", prefix: "warp://session/"),
        "com.googlecode.iterm2": TabLink(variable: "ITERM_SESSION_ID") { value in
            guard let colon = value.firstIndex(of: ":"),
                  isID(value[..<colon], alphanumeric: true),
                  isID(value[value.index(after: colon)...], alphanumeric: false) else { return nil }
            return URL(string: "iterm2:reveal?sessionid=\(value)")
        },
        "com.anthropic.claudefordesktop": TabLink(variable: "CLAUDE_CODE_HOST_SESSION_ID") { value in
            guard value.hasPrefix("local_"), isID(value.dropFirst("local_".count), alphanumeric: true) else {
                return nil
            }
            return URL(string: "claude://code/continue?session=\(value)")
        },
        "com.cmuxterm.app": TabLink(variables: ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID"]) { values in
            guard values.count == 2, let workspace = UUID(uuidString: String(values[0])),
                  let surface = UUID(uuidString: String(values[1])) else { return nil }
            return URL(string: "cmux://workspace/\(workspace.uuidString)/surface/\(surface.uuidString)")
        },
    ]

    /// A variable that holds the link itself: `<prefix><hex id>`.
    private static func ready(variable: String, prefix: String) -> TabLink {
        TabLink(variable: variable) { value in
            guard value.hasPrefix(prefix), isID(value.dropFirst(prefix.count), alphanumeric: false) else {
                return nil
            }
            return URL(string: String(value))
        }
    }

    /// 1–64 ASCII characters: hex digits (or any letter and digit) and `-`.
    /// Nothing that could start a path, a query or a fragment.
    private static func isID(_ id: Substring, alphanumeric: Bool) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { character in
            character.isASCII && (character == "-" || character.isHexDigit
                                  || (alphanumeric && (character.isLetter || character.isNumber)))
        }
    }

    static func of(_ bundleID: String) -> TabLink? { known[bundleID] }

    /// The tab's link for that app, from the agent's environment; `nil` for
    /// another app, a missing variable or a value that is not one. The first
    /// occurrence counts, as `getenv` reads it.
    static func url(bundleID: String, environment: [String]) -> URL? {
        guard let entry = of(bundleID) else { return nil }
        var values: [Substring] = []
        for variable in entry.variables {
            guard let line = environment.first(where: { $0.hasPrefix(variable + "=") }) else { return nil }
            values.append(line.dropFirst(variable.count + 1))
        }
        return entry.link(values)
    }
}
