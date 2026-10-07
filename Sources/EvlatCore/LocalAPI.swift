import Foundation

/// The local endpoint: which routes exist, who is allowed to reach them and
/// what comes back. All of it is pure — `Data` and `String` in, a `Response`
/// out — so the rules that matter can be tested without a socket. The
/// listener (`EvlatApp`) adds transport and nothing else.
public enum LocalAPI {
    /// The port the installed hook commands carry as **plain text**. That is
    /// the whole reason there is no stored setting for it: the command in the
    /// user's settings file says `48151`, so an app listening anywhere else
    /// would simply never be spoken to, and neither side would report an error.
    /// An override exists for development only, and it is an
    /// environment variable read on the app side (`EVLAT_PORT`).
    public static let defaultPort: UInt16 = 48151

    // MARK: - Routing

    /// What a request turned out to be. The refusals are part of the same
    /// answer because the decision is one step: a browser is turned away before
    /// any path is looked at.
    public enum Dispatch: Equatable {
        /// A browser: it sent an `Origin`, or wrote someone else's name in
        /// `Host`.
        case forbidden
        case notFound
        case hook(AgentID)
        /// A status line relaying its rate limits (`StatusLineUsage.path`).
        case usage(AgentID)
        /// A chat turn's permission request (`ChatRequest.path`).
        case permission
        /// A terminal session's permission, to approve from the bar
        /// (`ApprovalHook`).
        case approval
        /// An outside program's row (`SignalReport`). Keyed: the
        /// listener's key decides, not the route (`Listener`).
        case signal
        /// An `ssh` askpass helper's prompt (`Askpass`).
        case askpass
        case health

        /// The route by kind, for the listener's role (`Origin.role`); a
        /// refusal is none.
        public var route: Route? {
            switch self {
            case .forbidden, .notFound: return nil
            case .hook: return .hook
            case .usage: return .usage
            case .permission: return .permission
            case .approval: return .approval
            case .signal: return .signal
            case .askpass: return .askpass
            case .health: return .health
            }
        }
    }

    /// The fixed routes are this `switch`; the agents' are `routes`, made
    /// from the catalog (`RouteTable`).
    ///
    /// v1's generic route table (`Route.required`, `read`/`action`/`mac` kinds,
    /// a semaphore answering on the main queue) is **not** ported: every
    /// endpoint that needed it is out of scope for v2, and a handful of rows
    /// do not earn the generality.
    ///
    /// `curl` and the installed hook command never send `Origin`; a browser
    /// sends it on every cross-origin request. That alone is not enough,
    /// because a same-origin GET carries none — so a page that resolves its own
    /// name to 127.0.0.1 (DNS rebinding) could still reach a GET route. Its own
    /// name stays in `Host`, which is the second check. What is left is a
    /// browser's no-cors POST, and every side-effecting route here is POST, so
    /// that request carries an `Origin` and is refused by the first check.
    ///
    /// The path is **not normalised**: `/hook/a/../b` matches nothing.
    /// Collapsing it would let a route be reached by a spelling neither check
    /// above ever saw.
    public static func dispatch(method: String, target: String, origin: String?, host: String?,
                                routes: RouteTable) -> Dispatch {
        if origin != nil { return .forbidden }
        if let host = host, !isLoopback(host: host) { return .forbidden }
        // The query is dropped, not rejected: no v2 endpoint takes an argument,
        // and a path is what the table is written in. The **encoded** path is
        // what is compared: `path` would unescape it, and `/%68ook` is then a
        // second spelling of a route that neither check above examined.
        let path = URLComponents(string: target)?.percentEncodedPath ?? target
        switch (method, path) {
        // A synonym an agent keeps (`HookChannel.paths`) is in the table like
        // its installed path: dropping it would change the contract silently
        // for anyone whose hooks spell it that way.
        case ("POST", let path) where routes.hooks[path] != nil: return .hook(routes.hooks[path]!)
        case ("POST", let path) where routes.usage[path] != nil: return .usage(routes.usage[path]!)
        case ("POST", ChatRequest.path): return .permission
        case ("POST", ApprovalHook.path): return .approval
        case ("POST", SignalReport.path): return .signal
        case ("POST", Askpass.path): return .askpass
        case ("GET", "/health"): return .health
        default: return .notFound
        }
    }

