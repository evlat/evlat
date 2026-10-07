import Foundation
import EvlatCore

/// A remote session's terminal on this Mac: the user's own `ssh` to that
/// server, found from what the server said of the session's connection
/// (`RemoteHost.Reply`). From that `ssh` the walk is the local one
/// (`SessionHost.resolve`), tmux and herdr on this side included.
///
/// The candidates are the user's `ssh` processes connected to the **same
/// end** as Evlat's own tunnel to that machine. Not to the address the
/// server names alone: a NAT on either side, or a jump host, makes that
/// address one no `ssh` here holds. The tunnel goes the way the user's
/// `ssh` goes, so its end is theirs — DNS, NAT and `ProxyJump` included.
/// No tunnel, no candidate. The address the server names is an end too
/// (`serverEnd`): a host with two addresses gives the tunnel one and the
/// user's `ssh` the other — one `.local` name, an IPv6 for the tunnel and
/// an IPv4 for Bateri's, measured.
///
/// When the server says the agent has a terminal, an `ssh` with none of
/// its own that is no master is left out first (`askingTerminals`). Then,
/// in order:
///  1. the candidate whose local port is the server's client port (no NAT);
///  2. the only candidate, unless its start is past `apart` from the
///     connection's — then it is another connection;
///  3. the candidate whose start is nearest the connection's, on this Mac's
///     clock — within `nearest`, and every other one past `apart`;
///  4. otherwise ambiguous: the app alone when every candidate is in the
///     same one, else nothing. A tab chosen at random would be a lie.
/// The pick is walked as a local session. A tab link the terminal forwarded
/// over `ssh` and the server read (`Connection.forwarded`,
/// `TabLink.forwarded`) fills the tab the walk could not read — on this Mac
/// the `ssh` that carried it is Apple's, whose environment no other process
/// can read — checked by the rule of the app the walk reached, and only that
/// app's. It never picks the app: anything started from a tab (an editor,
/// another terminal, a local tmux) inherits the value, so a value alone
/// would open a tab the session is not in. Ambiguous picks in one app keep a
/// tab only when every one gives the same: riders of one `ControlMaster`
/// whose session's value names it.
/// A pick that is a `ControlMaster` with other `ssh` riding it is ambiguous
/// too: the server sees all of them as one connection. herdr's own master,
/// detached under `herdr --remote`, stands for that `herdr`
/// (`herdrRemoteClients`); any other master detached by `ControlPersist`
/// (parented to launchd: Bateri's own ssh, or the user's config) is in no
/// app, and stands for its riders — the `ssh` that made it among them,
/// though it keeps a copy of the connection's socket (`candidates`). The
/// forwarded value, the session's own, then names the tab.
/// Measured on an Ubuntu server (OpenSSH 9.6p1): the connection's `sshd`
/// started 0.11 s and −0.19 s from its Mac `ssh`, and the clocks were
/// within half a second.
enum Ssh {
    /// The farthest a chosen start may be from the connection's.
    static let nearest: TimeInterval = 2
    /// The nearest any other candidate's start may be.
    static let apart: TimeInterval = 10

    /// One of the user's `ssh` processes to the server's end, and its own
    /// ports there.
    struct Candidate: Equatable {
        let pid: Int32
        let localPorts: Set<Int>
    }

