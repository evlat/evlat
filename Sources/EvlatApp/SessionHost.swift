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
    /// No pid, or a chain that reaches no app: `screen`, ssh, or a herdr or
    /// tmux server with no client found.
    case notFound

    struct App: Equatable {
        let bundleID: String
        let name: String
        let pid: Int32
        /// The session's own tab in that app, when the app publishes a link
        /// to it (`TabLink`); activation then opens it instead.
        var tab: URL? = nil
        /// The herdr pane the session runs in, when it runs in one: the tab
        /// is herdr's client, and herdr picks the pane inside it.
        var herdr: HerdrPane? = nil
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
        /// A process's arguments as it was `exec`'d, `argv[0]` first.
        var arguments: (Int32) -> [String] = { _ in [] }
        /// Every process's pid: a herdr server's clients are found among them.
        var processes: () -> [Int32] = { [] }
        /// The unix sockets a process holds. A herdr client is a process
        /// connected to its server's client socket; `nil` when they cannot be
        /// read, and then they rule nobody out.
        var unixSockets: (Int32) -> [UnixSocket]? = { _ in nil }
        /// Whether a process has a controlling terminal; `nil` when unknown.
        var hasTerminal: (Int32) -> Bool? = { _ in nil }
        /// When a process started: of several clients, the newest is taken.
        var startedAt: (Int32) -> Date? = { _ in nil }
        /// A tmux server asked for a pane's session and its clients.
        var tmux: (TmuxQuery) -> TmuxReply? = { _ in nil }
    }

    /// One unix socket of a process: its own control block, the one it is
    /// connected to (`0` when none), and the path it is bound or was accepted
    /// at. A client's `peer` is its server's accepted socket's `pcb`: what
    /// `lsof -U` prints as `->0x…`.
    struct UnixSocket: Equatable {
        let pcb: UInt64
        let peer: UInt64
        var path: String? = nil
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
    /// A herdr or tmux server met on the way is passed for its client: see
    /// `viaHerdr` and `viaTmux`.
    /// The walk ends at launchd, at a process that is its own parent, at one
    /// that cannot be read, or at the step limit.
    static func resolve(pid: Int32?, _ probe: Probe) -> SessionHost {
        guard let agent = pid else { return .notFound }
        switch walk(pid: agent, probe) {
        case (.app(var app), let terminal):
            // The environment is read only for an app that has a tab link,
            // and only its own variables are kept. It is the agent's, or
            // the client's when the session runs in a herdr or tmux pane.
            // A pane whose client was not found names no tab: what it has
            // is the terminal its server was first started from, which may
            // since have closed (a closed tab's herdr client was seen alive
            // and still attached, deaf to TERM and HUP).
            if TabLink.of(app.bundleID) != nil {
                let environment = probe.environment(terminal)
                if terminal != agent || !isMultiplexed(environment) {
                    app.tab = TabLink.url(bundleID: app.bundleID, environment: environment)
                }
            }
            return .app(app)
        case (let other, _):
            return other
        }
    }

    /// Whether an agent's environment says it runs in a herdr or tmux pane.
    static func isMultiplexed(_ environment: [String]) -> Bool {
        environment.contains { line in
            line == "HERDR_ENV=1" || line == "TERM_PROGRAM=herdr"
                || (line.hasPrefix("TMUX=") && line.count > "TMUX=".count)
        }
    }

    /// The host, and the process whose environment names its tab.
    private static func walk(pid: Int32, _ probe: Probe,
                             throughServers: Bool = true) -> (host: SessionHost, terminal: Int32) {
        var current = pid
        var paths: [String] = []
        for _ in 0..<maxSteps {
            guard current > 1 else { break }
            if let app = probe.regularApp(current) { return (.app(app), pid) }
            if current != pid, let path = probe.executablePath(current) {
                paths.append(path)
                if throughServers, let found = viaHerdr(server: current, path: path, agent: pid, probe)
                    ?? viaTmux(server: current, path: path, agent: pid, probe) {
                    return found
                }
            }
            guard let up = probe.parent(current), up != current else { break }
            current = up
        }
        for path in paths.reversed() {
            let bundle = outermostApp(in: path).flatMap(probe.bundle) ?? helperBundle(path)
            guard let bundle else { continue }
            if let app = probe.running(bundle.bundleID) { return (.app(app), pid) }
            return (.closed(name: bundle.name), pid)
        }
        return (.notFound, pid)
    }

    /// herdr runs its panes under a server it parents to launchd, so the
    /// walk from an agent in a pane never reaches the terminal herdr is shown
    /// in. That terminal is wherever a client attached to the server runs:
    /// another `herdr` of the same session, found among all processes and
    /// walked like an agent. Its environment, not the agent's, names the tab
    /// (cmux's ids): the server's panes inherit the terminal the server was
    /// first started from, which may since have closed.
    ///
    /// A client counts only while it is connected to the server's client
    /// socket and has a terminal: a closed tab's client was seen alive with
    /// neither a terminal nor a reason to leave, still connected. Every
    /// client shows the same view (herdr 0.9.3, seen in two windows at
    /// once), so any live one is right; the newest is taken, being the tab
    /// the user opened last. Pids are no order: a client started later held
    /// a lower one. A server with no client is not a host: the walk goes on
    /// and ends `notFound`, or names a client's closed app.
    static func viaHerdr(server: Int32, path: String, agent: Int32,
                         _ probe: Probe) -> (host: SessionHost, terminal: Int32)? {
        guard (path as NSString).lastPathComponent == "herdr",
              probe.arguments(server).dropFirst().first == "server" else { return nil }
        let session = herdrSession(environment: probe.environment(server))
        let accepted = probe.unixSockets(server).map { sockets in
            Set(sockets.filter { ($0.path.map { ($0 as NSString).lastPathComponent }) == "herdr-client.sock" }
                .map(\.pcb))
        }
        let clients = probe.processes().filter { client in
            guard client != server, let executable = probe.executablePath(client),
                  (executable as NSString).lastPathComponent == "herdr",
                  let named = herdrClientSession(arguments: probe.arguments(client)),
                  (named ?? herdrSession(environment: probe.environment(client))) == session,
                  probe.hasTerminal(client) != false else { return false }
            guard let accepted else { return true }
            return (probe.unixSockets(client) ?? []).contains { accepted.contains($0.peer) }
        }
        let newestFirst = clients.sorted { a, b in
            switch (probe.startedAt(a), probe.startedAt(b)) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a > b
            }
        }
        return firstHost(of: newestFirst, server: server, probe) { app in
            app.herdr = HerdrPane.of(herdr: path, environment: probe.environment(agent))
        }
    }

    /// tmux keeps a view per client, so the client is the one that last did
    /// something in the pane's session (`client_activity`). The pane is
    /// named by the agent's own `TMUX` and `TMUX_PANE`, the server asked
    /// with its own executable. tmux's pane is not selected.
    static func viaTmux(server: Int32, path: String, agent: Int32,
                        _ probe: Probe) -> (host: SessionHost, terminal: Int32)? {
        guard (path as NSString).lastPathComponent == "tmux",
              let query = TmuxQuery.of(executable: path, environment: probe.environment(agent)),
              query.server == server, let reply = probe.tmux(query) else { return nil }
        let clients = reply.clients
            .filter { $0.session == reply.session && probe.hasTerminal($0.pid) != false }
            .sorted { ($0.activity, $0.pid) > ($1.activity, $1.pid) }
            .map(\.pid)
        return firstHost(of: clients, server: server, probe) { _ in }
    }

    /// The first client whose own walk reaches an app, or the first closed
    /// app named; `nil` when none reaches either.
    private static func firstHost(of clients: [Int32], server: Int32, _ probe: Probe,
                                  finish: (inout App) -> Void) -> (host: SessionHost, terminal: Int32)? {
        var closed: SessionHost?
        for client in clients {
            switch walk(pid: client, probe, throughServers: false).host {
            case .app(var app):
                finish(&app)
                return (.app(app), client)
            case .closed(let name): closed = closed ?? .closed(name: name)
            case .notFound: continue
            }
        }
        return closed.map { ($0, server) }
    }

    /// The session a herdr server serves: `HERDR_SESSION`, or the default.
    static func herdrSession(environment: [String]) -> String {
        let line = environment.first { $0.hasPrefix("HERDR_SESSION=") }
        let name = line.map { String($0.dropFirst("HERDR_SESSION=".count)) } ?? ""
        return name.isEmpty ? "default" : name
    }

    /// A herdr client's arguments: `.some(nil)` for a bare `herdr` (its
    /// session is its environment's), `.some(name)` for `--session <name>`
    /// or `session attach <name>`, `nil` for anything else — the CLI's own
    /// subcommands (`herdr pane list`) attach to nothing.
    static func herdrClientSession(arguments: [String]) -> String?? {
        let rest = Array(arguments.dropFirst())
        switch rest.count {
        case 0:
            return .some(nil)
        case 1 where rest[0].hasPrefix("--session=") && rest[0].count > "--session=".count:
            return .some(String(rest[0].dropFirst("--session=".count)))
        case 2 where rest[0] == "--session" && !rest[1].isEmpty:
            return .some(rest[1])
        case 3 where rest[0] == "session" && rest[1] == "attach" && !rest[2].isEmpty:
            return .some(rest[2])
        default:
            return nil
        }
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
                            environment: environment, arguments: arguments, processes: allPIDs,
                            unixSockets: unixSockets, hasTerminal: hasTerminal,
                            startedAt: AppController.processStartedAt, tmux: TmuxQuery.run)

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
        app.herdr?.focus()
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

    /// The arguments the process was `exec`'d with, from the same area.
    static func arguments(_ pid: Int32) -> [String] {
        procArgs(pid).map(arguments(procArgs:)) ?? []
    }

    /// Every pid, from `proc_listallpids`. The count can grow between the
    /// sizing call and the read, so the buffer has room to spare.
    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    /// The process's unix sockets (`PROC_PIDFDSOCKETINFO`), readable without
    /// a permission for the user's own processes. `nil` when the descriptor
    /// list cannot be read at all.
    static func unixSockets(_ pid: Int32) -> [UnixSocket]? {
        guard pid > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        // Room for descriptors opened between the sizing call and the read.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return nil }
        return fds.prefix(Int(filled) / stride).compactMap { fd -> UnixSocket? in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return nil }
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_UN) else { return nil }
            let un = info.psi.soi_proto.pri_un
            var address = un.unsi_addr.ua_sun
            let path = withUnsafeBytes(of: &address.sun_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return UnixSocket(pcb: info.psi.soi_pcb, peer: un.unsi_conn_pcb, path: path.isEmpty ? nil : path)
        }
    }

    /// Whether the process has a controlling terminal (`e_tdev` is not
    /// `NODEV`); `nil` when it cannot be read.
    static func hasTerminal(_ pid: Int32) -> Bool? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_tdev != -1
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
        split(procArgs: buffer).environment
    }

    /// The arguments in a `KERN_PROCARGS2` buffer, as `environment` reads it.
    static func arguments(procArgs buffer: [UInt8]) -> [String] {
        split(procArgs: buffer).arguments
    }

    private static func split(procArgs buffer: [UInt8]) -> (arguments: [String], environment: [String]) {
        let head = MemoryLayout<Int32>.size
        guard buffer.count > head else { return ([], []) }
        let argc = buffer[0..<head].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var index = buffer[head...].firstIndex(of: 0) ?? buffer.endIndex
        while index < buffer.endIndex, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        var environment: [String] = []
        while index < buffer.endIndex {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.endIndex
            if end == index { break }
            let string = String(decoding: buffer[index..<end], as: UTF8.self)
            if arguments.count < argc {
                arguments.append(string)
            } else {
                environment.append(string)
            }
            index = end + 1
        }
        return (arguments, environment)
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

/// The herdr pane an agent runs in, and how to select it. herdr gives every
/// pane `HERDR_PANE_ID` (`w4:p2`) and `HERDR_SOCKET_PATH`, set when it starts
/// the pane — unlike the terminal's variables, which the pane inherits from
/// wherever the server was first started. `herdr agent focus <pane>` selects
/// the pane's workspace, tab and pane in every attached client (seen working
/// on herdr 0.9.1, run with no other environment).
///
/// Run as the server's own executable with fixed arguments, no shell: the
/// pane id is checked, and the command only selects.
struct HerdrPane: Equatable {
    let executable: String
    let pane: String
    let socket: String?

    /// `nil` when the environment names no pane, or a value that is not one.
    static func of(herdr executable: String, environment: [String]) -> HerdrPane? {
        func value(_ name: String) -> String? {
            environment.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        guard executable.hasPrefix("/"), let pane = value("HERDR_PANE_ID"), isPaneID(pane) else { return nil }
        let socket = value("HERDR_SOCKET_PATH").flatMap { $0.hasPrefix("/") ? $0 : nil }
        return HerdrPane(executable: executable, pane: pane, socket: socket)
    }

    /// 1–64 ASCII letters, digits, `:`, `-` and `_`; never a leading `-`,
    /// which the command would read as an option.
    static func isPaneID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.first != "-" && id.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || ":-_".contains(character))
        }
    }

    var arguments: [String] { ["agent", "focus", pane] }

    /// Only the socket is passed: the pane's session is the socket's.
    var environment: [String: String] { socket.map { ["HERDR_SOCKET_PATH": $0] } ?? [:] }

    /// Fire and forget: a pane closed since is herdr's error, not Evlat's.
    func focus() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// A tmux pane, named by the agent's own environment: `TMUX` is