    /// `127.0.0.1:48151`, `localhost`, `[::1]:48151`. The connection already
    /// only ever arrives over loopback, so the name is the single thing worth
    /// looking at. The port is not: in a rebinding attempt the page's name
    /// changes, its port does not.
    public static func isLoopback(host: String) -> Bool {
        var name = host.lowercased()
        // `[::1]:48151` → `[::1]`, but a bare `[::1]` keeps its brackets.
        if let colon = name.lastIndex(of: ":"), !name.hasSuffix("]") { name = String(name[..<colon]) }
        return ["127.0.0.1", "localhost", "[::1]"].contains(name)
    }

    // MARK: - Answering

    public enum Status: Int, Equatable {
        case ok = 200
        case badRequest = 400
        case forbidden = 403
        case notFound = 404

        var reason: String {
            switch self {
            case .ok: return "OK"
            case .badRequest: return "Bad Request"
            case .forbidden: return "Forbidden"
            case .notFound: return "Not Found"
            }
        }
    }

    public struct Response: Equatable {
        public let status: Status
        public let body: String

        public init(status: Status, body: String) {
            self.status = status
            self.body = body
        }

        /// The bytes to write back. Framing lives here rather than in the
        /// listener because `Content-Length` counts **UTF-8 bytes**, not
        /// characters: a body with one multi-byte character announced by
        /// character count is cut short, and the client waits for the rest
        /// until its own timeout fires.
        public var httpText: String {
            "HTTP/1.1 \(status.rawValue) \(status.reason)\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
        }
    }

    /// What an accepted POST hands to the app: one thing or the other, never
    /// both — so there is no "both filled" state to get wrong.
    public enum Delivery {
        case hook(HookEvent)
        case usage(UsageReport)
        /// A permission request whose answer is **held**: the outcome has no
        /// response, and the listener keeps the connection open under the
        /// request's id until the user answers (`HookListener.answer`).
        case permission(ChatRequest)
        /// A terminal session's permission request, held like `permission`
        /// until the user answers on the card or it is answered elsewhere.
        case approval(HeldRequest)
        /// An outside program's row, read and cleaned; the key has passed.
        case signal(SignalReport)
        /// A tunnel's `ssh` asking for a password or a yes/no, held like
        /// `permission` until it is answered (`Askpass`).
        case askpass(Askpass.Request)
    }

    /// The answer, plus what the app should hand to the main queue. The
    /// delivery is separate from the response on purpose: the hook's `curl`
    /// runs with `-m 2` and must not wait for the main queue, so the listener
    /// writes the response from the server queue and passes this **parsed**
    /// value across (a raw body reaches 8 KB).
    ///
    /// `response == nil` means the answer is not known yet: only a
    /// permission request, whose answer is the user's (`Delivery.permission`).
    public struct Outcome {
        public let response: Response?
        public let delivery: Delivery?
    }

    /// Where a request came in. The listener knows and says so; what that
    /// means for the request is decided here, so the listener stays transport.
    public enum Origin: Equatable {
        /// This Mac: its loopback port (`defaultPort`) or its socket
        /// (`EvlatSocket`).
        case local
        /// A remote machine, arriving on that machine's own listener. The
        /// request is the same bytes the local hook command sends — the
        /// installed command is identical on both sides — but its `$PPID`
        /// and `$EVLAT_TASK` are the remote computer's. A remote pid asked
        /// about on this Mac would name whatever local process holds that
        /// number, so both are treated as absent.
        case machine
        /// A Docker sandbox (`SandboxInstall`), through the sandbox's own
        /// proxy and only because that sandbox's network rule allows it.
        /// Its pid and task speak about the VM, as a machine's do.
        case sandbox

