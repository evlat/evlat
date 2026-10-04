/// A terminal multiplexer: its server is the parent of the agent's pane, and
/// the tab the user looks at is wherever one of its clients runs. The walk
/// passes a server for the best of its clients (`SessionHost.walk`), and
/// reads the tab from that client's environment: the pane's is the one the
/// server was first started from, which may since have closed. Another
/// multiplexer is one more conforming type in `SessionHost.multiplexers`.
///
/// Each rule is pure over `SessionHost.Probe`, so every chain measured on a
/// real machine is a table in the tests.
protocol Multiplexer {
    /// Whether this ancestor of the agent is this multiplexer's server.
    static func isServer(_ pid: Int32, path: String, _ probe: SessionHost.Probe) -> Bool
    /// The server's clients that may be showing the agent's pane, best first.
    static func clients(server: Int32, path: String, agent: Int32, _ probe: SessionHost.Probe) -> [Int32]
    /// What the host learns once a client is found: herdr's pane to select.
    /// `root` is the walk's last process before the server: the pane's own.
    static func finish(_ app: inout SessionHost.App, server: Int32, root: Int32, agent: Int32,
                       _ probe: SessionHost.Probe)
}

extension Multiplexer {
    static func finish(_ app: inout SessionHost.App, server: Int32, root: Int32, agent: Int32,
                       _ probe: SessionHost.Probe) {}
}
