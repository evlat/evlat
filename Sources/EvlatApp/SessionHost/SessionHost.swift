import AppKit
import Darwin
import EvlatCore

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
        /// What herdr said of the session's pane, when the walk reached the
        /// app through a herdr client: the tab is herdr's client, and herdr
        /// picks the pane inside it (`.pane`). The one multiplexer whose pane
        /// is selected (`Multiplexer.finish`).
        var herdr: HerdrLookup? = nil
        /// What a remote session's server said of the herdr pane the
        /// session runs in there (`RemoteHost.Connection.herdrPane`); `nil`
        /// on this Mac, and for a remote session in no herdr pane. The
        /// click selects it on the server (`RemoteHostLookup.select`), not
        /// here: this is only what the card may promise.
        var serverPane: RemoteHost.Pane? = nil
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
        /// One request line to a herdr server's API socket, under the
        /// action's one deadline (`HerdrSocket.session`).
        var herdr: HerdrSocket.Call = { _, _ in .unreachable }
        /// The established TCP connections a process holds: an ssh to a
        /// server is found by the server's end (`Ssh`). `nil` when they
        /// cannot be read.
        var tcpSockets: (Int32) -> [TCPSocket]? = { _ in nil }
        /// A process's working directory: an unnamed sandbox is named after
        /// its client's (`Sandbox`). `nil` when it cannot be read.
        var currentDirectory: (Int32) -> String? = { _ in nil }
        /// The device of a process's controlling terminal; `nil` when it has
        /// none or it cannot be read.
        var terminalDevice: (Int32) -> Int32? = { _ in nil }
        /// The pty masters a process holds, by number (`ptyNumber`): a
        /// terminal holds its tabs'. `nil` when its descriptors cannot be
        /// read, and then it is nobody's owner and rules nobody out.
        var ptyMasters: (Int32) -> [Int32]? = { _ in nil }
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
    /// (`Multiplexer`). Failing both passes, the terminal's master is
    /// followed to the processes that hold it (`walk`).
    /// The walk ends at launchd, at a process that is its own parent, at one
    /// that cannot be read, or at the step limit.
    /// `forwarded` (`NAME=value` lines a server read, `Ssh`) fills a tab the
    /// walk could not read, and only for the app the walk reached: a value is
    /// inherited by whatever its tab starts, so it never chooses the app.
    /// With `throughServers` off no multiplexer's client is looked for: no
    /// `tmux` runs and no herdr socket is opened, and a session in a pane
    /// names no tab — the rule below gives none past a server.
    static func resolve(pid: Int32?, forwarded: [String] = [], throughServers: Bool = true,
                        _ probe: Probe) -> SessionHost {
        guard let agent = pid else { return .notFound }
        switch walk(pid: agent, probe, throughServers: throughServers) {
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
    ///
    /// A third pass, only when the climb reached no app and passed no
    /// multiplexer's server: the processes that hold the master of `pid`'s
    /// terminal. A terminal that relaunches and takes its tabs over keeps
    /// their masters, while each old tab's `login` is left to launchd, so
    /// the chain up from the session reaches nothing (Bateri 0.4.0,
    /// measured). Every owner is climbed, and only when all of them reach
    /// the one same app is it the host: two apps, or two copies of one, say
    /// nothing of which the tab is in. An owner's own climb does not look
    /// for owners again. The tab is still read from `pid`'s environment,
    /// never an owner's: an owner's is the tab it was itself started from.
    /// Past a server the master is the server's, and its holders say
    /// nothing of the session's terminal. The scan reads every process's
    /// descriptors, so a chain that finds its host never pays for it.
    private static func walk(pid: Int32, _ probe: Probe,
                             throughServers: Bool = true) -> (host: SessionHost, terminal: Int32, passedServer: Bool) {
        let climbed = climb(pid: pid, probe, throughServers: throughServers)
        guard climbed.host == .notFound, !climbed.passedServer,
              let device = probe.terminalDevice(pid) else { return climbed }
        let owners = probe.processes().filter { owner in
            owner != pid && probe.ptyMasters(owner).map { holdsMaster(of: device, masters: $0) } == true
        }
        // The owner is the terminal itself, never in a pane: asking a
        // multiplexer for its clients would only spend the action's deadline.
        let hosts = owners.map { climb(pid: $0, probe, throughServers: false).host }
        guard case .app(let app)? = hosts.first, hosts.allSatisfy({ $0 == .app(app) }) else { return climbed }
        return (.app(app), pid, false)
    }

    /// The walk up the parents, then the bundles on the way (see `resolve`).
    private static func climb(pid: Int32, _ probe: Probe,
                              throughServers: Bool) -> (host: SessionHost, terminal: Int32, passedServer: Bool) {
        var current = pid
        // The process before `current` in the walk: at a server, the pane's
        // root process.
        var previous = pid
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
                       let found = viaClient(of: multiplexer, server: current, path: path, root: previous,
                                             agent: pid, probe) {
                        return (found.host, found.terminal, true)
                    }
                }
            }
            guard let up = probe.parent(current), up != current else { break }
            previous = current
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
    private static func viaClient(of multiplexer: Multiplexer.Type, server: Int32, path: String, root: Int32,
                                  agent: Int32, _ probe: Probe) -> (host: SessionHost, terminal: Int32)? {
        var closed: SessionHost?
        for client in multiplexer.clients(server: server, path: path, agent: agent, probe) {
            switch walk(pid: client, probe, throughServers: false).host {
            case .app(var app):
                multiplexer.finish(&app, server: server, root: root, agent: agent, probe)
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

    /// The number a pty's two ends share: the minor of either device
    /// (`sys/types.h`'s `minor()`, a macro Swift does not import). Measured:
    /// `/dev/ttys018` is device 16,18 and its master, open on `/dev/ptmx`,
    /// 15,18.
    static func ptyNumber(_ device: Int32) -> Int32 { device & 0xff_ffff }

    /// Whether a process holding `masters` holds the master of the terminal
    /// `device`.
    static func holdsMaster(of device: Int32, masters: [Int32]) -> Bool {
        masters.contains(ptyNumber(device))
    }

    /// `--list`'s word for it. Names only: the pid stays out of anything that
    /// ends up pasted into a bug report. What herdr said of the pane follows.
    var diagnostic: String {
        switch self {
        case .app(let app): return "\(app.name) (\(app.bundleID))" + (app.herdr.map { "  ·  \($0.diagnostic)" } ?? "")
        case .closed(let name): return "\(name) (closed)"
        case .notFound: return "no terminal"
        }
    }


    // MARK: - The real lookups

    /// A new one per user action: its herdr calls share one deadline from
    /// the first of them (`HerdrSocket.session`), and so does the pane it
    /// finds. Read it once per action; never keep it. The pty masters are
    /// kept for the action too: several `ssh` candidates or clients may each
    /// fall back to the owners, and every process's descriptors are read
    /// once.
    static var live: Probe {
        Probe(parent: parentPID, regularApp: regularApp,
              executablePath: executablePath, bundle: bundle, running: runningApp,
              environment: environment, arguments: arguments, processes: allPIDs,
              unixSockets: unixSockets, hasTerminal: hasTerminal,
              startedAt: startedAt, tmux: TmuxQuery.run, herdr: HerdrSocket.session(), tcpSockets: tcpSockets,
              currentDirectory: currentDirectory, terminalDevice: terminalDevice,
              ptyMasters: kept(ptyMasters))
    }

    /// A read answered once per pid, an unreadable one (`nil`) included.
    static func kept(_ read: @escaping (Int32) -> [Int32]?) -> (Int32) -> [Int32]? {
        var known: [Int32: [Int32]?] = [:]
        return { pid in
            if let answer = known[pid] { return answer }
            let answer = read(pid)
            known[pid] = .some(answer)
            return answer
        }
    }

    static func resolve(pid: Int32?) -> SessionHost { resolve(pid: pid, live) }

    /// The walk the news asks of (`TabFocus`): only a tab it is sure of. A
    /// pane's client is the tab someone looks at, which may show another
    /// pane, and finding it runs `tmux` or spends herdr's deadline.
    static func resolveShallow(pid: Int32?) -> SessionHost { resolve(pid: pid, throughServers: false, live) }

    /// The same path v1 measured (macOS 26.4.1): from a
    /// background `LSUIElement` app this brings the target forward. Evlat
    /// itself is not activated.
    ///
    /// With a tab link the link is opened instead, by the running copy's own
    /// bundle: a development build and an installed copy of the same app can
    /// both be on the machine, and the default handler may not be the one
    /// the session is in. The app selects the tab and comes forward itself;
    /// if the open fails, the app is still brought forward.
    ///
    /// A herdr pane is selected first, and waited for (within the click's
    /// deadline), so the window comes up on it; checked before, so a test
    /// run offstage never selects a pane in the user's herdr.
    @discardableResult
    static func activate(_ app: App) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: app.pid),
              !running.isTerminated, !WindowStage.isOffstage else { return false }
        return activate(app, focus: { $0.focus() }, bringForward: { bringForward($0, running) })
    }

    /// The order, apart from AppKit: the pane, then the window, which comes
    /// whether or not the pane could be selected.
    static func activate(_ app: App, focus: (HerdrPane) -> Bool, bringForward: (App) -> Bool) -> Bool {
        if case .pane(let pane) = app.herdr { _ = focus(pane) }
        return bringForward(app)
    }

    private static func bringForward(_ app: App, _ running: NSRunningApplication) -> Bool {
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