        /// What a request from here may reach and which of its headers are
        /// believed. The one place a listener's role is written: a route
        /// not named here answers `404`, whatever the listener holds.
        public var role: Role {
            switch self {
            case .local:
                return Role(routes: Set(Route.allCases), trustsProcess: true, trustsSandbox: false)
            // No card in front of this user that grants anything, no
            // password asked for: the held routes stay this Mac's.
            case .machine:
                return Role(routes: [.hook, .usage, .signal, .health], trustsProcess: false, trustsSandbox: false)
            // Hooks only, and the one listener whose sandbox header is read.
            case .sandbox:
                return Role(routes: [.hook], trustsProcess: false, trustsSandbox: true)
            }
        }
    }

    /// A route by kind, the agents' routes folded into one each.
    public enum Route: CaseIterable, Equatable {
        case hook, usage, permission, approval, signal, askpass, health
    }

    /// An origin's reach (`Origin.role`).
    public struct Role: Equatable {
        public let routes: Set<Route>
        /// `X-Evlat-Pid` and `X-Evlat-Task` name processes on this Mac.
        public let trustsProcess: Bool
        /// `X-Evlat-Sandbox` names the sandbox the hook ran in.
        public let trustsSandbox: Bool
    }

    /// Everything a listener says about itself that decides a request: where
    /// it came in, and the key `/signal` asks for. One value rather than two
    /// parameters, so a listener cannot be built with one half and not the
    /// other.
    ///
    /// **The key belongs to the listener, not to the request.** The process
    /// that holds the port writes it; a machine's listener is
    /// given its machine's key, so a key names the machine and the
    /// body never does. A local listener with no key — the file could not be
    /// written, an isolated process — refuses every `/signal`; a machine's
    /// listener with none does not have the route. The socket's listener
    /// asks for none (`keylessSignal`): its directory is the user's alone.
    public struct Listener: Equatable {
        public let origin: Origin
        public let signalKey: String?
        /// `/signal` takes no key: the socket's listener, which only the
        /// user's own processes can reach.
        public let keylessSignal: Bool
        /// Where an agent's finish may read its reply from
        /// (`HookChannel.finish`); none, and no reply is read.
        public let transcriptRoots: [URL]
        /// The agents' routes (`RouteTable`); empty, and no agent route
        /// answers.
        public let routes: RouteTable

        public init(origin: Origin = .local, signalKey: String? = nil, keylessSignal: Bool = false,
                    transcriptRoots: [URL] = [], routes: RouteTable = RouteTable()) {
            self.origin = origin
            self.signalKey = signalKey
            self.keylessSignal = keylessSignal
            self.transcriptRoots = transcriptRoots
            self.routes = routes
        }
    }