    /// The user's `ssh` processes connected where the tunnel `ssh` (`tunnel`)
    /// is, or to `server` (`serverEnd`). Evlat's own are never one: the
    /// tunnel, the installer's calls and a jump host's `ssh -W` under them
    /// all descend from `evlat`.
    ///
    /// One connection is one candidate. The `ssh` that made a master
    /// detached by `ControlPersist` rides it, yet keeps a copy of the
    /// connection's socket: the same port, started the same second
    /// (OpenSSH 10.2p1, measured). It is the master's rider, not a second
    /// connection, and the master stands for it.
    static func candidates(tunnel: Int32, evlat: Int32, server: SessionHost.Endpoint? = nil,
                           _ probe: SessionHost.Probe) -> [Candidate] {
        let pids = probe.processes()
        // Through `ProxyJump` the socket is the tunnel's child's.
        let tunnelSide = [tunnel] + pids.filter { $0 != tunnel && probe.parent($0) == tunnel }
        var ends = Set(tunnelSide.flatMap { probe.tcpSockets($0) ?? [] }.map(\.remote))
        guard !ends.isEmpty else { return [] }
        if let server { ends.insert(server) }
        let found: [Candidate] = pids.compactMap { pid in
            guard pid != tunnel, isSsh(pid, probe), !descends(pid, from: evlat, probe),
                  let sockets = probe.tcpSockets(pid) else { return nil }
            let ports = Set(sockets.filter { ends.contains($0.remote) }.map(\.local.port))
            return ports.isEmpty ? nil : Candidate(pid: pid, localPorts: ports)
        }
        guard found.count > 1 else { return found }
        let riding = Set(found.filter { probe.parent($0.pid) == 1 }.flatMap { muxClients(of: $0.pid, probe) })
        return found.filter { !riding.contains($0.pid) }
    }

