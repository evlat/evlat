import Foundation

/// tmux keeps a view per client, so the client is the one that last did
/// something in the pane's session (`client_activity`). The pane is named by
/// the agent's own `TMUX` and `TMUX_PANE`, the server asked with its own
/// executable. tmux's pane is not selected.
enum Tmux: Multiplexer {
    /// A tmux ancestor is always its server: a client is never the parent
    /// of a pane's process.
    static func isServer(_ pid: Int32, path: String, _ probe: SessionHost.Probe) -> Bool {
        (path as NSString).lastPathComponent == "tmux"
    }

    static func clients(server: Int32, path: String, agent: Int32, _ probe: SessionHost.Probe) -> [Int32] {
        guard let query = TmuxQuery.of(executable: path, environment: probe.environment(agent)),
              query.server == server, let reply = probe.tmux(query) else { return [] }
        return reply.clients
            .filter { $0.session == reply.session && probe.hasTerminal($0.pid) != false }
            .sorted { ($0.activity, $0.pid) > ($1.activity, $1.pid) }
            .map(\.pid)
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
        func value(_ name: String) -> String? { SessionHost.value(name, in: environment) }
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

    /// How long the card waits for tmux, on the main thread. It answers from
    /// memory (6.8 ms median, 8.3 ms at most over 20 runs, tmux 3.7c); a
    /// server that does not is not waited for.
    static let timeout: TimeInterval = 0.25

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
