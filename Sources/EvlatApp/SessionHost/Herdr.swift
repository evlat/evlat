import Foundation

/// herdr runs its panes under a server (`herdr server`, the same executable)
/// that outlives the terminal it was started from and ends up parented to
/// launchd, so the walk from an agent in a pane never reaches the terminal
/// herdr is shown in.
///
/// A client counts only while it is connected to the server's client socket
/// and has a terminal: a closed tab's client was seen alive with neither a
/// terminal nor a reason to leave, still connected. The newest is taken,
/// being the tab the user opened last. Pids are no order: a client started
/// later held a lower one. Since herdr 0.9.0 each client navigates on its
/// own, so the newest may be showing another workspace; selecting the pane
/// over the API socket (`HerdrPane.focus`) moves every client to it, which
/// is what makes the newest the right one — and only once the pane is known.
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

    /// The pane is found from the process, never the agent's environment:
    /// that of an Apple-signed program (`/usr/bin/ssh`, `/bin/zsh`) cannot
    /// be read at all.
    static func finish(_ app: inout SessionHost.App, server: Int32, root: Int32, agent: Int32,
                       _ probe: SessionHost.Probe) {
        guard let socket = apiSocket(server: server, probe) else {
            app.herdr = .noSocket
            return
        }
        app.herdr = pane(root: root, agent: agent, socket: socket, probe.herdr)
    }

    /// The server's API socket: among its own unix sockets, the one named
    /// `herdr.sock` (the client socket beside it is `herdr-client.sock`).
    /// A socket moved by `HERDR_SOCKET_PATH` under another name is not found.
    static func apiSocket(server: Int32, _ probe: SessionHost.Probe) -> String? {
        probe.unixSockets(server)?.lazy.compactMap(\.path)
            .first { $0.hasPrefix("/") && ($0 as NSString).lastPathComponent == "herdr.sock" }
    }

    /// The pane whose root process — the walk's last process before the
    /// server — is `root`: its shell (`shell_pid`, the process herdr started
    /// for the pane) first, else the pane whose foreground processes hold the
    /// root or the agent, taken only once no pane's shell is. Each pane is one
    /// more request, all under the call's one deadline; past it the rest are
    /// not asked.
    static func pane(root: Int32, agent: Int32, socket: String, _ call: @escaping HerdrSocket.Call) -> HerdrLookup {
        let ids: [String]
        switch call(socket, HerdrAPI.listPanes) {
        case .timeout: return .timeout
        case .unreachable: return .noSocket
        case .line(let line):
            guard let listed = HerdrAPI.paneIDs(HerdrAPI.reply(line)) else { return .unsupported }
            ids = listed.filter(HerdrPane.isPaneID)
        }
        var foreground: String?
        for id in ids {
            switch call(socket, HerdrAPI.processInfo(pane: id)) {
            case .timeout: return .timeout
            case .unreachable: return .noSocket
            case .line(let line):
                let reply = HerdrAPI.reply(line)
                if case .error(let code) = reply {
                    // The method unknown is the server's; any other refusal
                    // (closed since the list: `pane_not_found`) is that
                    // pane's, and the next one is asked.
                    if code == "invalid_request" { return .unsupported }
                    continue
                }
                guard let pids = HerdrAPI.processIDs(reply) else { return .unsupported }
                if pids.shell == root { return .pane(HerdrPane(socket: socket, pane: id, call: call)) }
                if foreground == nil, pids.foreground.contains(where: { $0 == root || $0 == agent }) {
                    foreground = id
                }
            }
        }
        return foreground.map { .pane(HerdrPane(socket: socket, pane: $0, call: call)) } ?? .noMatch
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

/// What asking herdr for the agent's pane came to. Said by `--list`.
enum HerdrLookup: Equatable {
    /// Found: it can be selected.
    case pane(HerdrPane)
    /// No API socket among the server's, or nobody answering at it.
    case noSocket
    /// The action's deadline passed first (`HerdrSocket.budget`).
    case timeout
    /// The server did not answer as herdr 0.9.3 does: a method it does not
    /// know (`pane.process_info` came in 0.7.0), or another shape.
    case unsupported
    /// No pane's processes include the agent's root.
    case noMatch

    var diagnostic: String {
        switch self {
        case .pane(let pane): return "herdr pane \(pane.pane)"
        case .noSocket: return "herdr: no socket"
        case .timeout: return "herdr: timeout"
        case .unsupported: return "herdr: unsupported"
        case .noMatch: return "herdr: no pane"
        }
    }
}

/// The herdr pane an agent runs in, and how to select it: `pane.focus` on
/// the server's API socket selects the pane's workspace, tab and pane in
/// every attached client. Evlat runs no herdr process.
///
/// It keeps the call it was found with, so a click's lookup and selection
/// share that click's one deadline. The call is not part of its identity.
struct HerdrPane: Equatable {
    let socket: String
    let pane: String
    let call: HerdrSocket.Call

    init(socket: String, pane: String, call: @escaping HerdrSocket.Call = { _, _ in .unreachable }) {
        self.socket = socket
        self.pane = pane
        self.call = call
    }

    static func == (a: HerdrPane, b: HerdrPane) -> Bool { a.socket == b.socket && a.pane == b.pane }

    /// 1–64 ASCII letters, digits, `:`, `-` and `_`, never a leading `-`.
    /// An id comes from the server's reply and goes into the next request's
    /// JSON string as it is: no `"` or `\` can reach it.
    static func isPaneID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.first != "-" && id.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || ":-_".contains(character))
        }
    }

    /// Whether herdr selected it. A pane closed since is herdr's
    /// `pane_not_found`, and the app still comes forward.
    @discardableResult
    func focus() -> Bool {
        guard case .line(let line) = call(socket, HerdrAPI.focus(pane: pane)),
              case .result(let type, _) = HerdrAPI.reply(line) else { return false }
        return type == "pane_info"
    }
}