/// `<socket>,<server pid>,<session index>` and `TMUX_PANE` is `%<n>`. Both
/// are checked before they reach the server's arguments.
struct TmuxQuery: Equatable {
    let executable: String
    let socket: String
    let server: Int32
    let pane: String

    static func of(executable: String, environment: [String]) -> TmuxQuery? {
        func value(_ name: String) -> String? {
            environment.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        guard executable.hasPrefix("/"), let tmux = value("TMUX"), let pane = value("TMUX_PANE"),
              pane.count > 1, pane.count <= 12, pane.first == "%",
              pane.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        // The socket is a path and could hold a comma; the last two fields
        // are numbers.
        let fields = tmux.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3, let server = Int32(fields[fields.count - 2]), server > 1 else { return nil }
        let socket = fields.dropLast(2).joined(separator: ",")
        guard socket.hasPrefix("/") else { return nil }
        return TmuxQuery(executable: executable, socket: socket, server: server, pane: pane)
    }

    /// One call, two commands: the pane's session, then every client with
    /// its last activity and session. No shell; `;` is tmux's separator.
    var arguments: [String] {
        ["-S", socket, "display-message", "-p", "-t", pane, "#{session_id}", ";",
         "list-clients", "-F", "#{client_pid} #{client_activity} #{session_id}"]
    }

    /// How long the card waits for tmux. It answers from memory; a server
    /// that does not is not waited for.
    static let timeout: TimeInterval = 0.5

    static func run(_ query: TmuxQuery) -> TmuxReply? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: query.executable)
        process.arguments = query.arguments
        process.environment = [:]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return TmuxReply.parse(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

/// What tmux said: the pane's session (`$<n>`) and its clients.
struct TmuxReply: Equatable {
    struct Client: Equatable {
        let pid: Int32
        let activity: Int
        let session: String
    }

    let session: String
    let clients: [Client]

    /// The first line is the session; each line after it a client. A line
    /// that is not one is skipped; a first line that is not one is no reply.
    static func parse(_ output: String) -> TmuxReply? {
        let lines = output.split(separator: "\n").map(String.init)
        guard let session = lines.first, session.hasPrefix("$"), !session.contains(" ") else { return nil }
        let clients = lines.dropFirst().compactMap { line -> Client? in
            let fields = line.split(separator: " ")
            guard fields.count == 3, let pid = Int32(fields[0]), pid > 1,
                  let activity = Int(fields[1]) else { return nil }
            return Client(pid: pid, activity: activity, session: String(fields[2]))
        }
        return TmuxReply(session: session, clients: clients)
    }
}
