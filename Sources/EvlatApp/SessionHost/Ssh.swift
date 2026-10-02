import Foundation
import EvlatCore

/// A remote session's terminal on this Mac: the user's own `ssh` to that
/// server, found from what the server said of the session's connection
/// (`RemoteHost.Reply`). From that `ssh` the walk is the local one
/// (`SessionHost.resolve`), tmux and herdr on this side included.
///
/// The candidates are the user's `ssh` processes connected to the **same
/// end** as Evlat's own tunnel to that machine. Not to the address the
/// server names: a NAT on either side, or a jump host, makes that address
/// one no `ssh` here holds. The tunnel goes the way the user's `ssh` goes,
/// so its end is theirs — DNS, NAT and `ProxyJump` included. No tunnel, no
/// candidate.
///
/// In order:
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
/// too: the server sees all of them as one connection.
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
    /// is. Evlat's own are never one: the tunnel, the installer's calls and
    /// a jump host's `ssh -W` under them all descend from `evlat`.
    static func candidates(tunnel: Int32, evlat: Int32, _ probe: SessionHost.Probe) -> [Candidate] {
        let pids = probe.processes()
        // Through `ProxyJump` the socket is the tunnel's child's.
        let tunnelSide = [tunnel] + pids.filter { $0 != tunnel && probe.parent($0) == tunnel }
        let ends = Set(tunnelSide.flatMap { probe.tcpSockets($0) ?? [] }.map(\.remote))
        guard !ends.isEmpty else { return [] }
        return pids.compactMap { pid in
            guard pid != tunnel, isSsh(pid, probe), !descends(pid, from: evlat, probe),
                  let sockets = probe.tcpSockets(pid) else { return nil }
            let ports = Set(sockets.filter { ends.contains($0.remote) }.map(\.local.port))
            return ports.isEmpty ? nil : Candidate(pid: pid, localPorts: ports)
        }
    }

    /// What the order above makes of the candidates.
    enum Choice: Equatable {
        case one(Int32)
        /// Several, none told apart: their pids, for "is it one app".
        case ambiguous([Int32])
        case none
    }

    static func choose(_ candidates: [Candidate], for connection: RemoteHost.Connection,
                       startedAt: (Int32) -> Date?) -> Choice {
        if candidates.isEmpty { return .none }
        let exact = candidates.filter { $0.localPorts.contains(connection.clientPort) }
        if exact.count == 1 { return .one(exact[0].pid) }
        let all = candidates.map(\.pid)
        let start = connection.localStart
        if candidates.count == 1 {
            // Alone, unless its start says it is another connection: a
            // session started from another computer, or an `ssh` through
            // the same jump host to another server.
            if let start, let own = startedAt(all[0]), abs(own.timeIntervalSince(start)) > apart {
                return .none
            }
            return .one(all[0])
        }
        guard let start else { return .ambiguous(all) }
        let distances = candidates.compactMap { candidate in
            startedAt(candidate.pid).map { (pid: candidate.pid, distance: abs($0.timeIntervalSince(start))) }
        }.sorted { $0.distance < $1.distance }
        // A candidate whose start cannot be read could be the one: no pick.
        guard distances.count == candidates.count, let best = distances.first, best.distance <= nearest,
              distances.dropFirst().allSatisfy({ $0.distance > apart }) else { return .ambiguous(all) }
        return .one(best.pid)
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
    static func resolve(remote reply: RemoteHost.Reply, tunnel: Int32?, evlat: Int32,
                        _ probe: Probe) -> SessionHost {
        guard case .connection(let connection) = reply, let tunnel else { return .notFound }
        let forwarded = connection.forwarded
        let candidates = Ssh.candidates(tunnel: tunnel, evlat: evlat, probe)
        switch Ssh.choose(candidates, for: connection, startedAt: probe.startedAt) {
        case .one(let pid):
            let riders = Ssh.muxClients(of: pid, probe)
            guard riders.isEmpty else { return sameApp([pid] + riders, forwarded: forwarded, probe) }
            return resolve(pid: pid, forwarded: forwarded, probe)
        case .ambiguous(let pids):
            return sameApp(pids, forwarded: forwarded, probe)
        case .none:
            return .notFound
        }
    }

    /// The one app every pid's walk reaches, with no pane, and with a tab
    /// only when every walk gives that same tab; else nothing.
    private static func sameApp(_ pids: [Int32], forwarded: [String], _ probe: Probe) -> SessionHost {
        let apps = pids.map { resolve(pid: $0, forwarded: forwarded, probe) }.map { host -> App? in
            if case .app(let app) = host { return App(bundleID: app.bundleID, name: app.name, pid: app.pid, tab: app.tab) }
            return nil
        }
        guard var first = apps.first ?? nil,
              apps.allSatisfy({ $0?.bundleID == first.bundleID }) else { return .notFound }
        if first.tab == nil || !apps.allSatisfy({ $0?.tab == first.tab }) { first.tab = nil }
        return .app(first)
    }

    static func resolve(remote reply: RemoteHost.Reply, tunnel: Int32?) -> SessionHost {
        resolve(remote: reply, tunnel: tunnel, evlat: getpid(), live)
    }
}