    /// The default listener is local and has no key: `/signal` is refused.
    /// `agents` is what a dispatched route's id is looked up in: its
    /// translation, its status line and its approvals. The routes are the
    /// listener's (`Listener.routes`), made from the same catalog.
    public static func handle(_ request: HTTPRequest, listener: Listener = Listener(),
                              agents: [any Agent] = []) -> Outcome {
        let role = listener.origin.role
        let dispatched = dispatch(method: request.method, target: request.target,
                                  origin: request.origin, host: request.host, routes: listener.routes)
        // The role first: a route this listener does not serve is not
        // shown to exist, keyed or not.
        if let route = dispatched.route, !role.routes.contains(route) { return notFound }
        switch dispatched {
        case .forbidden:
            return Outcome(response: Response(status: .forbidden,
                                              body: error("forbidden", "browser requests are not accepted")),
                           delivery: nil)
        case .notFound:
            return notFound
        case .permission:
            // Only this Mac's own turns ask (`Origin.role`): a remote machine
            // must not be able to put a permission card in front of this user.
            guard let json = jsonObject(request.body) else { return badRequest }
            // A missing token is refused here; a wrong one needs the running
            // turns to know, and is refused on the main queue (`ChatStore`).
            guard let token = request.permissionToken else {
                return Outcome(response: Response(status: .forbidden,
                                                  body: error("forbidden", "a permission token is expected")),
                               delivery: nil)
            }
            // Read by the backend whose turns ask here (`RouteTable.permission`).
            guard let backend = listener.routes.permission.flatMap({ agents[id: $0]?.chat }),
                  let asked = backend.request(json: json, token: token) else { return badRequest }
            return Outcome(response: nil, delivery: .permission(asked))
        case .approval:
            // This Mac's own sessions only (`Origin.role`), as `/permission`.
            // `{}` is no decision: the agent's own dialog stays and decides.
            guard let json = jsonObject(request.body),
                  let channel = listener.routes.approval.flatMap({ agents[id: $0]?.approvals }),
                  let asked = channel.request(json: json),
                  asked.sessionID != nil else {
                return Outcome(response: Response(status: .ok, body: "{}"), delivery: nil)
            }
            return Outcome(response: nil, delivery: .approval(asked))
        case .askpass:
            // This Mac's own tunnels only (`Origin.role`): what a helper is
            // answered may be a password, and a remote machine must never be
            // able to ask for one — keyed or not.
            guard let token = request.askpassToken else {
                return Outcome(response: Response(status: .forbidden,
                                                  body: error("forbidden", "an askpass token is expected")),
                               delivery: nil)
            }
            // The prompt is the body as text, not JSON: that is all `ssh`
            // hands its helper.
            guard let prompt = String(data: request.body, encoding: .utf8) else {
                return Outcome(response: Response(status: .badRequest,
                                                  body: error("badRequest", "a UTF-8 prompt is expected")),
                               delivery: nil)
            }
            return Outcome(response: nil, delivery: .askpass(Askpass.Request(token: token, prompt: prompt)))
        case .signal:
            // A machine's listener with neither a key nor a socket does not
            // have the route, and its existence is not shown to it (as
            // `/permission`). Otherwise a machine is the local route exactly:
            // the machine is the listener's, which the delivery's receiver
            // knows. A machine's socket end is this user's alone, as the
            // channel's end on the server is (`RemoteTunnel`).
            if listener.origin == .machine, listener.signalKey == nil, !listener.keylessSignal { return notFound }
            // The key before the body: a caller without it learns nothing
            // about what a valid body looks like. The socket asks for none.
            guard listener.keylessSignal
                    || listener.signalKey.flatMap({ expected in
                        request.signalKey.map { sameKey($0, expected) } }) == true else {
                return Outcome(response: Response(status: .forbidden,
                                                  body: error("forbidden", "a valid X-Evlat-Key is expected")),
                               delivery: nil)
            }
            guard let json = jsonObject(request.body) else { return badRequest }
            switch SignalReport.parse(json: json) {
            case .failure(let rejection):
                return Outcome(response: Response(status: .badRequest, body: error(rejection.code, rejection.message)),
                               delivery: nil)
            case .success(let report):
                // `{}` whatever the main queue does with it: the cap is
                // known there, after this answer (`SignalsProvider.Applied`).
                return Outcome(response: Response(status: .ok, body: "{}"), delivery: .signal(report))
            }
        case .health:
            // v1 answered the single word `ok` under `Content-Type:
            // application/json`, which is not JSON. Nothing reads this body
            // yet, so it was corrected rather than carried over.
            return Outcome(response: Response(status: .ok, body: "{\"ok\":true}"), delivery: nil)
        case .usage(let id):
            // The body is that agent's status line input; each has its own
            // reader, and anything else in it is let go there.
            guard let json = jsonObject(request.body) else { return badRequest }
            let report = UsageReport(statusLine: json, source: id, usage: agents[id: id]?.statusLineUsage)
            // `{}` for the same reason as a hook: the relay throws the answer
            // away, and nothing from this body is ever sent back anywhere.
            return Outcome(response: Response(status: .ok, body: "{}"), delivery: .usage(report))
        case .hook(let id):
            guard var json = jsonObject(request.body) else { return badRequest }
            let channel = agents[id: id]?.hooks
            // These two keys are written **only** here, from the headers, and a
            // body that carries them has them deleted. This endpoint asks for
            // no identity, so otherwise any local process could put `evlat_pid`
            // in a body and choose where a session appears to be running, or
            // claim with `evlat_task` to be an errand Evlat started itself.
            //
            // The stamp happens before the translation, which is why an adapter
            // has to pass these keys through (`HookChannel.canonical`).
            //
            // A machine's or a sandbox's request takes the no-header branch:
            // its headers are real, but they speak about another computer
            // (`Origin.role`).
            let trusted = role.trustsProcess
            if trusted, let taskID = request.taskID { json[HookEvent.taskKey] = taskID }
            else { json.removeValue(forKey: HookEvent.taskKey) }
            if trusted, let pid = request.pid { json[HookEvent.pidKey] = pid }
            else { json.removeValue(forKey: HookEvent.pidKey) }
            // The sandbox's header, by the same rule: written from the
            // headers by a sandbox's listener only, deleted from every body.
            // Elsewhere any local process could put a sandbox's name on a row
            // and have its card look for that sandbox's terminal.
            let sandbox = role.trustsSandbox
            if sandbox, let name = request.sandboxName { json[HookEvent.sandboxKey] = name }
            else { json.removeValue(forKey: HookEvent.sandboxKey) }
            // A body that names no event has it in a header
            // (`HookChannel.eventInHeader`). A body that names its own keeps it.
            if json["hook_event_name"] == nil, let event = request.event { json["hook_event_name"] = event }
            // A finish that names no reply has it read from this Mac's files;
            // a machine's names a file elsewhere and never is. Such a
            // body never supplies the reply itself.
            if let finish = channel?.finish {
                json.removeValue(forKey: "last_assistant_message")
                if trusted, let reply = finish(json, listener.transcriptRoots) {
                    json["last_assistant_message"] = reply
                }
            }
            // Exactly `{}`, and that is not incidental. The installed command
            // throws the answer away (`>/dev/null`), but if this body ever did
            // reach Claude Code, a stray JSON object would allow or deny a
            // permission on the user's behalf.
            return Outcome(response: Response(status: .ok, body: "{}"),
                           delivery: .hook(HookEvent(json: channel?.canonical(json) ?? json, source: id)))
        }
    }

