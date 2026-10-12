import Foundation

/// The tab of a session that runs in a service many terminals share: the
/// terminal client connected to that service, in the session's folder.
///
/// The service belongs to no terminal (launchd's child) and says nothing of
/// which client a session was started from, so the walk up from the agent has
/// nothing to start from. What can be read, with no permission, is the
/// clients: a process of the same program as the service, with a terminal,
/// holding a connection to the port the service **listens** on — a service's
/// own outgoing connections are not that — and whose working directory is the
/// session's folder, which is where a client starts its sessions (a
/// subfolder included: that subfolder is its directory then). How many
/// connections a client holds does not matter (one on 2.0.22, three on
/// 2.0.27).
///
/// Of the candidates one is that session's tab; several in one folder cannot
/// be told apart, so the app alone when every one is in the same app and
/// nothing otherwise; none, nothing. Only the click and the card ask this —
/// never the news, since a client holds the tabs of many sessions and the
/// news must be sure of the tab it keeps quiet for. Nothing is run: the
/// clients are read like any other process (`SessionHost.Probe`).
enum ServiceClients {
    static func resolve(service: Int32, folder: String?) -> SessionHost {
        resolve(service: service, folder: folder, SessionHost.live)
    }

    static func resolve(service: Int32, folder: String?, _ probe: SessionHost.Probe) -> SessionHost {
        let pids = clients(of: service, in: folder, probe)
        switch pids.count {
        case 0: return .notFound
        case 1: return SessionHost.resolve(pid: pids[0], probe)
        default: return SessionHost.sameApp(pids, keepsTab: false, probe)
        }
    }

    /// The service's clients that run in `folder`, by pid. Each check is
    /// cheaper than the one after it, since every process is asked.
    static func clients(of service: Int32, in folder: String?, _ probe: SessionHost.Probe) -> [Int32] {
        guard let folder, folder.hasPrefix("/"), let wanted = probe.realPath(folder),
              let program = probe.executablePath(service),
              let listening = probe.listeningSockets(service), !listening.isEmpty else { return [] }
        return Set(probe.processes()).sorted().filter { pid in
            pid != service
                && probe.executablePath(pid) == program
                && probe.hasTerminal(pid) == true
                && probe.currentDirectory(pid).flatMap(probe.realPath) == wanted
                && (probe.tcpSockets(pid) ?? []).contains { socket in
                    listening.contains { reaches(socket.remote, $0) }
                }
        }
    }

    /// A connection's far end is the service's listening one: the same port,
    /// on the address it listens on or on loopback, which is what a
    /// wildcard listener is reached by.
    static func reaches(_ remote: SessionHost.Endpoint, _ listening: SessionHost.Endpoint) -> Bool {
        remote.port == listening.port && (remote.address == listening.address || isLoopback(remote.address))
    }

    private static func isLoopback(_ address: String) -> Bool {
        address == "::1" || address.hasPrefix("127.") || address.hasPrefix("::ffff:127.")
    }
}