/// herdr's socket API as Evlat speaks it (herdr 0.9.3, protocol 22; the
/// schema is `herdr api schema --json`): one JSON line per request, one
/// reply line, `{"id","result":{"type",…}}` or `{"id","error":{"code",…}}`.
/// Only the fields read are looked at; any other is left alone.
enum HerdrAPI {
    static let listPanes = #"{"id":"evlat","method":"pane.list","params":{}}"#

    /// The pane id is checked (`HerdrPane.isPaneID`) before it gets here.
    static func processInfo(pane: String) -> String {
        #"{"id":"evlat","method":"pane.process_info","params":{"pane_id":"\#(pane)"}}"#
    }

    static func focus(pane: String) -> String {
        #"{"id":"evlat","method":"pane.focus","params":{"pane_id":"\#(pane)"}}"#
    }

    enum Reply {
        case result(type: String, body: [String: Any])
        case error(code: String)
        case unreadable
    }

    static func reply(_ line: String) -> Reply {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return .unreadable
        }
        if let error = object["error"] as? [String: Any], let code = error["code"] as? String {
            return .error(code: code)
        }
        guard let result = object["result"] as? [String: Any], let type = result["type"] as? String else {
            return .unreadable
        }
        return .result(type: type, body: result)
    }

    /// A `pane_list`'s pane ids; `nil` for any other reply.
    static func paneIDs(_ reply: Reply) -> [String]? {
        guard case .result("pane_list", let body) = reply,
              let panes = body["panes"] as? [[String: Any]] else { return nil }
        return panes.compactMap { $0["pane_id"] as? String }
    }

    /// A `pane_process_info`'s shell and foreground pids; `nil` for any
    /// other reply. `tty` is not read: it was `null` on macOS.
    static func processIDs(_ reply: Reply) -> (shell: Int32?, foreground: [Int32])? {
        guard case .result("pane_process_info", let body) = reply,
              let info = body["process_info"] as? [String: Any] else { return nil }
        let shell = (info["shell_pid"] as? NSNumber).flatMap { Int32(exactly: $0.int64Value) }
        let foreground = (info["foreground_processes"] as? [[String: Any]] ?? []).compactMap {
            ($0["pid"] as? NSNumber).flatMap { Int32(exactly: $0.int64Value) }
        }
        return (shell, foreground)
    }
}