    /// The end the server says the connection reached, written as this
    /// Mac writes the ends it reads (`inet_ntop`); `nil` for none, for one
    /// that is not an address, and for the server's loopback or an
    /// unspecified one, which no `ssh` here reaches. An IPv6 zone is the
    /// server's interface, not this Mac's, and is dropped; an IPv4 written
    /// as IPv6 (`::ffff:a.b.c.d`) is its IPv4.
    static func serverEnd(of connection: RemoteHost.Connection) -> SessionHost.Endpoint? {
        guard let text = connection.serverAddress,
              let bare = text.split(separator: "%", maxSplits: 1).first.map(String.init) else { return nil }
        var four = in_addr()
        var six = in6_addr()
        var bytes: [UInt8]
        if inet_pton(AF_INET, bare, &four) == 1 {
            bytes = withUnsafeBytes(of: &four) { Array($0) }
        } else if inet_pton(AF_INET6, bare, &six) == 1 {
            bytes = withUnsafeBytes(of: &six) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                bytes = Array(bytes.suffix(4))
            }
        } else {
            return nil
        }
        if bytes.count == 4 {
            guard bytes[0] != 127, bytes != [0, 0, 0, 0] else { return nil }
            return SessionHost.Endpoint(address: bytes.map(String.init).joined(separator: "."),
                                        port: connection.serverPort)
        }
        // `::` and `::1`.
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] <= 1 { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &six, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return SessionHost.Endpoint(address: String(cString: buffer), port: connection.serverPort)
    }

    /// The candidates that can carry a session with a terminal on the
    /// server (`Connection.terminal`): its `ssh` asked for one, so it has
    /// one of its own. One with none that is no master is another
    /// connection — Bateri's own `ssh -T` beside a tab's, started 1.6 s
    /// after it, measured — and is left out, unless none would remain. A
    /// master detached by `ControlPersist` has no terminal and stands for
    /// its riders; a terminal that cannot be read keeps its `ssh`. An
    /// `ssh -tt` with no terminal of its own asks for one anyway, and is
    /// no tab's either.
    static func askingTerminals(_ candidates: [Candidate], _ probe: SessionHost.Probe) -> [Candidate] {
        guard candidates.count > 1 else { return candidates }
        let kept = candidates.filter { probe.hasTerminal($0.pid) != false || !muxClients(of: $0.pid, probe).isEmpty }
        return kept.isEmpty ? candidates : kept
    }

    /// What the order above makes of the candidates (`StartMatch`).
    typealias Choice = StartMatch.Choice

    /// `ssh`'s thresholds: a lone `ssh` far from the connection's start is
    /// another connection.
    static let rule = StartMatch.Rule(nearest: nearest, apart: apart, aloneWithin: apart)

    static func choose(_ candidates: [Candidate], for connection: RemoteHost.Connection,
                       startedAt: (Int32) -> Date?) -> Choice {
        let exact = candidates.filter { $0.localPorts.contains(connection.clientPort) }
        if exact.count == 1 { return .one(exact[0].pid) }
        // Alone, unless its start says it is another connection: a session
        // started from another computer, or an `ssh` through the same jump
        // host to another server. Several, told apart by start.
        return StartMatch.choose(candidates.map(\.pid), start: connection.localStart, rule: rule,
                                 startedAt: startedAt)
    }

    /// The user's `ssh` processes riding `master`'s connection: connected to
    /// one of its unix sockets (`ControlMaster`). The server sees them all
    /// as the master's one connection, so which tab it is cannot be told.
    static func muxClients(of master: Int32, _ probe: SessionHost.Probe) -> [Int32] {
        let accepted = Set((probe.unixSockets(master) ?? []).map(\.pcb).filter { $0 != 0 })
        guard !accepted.isEmpty else { return [] }
        return probe.processes().filter { pid in
            pid != master && isSsh(pid, probe)
                && (probe.unixSockets(pid) ?? []).contains { $0.peer != 0 && accepted.contains($0.peer) }
        }
    }

    /// The `herdr --remote` processes whose `ssh` rides `master`, when the
    /// master is herdr's own; `nil` for any other. herdr runs its `ssh` with
    /// `ControlMaster=auto` and `ControlPersist=600` on a control socket of
    /// its own, so its first `ssh` detaches into a master parented to
    /// launchd (its arguments rewritten to `ssh: <socket> [mux]`), which
    /// holds the connection the server sees, and the bridge's `ssh` rides it
    /// as a child of the `herdr --remote` in the tab (herdr 0.9.3, measured).
    /// The master's walk reaches no app; the riders' `herdr` does, and its
    /// environment can be read. Only that chain: a detached master every one
    /// of whose riders is a child of a `herdr` run with `--remote`. Several
    /// such `herdr` are several tabs on one master, told apart by nothing.
    static func herdrRemoteClients(master: Int32, riders: [Int32], _ probe: SessionHost.Probe) -> [Int32]? {
        guard probe.parent(master) == 1, !riders.isEmpty else { return nil }
        var clients: [Int32] = []
        for rider in riders {
            guard let up = probe.parent(rider), up > 1, let path = probe.executablePath(up),
                  Herdr.isExecutable(path),
                  probe.arguments(up).dropFirst().contains("--remote") else { return nil }
            if !clients.contains(up) { clients.append(up) }
        }
        return clients
    }

    private static func isSsh(_ pid: Int32, _ probe: SessionHost.Probe) -> Bool {
        probe.executablePath(pid).map { ($0 as NSString).lastPathComponent == "ssh" } ?? false
    }

    private static func descends(_ pid: Int32, from ancestor: Int32, _ probe: SessionHost.Probe) -> Bool {
        var current = pid
        for _ in 0..<SessionHost.maxSteps {
            guard let up = probe.parent(current), up > 1, up != current else { return false }
            if up == ancestor { return true }
            current = up
        }
        return false
    }
}