    /// A permission request whose token names no running turn.
    public static let unknownToken = Response(status: .forbidden,
                                              body: error("forbidden", "no turn holds this permission token"))

    /// An askpass prompt nobody answers: the helper exits non-zero and `ssh`
    /// sends no password at all. Never `200`, which is an answer.
    public static let noAnswer = Response(status: .forbidden,
                                          body: error("noAnswer", "the prompt was not answered"))

    /// No route by that name — also what a listener that answers no
    /// permissions says to one (`HookListener`).
    public static let noSuchEndpoint = Response(status: .notFound, body: error("notFound", "no such endpoint"))

    private static var notFound: Outcome {
        Outcome(response: noSuchEndpoint, delivery: nil)
    }

    /// A body that is not a JSON object delivers nothing: half a reading would
    /// move the bar on a request Evlat could not read.
    private static var badRequest: Outcome {
        Outcome(response: Response(status: .badRequest, body: error("badRequest", "a JSON object is expected")),
                delivery: nil)
    }

    /// Equal keys, in a time that does not depend on where they differ.
    /// Foundation has no such comparison. Every byte of the **longer** one is
    /// visited, with the missing side read as zero, and the length difference
    /// is folded in as a whole `Int` — a byte-sized fold would wrap at 256 and
    /// let a key followed by 256 zero bytes pass. An empty key is no key.
    static func sameKey(_ sent: String, _ expected: String) -> Bool {
        let a = Array(sent.utf8), b = Array(expected.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= Int(x ^ y)
        }
        return difference == 0 && !b.isEmpty
    }

