import Foundation
import EvlatCore

/// One Codex chat turn over `codex app-server`'s stdio, JSON-RPC one object
/// per line: it reads what the server says into the bubble's events and
/// words what the turn writes back, in order —
///
/// 1. `initialize` (the launch's one line) → its response names the
///    server's version; `initialized` and `thread/start` (the first turn) or
///    `thread/resume` (a later one, by the thread's id) go out with the
///    chat's folder and mode.
/// 2. The thread's response names it (`started`); `turn/start` goes out
///    with the prompt.
/// 3. `item/*` notifications stream the reply and the tools;
///    `turn/completed` is the result.
///
/// The shapes are the ones measured on codex-cli 0.156.1 and its offline
/// schema (`codex app-server generate-json-schema`).
///
/// The server **asks** on this channel too: a command's or a file change's
/// approval is a card (`asked`), answered on stdin (`answer`). A request the
/// bubble does not know is refused at once with a JSON-RPC error and said in
/// the chat (`unsupported`): left unanswered, the turn would wait for ever.
/// An unknown notification is counted, not swallowed.
///
/// Pure: no process, no queue.
struct AppServerStream: ChatParser {
    /// The version whose protocol this reads: `codex app-server` is marked
    /// experimental, and another version may speak differently.
    static let measuredVersion = "0.156.1"

    /// The ids of Evlat's own requests: each response is matched by them.
    enum Call: Int {
        case initialize = 1
        case thread = 2
        case turn = 3
        case interrupt = 4
    }

    /// The JSON-RPC error code for a method the receiver does not have.
    static let methodNotFound = -32601

    private let spec: TurnSpec
    private var buffer = Data()
    private(set) var unrecognized: [String: Int] = [:]
    /// From `initialize`'s `userAgent`.
    private(set) var version: String?
    private(set) var threadID: String?
    private(set) var turnID: String?
    /// The last finished reply: the result's text.
    private var lastText: String?
    /// A file change's paths, by its item: its approval names only the item.
    private var changes: [String: [String]] = [:]

    init(spec: TurnSpec) {
        self.spec = spec
    }

    // MARK: - Lines out

    /// The launch's line. The client's name and version are Evlat's word
    /// for itself; the server does not act on them.
    static let initialize = request(.initialize, "initialize", ["clientInfo": ["name": "evlat", "version": "1"]])

    static func request(_ call: Call, _ method: String, _ params: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": call.rawValue, "method": method, "params": params])
    }

    static func notification(_ method: String) -> Data {
        line(["jsonrpc": "2.0", "method": method])
    }

    /// The answer to a server request whose id is `callID` (its JSON).
    static func answer(_ decision: ChatDecision, to callID: String?) -> Data {
        response(to: callID, ["result": ["decision": word(for: decision)]])
    }

    /// `accept`, `acceptForSession`, `decline`; Stop's denial is `cancel`,
    /// which also ends the turn. A question's answer is not this protocol's:
    /// declined.
    static func word(for decision: ChatDecision) -> String {
        switch decision {
        case .allow: return "accept"
        case .allowForSession: return "acceptForSession"
        case .deny(let interrupt): return interrupt ? "cancel" : "decline"
        case .answer: return "decline"
        }
    }

