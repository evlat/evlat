import Foundation

/// herdr runs its panes under a server (`herdr server`, the same executable)
/// that outlives the terminal it was started from and ends up parented to
/// launchd, so the walk from an agent in a pane never reaches the terminal
/// herdr is shown in.
///
/// A client counts only while it is connected to the server's client socket
/// and has a terminal: a closed tab's client was seen alive with neither a
/// terminal nor a reason to leave, still connected. Every client shows the
/// same view (herdr 0.9.3, seen in two windows at once), so any live one is
/// right; the newest is taken, being the tab the user opened last. Pids are
/// no order: a client started later held a lower one.
enum Herdr: Multiplexer {
    static func isServer(_ pid: Int32, path: String, _ probe: SessionHost.Probe) -> Bool {
        (path as NSString).lastPathComponent == "herdr" && probe.arguments(pid).dropFirst().first == "server"
    }

    static func clients(server: Int32, path: String, agent: Int32, _ probe: SessionHost.Probe) -> [Int32] {
        // The connection proves the session, whatever the client's
        // arguments; without the sockets (unreadable, or none by that name)
        // the arguments and `HERDR_SESSION` are what is left.
        let accepted = probe.unixSockets(server).flatMap { sockets -> Set<UInt64>? in
            let named = sockets.filter { $0.path.map { ($0 as NSString).lastPathComponent } == "herdr-client.sock" }
            return named.isEmpty ? nil : Set(named.map(\.pcb))
        }
        let serverSession = accepted == nil ? session(environment: probe.environment(server)) : ""
        let clients = probe.processes().filter { client in
            guard client != server, let executable = probe.executablePath(client),
                  (executable as NSString).lastPathComponent == "herdr",
                  probe.hasTerminal(client) != false else { return false }
            if let accepted {
                return (probe.unixSockets(client) ?? []).contains { accepted.contains($0.peer) }
            }
            guard let named = clientSession(arguments: probe.arguments(client)) else { return false }
            return (named ?? session(environment: probe.environment(client))) == serverSession
        }
        let started = Dictionary(uniqueKeysWithValues: clients.map { ($0, probe.startedAt($0)) })
        return clients.sorted { a, b in
            switch (started[a] ?? nil, started[b] ?? nil) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a > b
            }
        }
    }

    static func finish(_ app: inout SessionHost.App, server path: String, agent: Int32,
                       _ probe: SessionHost.Probe) {
        app.herdr = HerdrPane.of(herdr: path, environment: probe.environment(agent))
    }

    /// The session a herdr server serves: `HERDR_SESSION`, or the default.
    static func session(environment: [String]) -> String {
        let name = SessionHost.value("HERDR_SESSION", in: environment) ?? ""
        return name.isEmpty ? "default" : name
    }

    /// A herdr client's arguments: `.some(nil)` for a bare `herdr` (its
    /// session is its environment's), `.some(name)` for `--session <name>`
    /// or `session attach <name>`, `nil` for anything else — the CLI's own
    /// subcommands (`herdr pane list`) attach to nothing.
    static func clientSession(arguments: [String]) -> String?? {
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
    let socket: String

    /// `nil` when the environment names no pane, or a value that is not one.
    static func of(herdr executable: String, environment: [String]) -> HerdrPane? {
        func value(_ name: String) -> String? { SessionHost.value(name, in: environment) }
        // Without its socket the command would ask the default session,
        // whose panes are numbered on their own: `w1:p1` is in every one.
        guard executable.hasPrefix("/"), let pane = value("HERDR_PANE_ID"), isPaneID(pane),
              let socket = value("HERDR_SOCKET_PATH"), socket.hasPrefix("/") else { return nil }
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
    var environment: [String: String] { ["HERDR_SOCKET_PATH": socket] }

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
