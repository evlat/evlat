import Foundation

/// The local endpoint: which routes exist, who is allowed to reach them and
/// what comes back. All of it is pure — `Data` and `String` in, a `Response`
/// out — so the rules that matter can be tested without a socket. `phase-3`'s
/// listener adds transport and nothing else.
public enum LocalAPI {
    /// The port the installed hook commands carry as **plain text**. That is
    /// the whole reason there is no stored setting for it: the command in the
    /// user's settings file says `48151`, so an app listening anywhere else
    /// would simply never be spoken to, and neither side would report an error
    /// (`plan.md` → Göç). An override exists for development only, and it is an
    /// environment variable read on the app side (`EVLAT_PORT`, `phase-3`).
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
        case hook(AgentSource)
        /// A status line relaying its rate limits (`AgentSource.usagePath`).
        case usage(AgentSource)
        case health
    }

    /// The table is five rows and it is this `switch`.
    ///
    /// v1's generic route table (`Route.required`, `read`/`action`/`mac` kinds,
    /// a semaphore answering on the main queue) is **not** ported: every
    /// endpoint that needed it is out of scope for v2, and five rows do not
    /// earn the generality.
    ///
    /// `curl` and the installed hook command never send `Origin`; a browser
    /// sends it on every cross-origin request. That alone is not enough,
    /// because a same-origin GET carries none — so a page that resolves its own
    /// name to 127.0.0.1 (DNS rebinding) could still reach a GET route. Its own
    /// name stays in `Host`, which is the second check. What is left is a
    /// browser's no-cors POST, and every side-effecting route here is POST, so
    /// that request carries an `Origin` and is refused by the first check.
    ///
    /// The path is **not normalised**: `/hook/codex/../claude` matches nothing.
    /// Collapsing it would let a route be reached by a spelling neither check
    /// above ever saw.
    public static func dispatch(method: String, target: String, origin: String?, host: String?) -> Dispatch {
        if origin != nil { return .forbidden }
        if let host = host, !isLoopback(host: host) { return .forbidden }
        // The query is dropped, not rejected: no v2 endpoint takes an argument,
        // and a path is what the table is written in. The **encoded** path is
        // what is compared: `path` would unescape it, and `/%68ook` is then a
        // second spelling of a route that neither check above examined.
        let path = URLComponents(string: target)?.percentEncodedPath ?? target
        switch (method, path) {
        // Claude's installed command posts to `/hook`; `/hook/claude` is the
        // synonym v1 accepted, and dropping it would change the contract
        // silently for anyone whose hooks spell it that way.
        case ("POST", AgentSource.claude.hookPath), ("POST", "/hook/claude"): return .hook(.claude)
        case ("POST", AgentSource.codex.hookPath): return .hook(.codex)
        case ("POST", let path) where AgentSource.claude.usagePath == path: return .usage(.claude)
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
    }

    /// The answer, plus what the app should hand to the main queue. The
    /// delivery is separate from the response on purpose: the hook's `curl`
    /// runs with `-m 2` and must not wait for the main queue, so the listener
    /// writes the response from the server queue and passes this **parsed**
    /// value across (a raw body reaches 8 KB).
    public struct Outcome {
        public let response: Response
        public let delivery: Delivery?
    }

    public static func handle(_ request: HTTPRequest) -> Outcome {
        switch dispatch(method: request.method, target: request.target,
                        origin: request.origin, host: request.host) {
        case .forbidden:
            return Outcome(response: Response(status: .forbidden,
                                              body: error("forbidden", "browser requests are not accepted")),
                           delivery: nil)
        case .notFound:
            return Outcome(response: Response(status: .notFound,
                                              body: error("notFound", "no such endpoint")),
                           delivery: nil)
        case .health:
            // v1 answered the single word `ok` under `Content-Type:
            // application/json`, which is not JSON. Nothing reads this body
            // yet, so it was corrected rather than carried over.
            return Outcome(response: Response(status: .ok, body: "{\"ok\":true}"), delivery: nil)
        case .usage:
            // Only Claude has a usage route (`AgentSource.usagePath`), so the
            // body is its status line input.
            guard let json = jsonObject(request.body) else { return badRequest }
            // `{}` for the same reason as a hook: the relay throws the answer
            // away, and nothing from this body is ever sent back anywhere.
            return Outcome(response: Response(status: .ok, body: "{}"),
                           delivery: .usage(UsageReport(claudeStatusLine: json)))
        case .hook(let source):
            guard var json = jsonObject(request.body) else { return badRequest }
            // These two keys are written **only** here, from the headers, and a
            // body that carries them has them deleted. This endpoint asks for
            // no identity, so otherwise any local process could put `evlat_pid`
            // in a body and choose where a session appears to be running, or
            // claim with `evlat_task` to be an errand Evlat started itself.
            //
            // The stamp happens before the translation, which is why an adapter
            // has to pass these keys through (`AgentSource.canonical`).
            if let taskID = request.taskID { json[HookEvent.taskKey] = taskID }
            else { json.removeValue(forKey: HookEvent.taskKey) }
            if let pid = request.pid { json[HookEvent.pidKey] = pid }
            else { json.removeValue(forKey: HookEvent.pidKey) }
            // Exactly `{}`, and that is not incidental. The installed command
            // throws the answer away (`>/dev/null`), but if this body ever did
            // reach Claude Code, a stray JSON object would allow or deny a
            // permission on the user's behalf (`proje.md` → tuzaklar).
            return Outcome(response: Response(status: .ok, body: "{}"),
                           delivery: .hook(HookEvent(json: source.canonical(json), source: source)))
        }
    }

    /// A body that is not a JSON object delivers nothing: half a reading would
    /// move the bar on a request Evlat could not read.
    private static var badRequest: Outcome {
        Outcome(response: Response(status: .badRequest, body: error("badRequest", "a JSON object is expected")),
                delivery: nil)
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
    /// code and the string that lands in the file, so v1's installs and v2's
    /// read the same: the route, the port and the header names below are the
    /// same ones `dispatch` and `HTTPRequest` read, so a change to any of them
    /// changes this string and breaks the golden test that pins it
    /// (`LocalAPITests.testTheInstalledHookCommandIsUnchanged`).
    ///
    /// It fails silently by construction: `-m 2` so a closed Evlat cannot stall
    /// the agent, `>/dev/null 2>&1` because the answer must never reach Claude
    /// Code, and `|| true` so a hook never fails over Evlat. `$PPID` and
    /// `${EVLAT_TASK:-}` are plain text — they resolve when the hook runs, not
    /// when it is installed.
    public static func installedHookCommand(for source: AgentSource) -> String {
        "curl -s -m 2 -X POST -H 'Content-Type: application/json'"
            + " -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\""
            + " --data-binary @- http://127.0.0.1:\(defaultPort)\(source.hookPath) >/dev/null 2>&1 || true"
    }
}