    private static func jsonObject(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// `{"error": {"code", "message"}}`. `code` is a stable identifier and
    /// `message` is English: this body is read by a developer or a script, and
    /// it must not change with the interface language.
    ///
    /// v1 guarded against `NaN` here because it encoded arbitrary `Any` values;
    /// v2's bodies are fixed strings, so the only failure left is the one the
    /// fallback covers.
    public static func error(_ code: String, _ message: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]],
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":{\"code\":\"encodingFailed\",\"message\":\"the answer could not be encoded\"}}"
        }
        return text
    }

    // MARK: - The installed command

    /// The command installed in the user's hook settings —
    /// `~/.claude/settings.json` and `~/.codex/hooks.json` — and the only one
    /// the app writes there (`HookSettings`). It is both the contract's owner in
    /// code and the string that lands in the file: the route and the header
    /// names below are the same ones `dispatch` and `HTTPRequest` read, so a
    /// change to any of them changes this string and breaks the golden test
    /// that pins it (`LocalAPITests.testTheInstalledHookCommandIsUnchanged`).
    ///
    /// It speaks to the socket under the home where it runs
    /// (`EvlatSocket.Curl.homeSocket`): this Mac's own, or on a server the
    /// one the tunnel carries here — the same bytes on both. The URL stays
    /// `http://127.0.0.1:48151/…` although no port is dialled: its text is
    /// what makes a command Evlat's (`HookSettings.marker`), so a command
    /// from before the socket reads as Evlat's older one, not someone
    /// else's.
    ///
    /// It fails silently by construction: `-m 2` so a closed Evlat cannot stall
    /// the agent, `>/dev/null 2>&1` because the answer must never reach Claude
    /// Code, and `|| true` so a hook never fails over Evlat — a missing
    /// socket included. `-q` reads no `.curlrc` and `--noproxy '*'` lets no
    /// proxy variable take the request elsewhere. `$PPID`, `$HOME` and
    /// `${EVLAT_TASK:-}` are plain text — they resolve when the hook runs,
    /// not when it is installed.
    ///
    /// A body that does not name its event (`HookChannel.eventInHeader`)
    /// gets a command per event that says it in `X-Evlat-Event`; every
    /// other agent's bytes carry no such header.
    ///
    /// `endpoint` is where the command runs. `.local`, the default, is the
    /// bytes above and nothing else: the installed contract. `.sandbox` is
    /// its twin inside a Docker sandbox (`SandboxInstall`), written into each
    /// sandbox's own file and pinned beside it (`SandboxInstallTests`).
    public static func installedHookCommand(for agent: some Agent, event: String? = nil,
                                            endpoint: HookEndpoint = .local) -> String {
        installedHookCommand(for: agent.hooks, event: event, endpoint: endpoint)
    }

    public static func installedHookCommand(for hooks: HookChannel, event: String? = nil,
                                            endpoint: HookEndpoint = .local) -> String {
        let named = hooks.eventInHeader ? event.map { " -H 'X-Evlat-Event: \($0)'" } ?? "" : ""
        switch endpoint {
        case .local:
            let curl = EvlatSocket.Curl.self
            return "\(curl.program) -s -m 2 \(curl.noProxy) \(curl.homeSocket)"
                + " -X POST -H 'Content-Type: application/json'" + named
                + " -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\""
                + " --data-binary @- \(curl.url(hooks.paths[0])) >/dev/null 2>&1 || true"
        case .sandbox(let port):
            // No `$PPID` and no task: they would name the VM's processes,
            // and the listener ignores them anyway. `${SANDBOX_NAME:-}` is
            // the sandbox's own variable; empty, `curl` drops the header.
            // No `--noproxy`: the way out of the VM is its proxy, which
            // turns `host.docker.internal` into this Mac's loopback.
            return "curl -s -m 2 -X POST -H 'Content-Type: application/json'" + named
                + " -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\""
                + " --data-binary @- http://\(SandboxInstall.host):\(port)\(hooks.paths[0]) >/dev/null 2>&1 || true"
        }
    }

    /// Where an installed hook command runs, and so how it reaches Evlat.
    public enum HookEndpoint: Equatable {
        /// This Mac, or a remote machine through its tunnel: the socket
        /// under the home, with the agent's pid and Evlat's task.
        case local
        /// A Docker sandbox: the Mac through the VM's proxy, on the sandbox
        /// listener's port, with the sandbox's name.
        case sandbox(port: UInt16)
    }
}
