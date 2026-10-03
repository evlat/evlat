import AppKit
import Darwin

/// Where a session runs: the app `[Go to session]` brings forward.
///
/// A port of v1's `SessionHost`, living in `EvlatApp` because every lookup
/// under it is Darwin or AppKit. The walk itself is pure over the lookups in
/// `Probe`, so each chain measured on a real machine is a table in the tests.
/// Nothing here asks for a permission: `sysctl` (parent, argument area),
/// `proc_pidpath`, `Bundle` and `NSRunningApplication` read what any process
/// may read of its user's own (`ProcessReads.swift`). Choosing the tab inside
/// the app would need one (Accessibility, Apple Events) — except where the
/// app publishes its own link to the tab: see `TabLink`. A pane of herdr or
/// tmux is followed to its client: see `Multiplexer`.
///
/// **Not cached.** It is resolved when the card comes up and again on the
/// click: the app may have quit or come back in between.
enum SessionHost: Equatable {
    /// Found and running: it can be brought forward.
    case app(App)
    /// The session's app is known but not running. Said, never opened: the
    /// session went with it.
    case closed(name: String)
    /// No pid, or a chain that reaches no app: `screen`, ssh, or a
    /// multiplexer's server with no client found.
    case notFound

    struct App: Equatable {
        let bundleID: String
        let name: String
        let pid: Int32
        /// The session's own tab in that app, when the app publishes a link
        /// to it (`TabLink`); activation then opens it instead.
        var tab: URL? = nil
        /// The herdr pane the session runs in, when it runs in one: the tab
        /// is herdr's client, and herdr picks the pane inside it. The one
        /// multiplexer whose pane is selected (`Multiplexer.finish`).
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
        /// Every process's pid: a multiplexer's clients are found among them.
        var processes: () -> [Int32] = { [] }
        /// The unix sockets a process holds. A herdr client is a process
        /// connected to its server's client socket; `nil` when they cannot be
        /// read, and then they rule nobody out.
        var unixSockets: (Int32) -> [UnixSocket]? = { _ in nil }
        /// Whether a process has a controlling terminal; `nil` when unknown.
        var hasTerminal: (Int32) -> Bool? = { _ in nil }
        /// When a process started: of several clients, the newest is taken.
        var startedAt: (Int32) -> Date? = { _ in nil }
        /// A tmux server asked for a pane's session and its clients
        /// (`TmuxQuery.run`).
        var tmux: (TmuxQuery) -> TmuxReply? = { _ in nil }
        /// The established TCP connections a process holds: an ssh to a
        /// server is found by the server's end (`Ssh`). `nil` when they
        /// cannot be read.
        var tcpSockets: (Int32) -> [TCPSocket]? = { _ in nil }
        /// A process's working directory: an unnamed sandbox is named after
        /// its client's (`Sandbox`). `nil` when it cannot be read.
        var currentDirectory: (Int32) -> String? = { _ in nil }
    }

    /// One established TCP connection of a process: its own end and the
    /// other one.
    struct TCPSocket: Equatable {
        let local: Endpoint
        let remote: Endpoint
    }

    /// An address as `inet_ntop` writes it, and a port.
    struct Endpoint: Hashable {
        let address: String
        let port: Int
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
    /// A multiplexer's server met on the way is passed for its best client
    /// (`Multiplexer`).
    /// The walk ends at launchd, at a process that is its own parent, at one
    /// that cannot be read, or at the step limit.
    /// `forwarded` (`NAME=value` lines a server read, `Ssh`) fills a tab the
    /// walk could not read, and only for the app the walk reached: a value is
    /// inherited by whatever its tab starts, so it never chooses the app.
    static func resolve(pid: Int32?, forwarded: [String] = [], _ probe: Probe) -> SessionHost {
        guard let agent = pid else { return .notFound }
        switch walk(pid: agent, probe) {
        case (.app(var app), let terminal, let passedServer):
            // The environment is read only for an app that has a tab link,
            // and only its own variables are kept. It is the agent's, or
            // the client's when the session runs in a multiplexer's pane.
            // An agent whose walk passed a multiplexer's server without
            // finding its client names no tab: what it has is the terminal
            // that server was first started from, which may since have
            // closed (a closed tab's herdr client was seen alive and still
            // attached, deaf to TERM and HUP). The walk decides, not the
            // agent's variables: a terminal started from a pane inherits
            // them too.
            if TabLink.of(app.bundleID) != nil, terminal != agent || !passedServer {
                app.tab = TabLink.url(bundleID: app.bundleID, environment: probe.environment(terminal))
            }
            // Past a multiplexer's server the forwarded value is that
            // server's start environment, stale like the agent's own.
            if app.tab == nil, !passedServer, !forwarded.isEmpty {
                app.tab = TabLink.url(bundleID: app.bundleID, environment: forwarded, forwarded: true)
            }
            return .app(app)
        case (let other, _, _):
            return other
        }
    }

    /// The multiplexers whose servers the walk passes for a client.
    static let multiplexers: [Multiplexer.Type] = [Herdr.self, Tmux.self]

    /// The host, the process whose environment names its tab, and whether
    /// the walk went through a multiplexer's server on the way.
    private static func walk(pid: Int32, _ probe: Probe,
                             throughServers: Bool = true) -> (host: SessionHost, terminal: Int32, passedServer: Bool) {
        var current = pid
        var paths: [String] = []
        var passedServer = false
        for _ in 0..<maxSteps {
            guard current > 1 else { break }
            if let app = probe.regularApp(current) { return (.app(app), pid, passedServer) }
            if current != pid, let path = probe.executablePath(current) {
                paths.append(path)
                if let multiplexer = multiplexers.first(where: { $0.isServer(current, path: path, probe) }) {
                    passedServer = true
                    if throughServers,
                       let found = viaClient(of: multiplexer, server: current, path: path, agent: pid, probe) {
                        return (found.host, found.terminal, true)
                    }
                }
            }
            guard let up = probe.parent(current), up != current else { break }
            current = up
        }
        for path in paths.reversed() {
            let bundle = outermostApp(in: path).flatMap(probe.bundle) ?? helperBundle(path)
            guard let bundle else { continue }
            if let app = probe.running(bundle.bundleID) { return (.app(app), pid, passedServer) }
            return (.closed(name: bundle.name), pid, passedServer)
        }
        return (.notFound, pid, passedServer)
    }

    /// The first of a server's clients whose own walk reaches an app, or the
    /// first closed app named; `nil` when none reaches either. A server with
    /// no client is not a host: the walk goes on and ends `notFound`, or
    /// names a client's closed app.
    private static func viaClient(of multiplexer: Multiplexer.Type, server: Int32, path: String, agent: Int32,
                                  _ probe: Probe) -> (host: SessionHost, terminal: Int32)? {
        var closed: SessionHost?
        for client in multiplexer.clients(server: server, path: path, agent: agent, probe) {
            switch walk(pid: client, probe, throughServers: false).host {
            case .app(var app):
                multiplexer.finish(&app, server: path, agent: agent, probe)
                return (.app(app), client)
            case .closed(let name): closed = closed ?? .closed(name: name)
            case .notFound: continue
            }
        }
        return closed.map { ($0, server) }
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
                            startedAt: startedAt, tmux: TmuxQuery.run, tcpSockets: tcpSockets,
                            currentDirectory: currentDirectory)

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

}