    /// A response carries back the request's id as it came — a number or a
    /// string.
    private static func response(to callID: String?, _ body: [String: Any]) -> Data {
        var object = body
        object["jsonrpc"] = "2.0"
        object["id"] = callID.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed])
        } ?? NSNull()
        return line(object)
    }

    private static func line(_ object: [String: Any]) -> Data {
        // Strings, numbers and nested dictionaries of them always serialise;
        // the fallback is unreachable.
        var data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The chat's mode in the thread's own terms; the stored id read back,
    /// else the standard mode.
    private var mode: CodexMode { CodexMode(rawValue: spec.mode.id) ?? .standard }

    /// The prompt, the attached files named under it.
    private var prompt: String {
        spec.attachments.isEmpty ? spec.prompt : spec.prompt + "\n\n" + spec.attachments.joined(separator: "\n")
    }

    func stopLine() -> Data? {
        guard let threadID, let turnID else { return nil }
        return Self.request(.interrupt, "turn/interrupt", ["threadId": threadID, "turnId": turnID])
    }

    // MARK: - Lines in

    mutating func feed(_ chunk: Data) -> (events: [ChatEvent], replies: [Data]) {
        buffer.append(chunk)
        var events: [ChatEvent] = []
        var replies: [Data] = []
        // Indices from `startIndex`: the chunk may be a slice (`AGENTS.md`).
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            read(line, &events, &replies)
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return (events, replies)
    }

    mutating func finish() -> [ChatEvent] {
        defer { buffer = Data() }
        var events: [ChatEvent] = []
        var replies: [Data] = []
        read(buffer, &events, &replies)
        return events
    }

    /// The key a line that is not a JSON object is counted under.
    static let unparsable = "(unparsable)"

    private mutating func read(_ line: Data, _ events: inout [ChatEvent], _ replies: inout [Data]) {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { return }
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            unrecognized[Self.unparsable, default: 0] += 1
            return
        }
        let method = json["method"] as? String
        let id = json["id"]
        switch (method, id) {
        case (nil, .some(let id)):
            responded(id, json, &events, &replies)
        case (.some(let method), .some(let id)):
            asked(method, id: id, params: json["params"] as? [String: Any] ?? [:], &events, &replies)
        case (.some(let method), nil):
            notified(method, params: json["params"] as? [String: Any] ?? [:], &events)
        default:
            unrecognized[Self.unparsable, default: 0] += 1
        }
    }

    /// A response to one of Evlat's requests.
    private mutating func responded(_ id: Any, _ json: [String: Any], _ events: inout [ChatEvent],
                                    _ replies: inout [Data]) {
        guard let number = id as? Int, let call = Call(rawValue: number) else {
            unrecognized["response", default: 0] += 1
            return
        }
        if let error = json["error"] as? [String: Any] {
            // Interrupting a turn that just ended is no failure.
            guard call != .interrupt else { return }
            events.append(.result(.init(subtype: "error", isError: true, text: error["message"] as? String)))
            return
        }
        let result = json["result"] as? [String: Any] ?? [:]
        switch call {
        case .initialize:
            version = Self.version(fromUserAgent: result["userAgent"] as? String)
            replies.append(Self.notification("initialized"))
            var params: [String: Any] = ["cwd": spec.directory, "approvalPolicy": mode.approvalPolicy,
                                         "sandbox": mode.sandbox]
            if spec.resume {
                params["threadId"] = spec.sessionID
                replies.append(Self.request(.thread, "thread/resume", params))
            } else {
                replies.append(Self.request(.thread, "thread/start", params))
            }
        case .thread:
            guard let thread = (result["thread"] as? [String: Any])?["id"] as? String, !thread.isEmpty else {
                events.append(.result(.init(subtype: "error", isError: true, text: nil)))
                return
            }
            threadID = thread
            events.append(.started(sessionID: thread))
            replies.append(Self.request(.turn, "turn/start",
                                        ["threadId": thread, "input": [["type": "text", "text": prompt]]]))
        case .turn:
            if let turn = (result["turn"] as? [String: Any])?["id"] as? String { turnID = turn }
        case .interrupt:
            break
        }
    }

    /// The server's request: a card, or a refusal.
    private mutating func asked(_ method: String, id: Any, params: [String: Any], _ events: inout [ChatEvent],
                                _ replies: inout [Data]) {
        let callID = (try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) }
        let reason = (params["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"] as? String
            events.append(.asked(ChatRequest(id: UUID().uuidString, token: nil, callID: callID, tool: Self.shell,
                                             subject: Self.commandLine(params) ?? command, command: command,
                                             reason: reason, replyTarget: .runner)))
        case "item/fileChange/requestApproval":
            let paths = (params["itemId"] as? String).flatMap { changes[$0] } ?? []
            events.append(.asked(ChatRequest(id: UUID().uuidString, token: nil, callID: callID, tool: Self.edit,
                                             subject: paths.isEmpty ? nil : paths.joined(separator: ", "),
                                             reason: reason, replyTarget: .runner)))
        default:
            unrecognized["request/" + method, default: 0] += 1
            replies.append(Self.response(to: callID, ["error": [
                "code": Self.methodNotFound,
                "message": "Evlat's chat cannot answer \(method).",
            ]]))
            events.append(.unsupported(method))
        }
    }

    /// The canonical names a command and a file change are shown under.
    static let shell = "Bash"
    static let edit = "Edit"

    /// What the server says without asking.
    private mutating func notified(_ method: String, params: [String: Any], _ events: inout [ChatEvent]) {
        switch method {
        case "turn/started":
            if let turn = (params["turn"] as? [String: Any])?["id"] as? String { turnID = turn }
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String, !delta.isEmpty { events.append(.textDelta(delta)) }
        case "item/started":
            if let item = params["item"] as? [String: Any], let event = started(item) { events.append(event) }
        case "item/completed":
            if let item = params["item"] as? [String: Any], let event = completed(item) { events.append(event) }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            switch turn["status"] as? String {
            case "completed":
                events.append(.result(.init(subtype: "success", isError: false, text: lastText)))
            case "interrupted":
                events.append(.result(.init(subtype: "interrupted", isError: true, text: nil)))
            default:
                let error = (turn["error"] as? [String: Any])?["message"] as? String
                events.append(.result(.init(subtype: turn["status"] as? String ?? "error", isError: true,
                                            text: error)))
            }
        case let quiet where Self.isQuiet(quiet):
            break
        default:
            unrecognized[method, default: 0] += 1
        }
    }

    /// Known, and nothing a chat shows: the thread's bookkeeping, usage,
    /// the user's hooks and MCP servers starting, a reasoning summary.
    static func isQuiet(_ method: String) -> Bool {
        quietMethods.contains(method) || quietPrefixes.contains { method.hasPrefix($0) }
    }

    private static let quietMethods: Set<String> = [
        "thread/started", "thread/status/changed", "thread/tokenUsage/updated", "thread/name/updated",
        "serverRequest/resolved", "warning", "error", "remoteControl/status/changed",
        "turn/diff/updated", "turn/plan/updated", "item/commandExecution/outputDelta",
        "item/fileChange/outputDelta", "item/fileChange/patchUpdated", "item/plan/delta",
    ]

    private static let quietPrefixes = ["account/", "hook/", "mcpServer/", "item/reasoning/"]

    /// The items a chat shows as a tool line when they start.
    private mutating func started(_ item: [String: Any]) -> ChatEvent? {
        guard let type = item["type"] as? String, let id = item["id"] as? String else { return nil }
        let tool: ChatEvent.ToolCall
        switch type {
        case "commandExecution":
            tool = .init(id: id, name: Self.shell, subject: Self.commandLine(item) ?? item["command"] as? String)
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            changes[id] = paths
            tool = .init(id: id, name: Self.edit, subject: paths.first)
        case "mcpToolCall":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            tool = .init(id: id, name: name.isEmpty ? type : name, subject: nil)
        case "dynamicToolCall":
            tool = .init(id: id, name: item["tool"] as? String ?? type, subject: nil)
        case "webSearch":
            tool = .init(id: id, name: "WebSearch", subject: item["query"] as? String)
        case let quiet where Self.quietItems.contains(quiet):
            return nil
        default:
            unrecognized["item/" + type, default: 0] += 1
            return nil
        }
        return .assistant(text: nil, tools: [tool])
    }

    /// What a finished item adds: the reply's text, a tool's outcome.
    private mutating func completed(_ item: [String: Any]) -> ChatEvent? {
        guard let type = item["type"] as? String, let id = item["id"] as? String else { return nil }
        let status = item["status"] as? String
        switch type {
        case "agentMessage":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            lastText = text
            return .assistant(text: text, tools: [])
        case "commandExecution":
            let failed = status != "completed" || (item["exitCode"] as? Int).map { $0 != 0 } == true
            return .toolResult(id: id, isError: failed, output: Self.firstLine(of: item["aggregatedOutput"] as? String))
        case "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch":
            return .toolResult(id: id, isError: status != nil && status != "completed", output: nil)
        default:
            // Unknown types were counted when they started.
            return nil
        }
    }

    /// Items a chat does not draw: the prompt it sent, the model's thinking,
    /// and the thread's own housekeeping.
    private static let quietItems: Set<String> = [
        "userMessage", "agentMessage", "reasoning", "plan", "hookPrompt", "contextCompaction",
        "enteredReviewMode", "exitedReviewMode", "imageView", "sleep", "functionCallOutput",
    ]

    /// The command as it was asked, not its shell wrapper: the first parsed
    /// action's (`/bin/zsh -lc 'echo one > a.txt'` → `echo one > a.txt`).
    static func commandLine(_ object: [String: Any]) -> String? {
        ((object["commandActions"] as? [[String: Any]])?.first?["command"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `evlat/0.156.1 (Mac OS 26.4.1; arm64) …` → `0.156.1`: between the
    /// first `/` and the first space.
    static func version(fromUserAgent agent: String?) -> String? {
        guard let agent, let slash = agent.firstIndex(of: "/") else { return nil }
        let rest = agent[agent.index(after: slash)...]
        let version = rest.prefix { !$0.isWhitespace }
        return version.isEmpty ? nil : String(version)
    }

    /// The longest line kept from a command's output.
    static let outputLimit = 160

    /// The first non-blank line of a command's output, capped: the output
    /// can be a whole file, so the scan stops at that line rather than
    /// splitting all of it.
    static func firstLine(of text: String?) -> String? {
        guard let text else { return nil }
        var rest = text[...]
        while !rest.isEmpty {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let line = rest[..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                return line.count > outputLimit ? String(line.prefix(outputLimit)) + "…" : line
            }
            rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...]
        }
        return nil
    }
}
