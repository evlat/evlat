import Foundation

/// Reads a `claude -p --output-format stream-json` stdout, line by line, into
/// the few events a chat shows (`011`).
///
/// The shapes are the ones measured on Claude Code 2.1.281 (`011/phase-1`,
/// `--verbose --include-partial-messages`): `system/init` names the session,
/// a partial message's `text_delta` streams the reply, an `assistant` message
/// carries the finished text and tool calls, a `user` message carries tool
/// results, `result` ends the turn.
///
/// **An unknown word is counted, not swallowed** — the `rawStatus` rule: a
/// renamed type would otherwise make the chat silently empty. What is known
/// and says nothing a chat shows (`system/status`, `rate_limit_event`, the
/// partial-message machinery around the text) is quiet and uncounted.
///
/// Pure: no process, no queue. The shell feeds it on the main queue.
public struct ChatStream {
    public enum Event: Equatable {
        /// `system/init`: the turn reached Claude and this is its session.
        case started(sessionID: String)
        /// A piece of the reply as it is written.
        case textDelta(String)
        /// A finished assistant message: its text (blocks joined) and the
        /// tools it calls, each reduced to one line.
        case assistant(text: String?, tools: [ToolCall])
        case toolResult(id: String, isError: Bool)
        case result(Result)
        /// `system/permission_denied`: a tool call nobody approved.
        case permissionDenied(tool: String?)
    }

    public struct ToolCall: Equatable {
        public let id: String
        public let name: String
        /// `HookEvent.subject(of:)` over the input — the same line a session's
        /// card shows. The raw input is never kept (`Write` carries a file).
        public let subject: String?

        public init(id: String, name: String, subject: String?) {
            self.id = id
            self.name = name
            self.subject = subject
        }
    }

    public struct Result: Equatable {
        /// `success`, or an `error_*` word.
        public let subtype: String
        public let isError: Bool
        /// The final reply text, when the source gives one.
        public let text: String?

        public init(subtype: String, isError: Bool, text: String?) {
            self.subtype = subtype
            self.isError = isError
            self.text = text
        }
    }

    /// The key a line that is not a JSON object is counted under.
    public static let unparsable = "(unparsable)"

    /// Words read but not known, with how often: `type`, or `system/<subtype>`.
    public private(set) var unrecognized: [String: Int] = [:]

    private var buffer = Data()

    private static let quietTypes: Set<String> = ["rate_limit_event"]
    /// `hook_*` only appears with `--include-hook-events`, which a chat does
    /// not pass; it is listed so a measurement run reads the same.
    private static let quietSystem: Set<String> = [
        "status", "hook_started", "hook_progress", "hook_response", "compact_boundary",
    ]

    public init() {}

    /// Takes one chunk as read from the pipe and returns the events of every
    /// line it completed. The chunk may be a slice: indices are taken from
    /// `startIndex`, never from zero (`proje.md` → Tuzaklar).
    public mutating func feed(_ chunk: Data) -> [Event] {
        buffer.append(chunk)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if let event = parse(line: line) { events.append(event) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return events
    }

    /// The pipe closed: a last line without a newline is still a line.
    public mutating func finish() -> [Event] {
        defer { buffer = Data() }
        return parse(line: buffer).map { [$0] } ?? []
    }

    /// One line. Blank lines are nothing; everything else is an event, quiet
    /// or counted.
    mutating func parse(line: Data) -> Event? {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = json["type"] as? String else {
            unrecognized[Self.unparsable, default: 0] += 1
            return nil
        }
        switch type {
        case "system":
            let subtype = json["subtype"] as? String ?? ""
            switch subtype {
            case "init":
                guard let id = json["session_id"] as? String, !id.isEmpty else { break }
                return .started(sessionID: id)
            case "permission_denied":
                return .permissionDenied(tool: json["tool_name"] as? String)
            case let quiet where Self.quietSystem.contains(quiet):
                return nil
            default:
                break
            }
            unrecognized["system/\(subtype)", default: 0] += 1
            return nil
        case "stream_event":
            // Everything but the reply's text is machinery around it.
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .textDelta(text)
        case "assistant":
            let blocks = Self.content(of: json)
            let texts = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            let tools = blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { block -> ToolCall? in
                guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
                return ToolCall(id: id, name: name, subject: HookEvent.subject(of: block["input"] as? [String: Any]))
            }
            guard !texts.isEmpty || !tools.isEmpty else { return nil }
            return .assistant(text: texts.isEmpty ? nil : texts.joined(separator: "\n\n"), tools: tools)
        case "user":
            // A replayed prompt says nothing new; only tool results matter.
            // One message holds one result in practice; the first is read.
            guard let block = Self.content(of: json).first(where: { $0["type"] as? String == "tool_result" }),
                  let id = block["tool_use_id"] as? String else { return nil }
            return .toolResult(id: id, isError: block["is_error"] as? Bool ?? false)
        case "result":
            return .result(Result(subtype: json["subtype"] as? String ?? "",
                                  isError: json["is_error"] as? Bool ?? false,
                                  text: (json["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
        case let quiet where Self.quietTypes.contains(quiet):
            return nil
        default:
            unrecognized[type, default: 0] += 1
            return nil
        }
    }

    private static func content(of json: [String: Any]) -> [[String: Any]] {
        (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }
}