extension SessionHost {
    /// A remote session's host on this Mac: the server's `reply` turned
    /// into one of the user's `ssh` (`Ssh`), then walked as a local session
    /// is. `tunnel` is the machine's tunnel `ssh`, `nil` while it is down.
    /// Ambiguous candidates all in one app give that app, with no tab and
    /// no pane: it is right to bring forward, and nothing more is known.
    /// The server's herdr pane is the session's whichever `ssh` was picked,
    /// so it rides to the app either way.
    ///
    /// `shallow` is the news's walk (`resolveShallow`): only a tab it is
    /// sure of, walked without looking for a multiplexer's client — an
    /// `ssh` in a local tmux or herdr pane names no tab. Riders of one
    /// master are walked as the card walks them: every one must reach the
    /// one app and give the one tab, which the session's forwarded value
    /// fills — each rider's session carries its own (measured). herdr's own
    /// master and candidates too close to tell apart are nothing at all,
    /// not the app alone. Whether the server walked from the agent itself
    /// (`Connection.direct`) is the caller's to have checked.
    static func resolve(remote reply: RemoteHost.Reply, tunnel: Int32?, evlat: Int32, shallow: Bool = false,
                        _ probe: Probe) -> SessionHost {
        guard case .connection(let connection) = reply, let tunnel else { return .notFound }
        let forwarded = connection.forwarded
        var candidates = Ssh.candidates(tunnel: tunnel, evlat: evlat, server: Ssh.serverEnd(of: connection), probe)
        if connection.terminal { candidates = Ssh.askingTerminals(candidates, probe) }
        let host: SessionHost
        switch Ssh.choose(candidates, for: connection, startedAt: probe.startedAt) {
        case .one(let pid):
            let riders = Ssh.muxClients(of: pid, probe)
            if riders.isEmpty {
                host = resolve(pid: pid, forwarded: forwarded, throughServers: !shallow, probe)
            } else if let clients = Ssh.herdrRemoteClients(master: pid, riders: riders, probe) {
                if shallow { return .notFound }
                // herdr's own master stands for the `herdr --remote` it
                // serves: the session's tab is that one's.
                host = clients.count == 1 ? resolve(pid: clients[0], forwarded: forwarded, probe)
                    : sameApp(clients, forwarded: forwarded, probe)
            } else if probe.parent(pid) == 1 {
                // Detached by `ControlPersist`, the master is in no app: its
                // riders are the tabs that use it.
                host = sameApp(riders, forwarded: forwarded, throughServers: !shallow, probe)
            } else {
                host = sameApp([pid] + riders, forwarded: forwarded, throughServers: !shallow, probe)
            }
        case .ambiguous(let pids):
            if shallow { return .notFound }
            host = sameApp(pids, forwarded: forwarded, probe)
        case .none:
            return .notFound
        }
        guard case .app(var app) = host else { return host }
        app.serverPane = connection.herdrPane
        return .app(app)
    }

    /// The one app every pid's walk reaches, else nothing. Its tab and its
    /// herdr pane only when every walk gives that same one and `keepsTab`
    /// (a candidate that may be another session's opens neither); a walk
    /// through herdr with no one pane kept says `.ambiguous`, so the card
    /// does not promise the session.
    static func sameApp(_ pids: [Int32], forwarded: [String] = [], keepsTab: Bool = true,
                        throughServers: Bool = true, _ probe: Probe) -> SessionHost {
        // No pane will be kept, so herdr is not asked: its answer would be
        // thrown away, and the asking spends the action's one deadline.
        var probe = probe
        if !keepsTab { probe.herdr = { _, _ in .unreachable } }
        let hosts = pids.map { resolve(pid: $0, forwarded: forwarded, throughServers: throughServers, probe) }
        let apps = hosts.map { host -> App? in
            if case .app(let app) = host { return app }
            return nil
        }
        guard var first = apps.first ?? nil,
              apps.allSatisfy({ $0?.bundleID == first.bundleID }) else { return .notFound }
        if !keepsTab || first.tab == nil || !apps.allSatisfy({ $0?.tab == first.tab }) { first.tab = nil }
        if !keepsTab || !apps.allSatisfy({ $0?.herdr == first.herdr }) {
            first.herdr = apps.contains { $0?.herdr != nil } ? .ambiguous : nil
        }
        return .app(first)
    }

    static func resolve(remote reply: RemoteHost.Reply, tunnel: Int32?) -> SessionHost {
        resolve(remote: reply, tunnel: tunnel, evlat: getpid(), live)
    }

    /// The news's walk of a remote session (`shallow`): no multiplexer is
    /// asked, so no `tmux` runs and no herdr socket is opened.
    static func resolveShallow(remote reply: RemoteHost.Reply, tunnel: Int32?) -> SessionHost {
        resolve(remote: reply, tunnel: tunnel, evlat: getpid(), shallow: true, live)
    }
}
