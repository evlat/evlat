import Foundation
import EvlatCore

/// Reads a `claude -p --output-format stream-json` stdout, line by line, into
/// the few events a chat shows.
///
/// The shapes are the ones measured on Claude Code 2.1.281
/// (`--verbose --include-partial-messages`): `system/init` names the session,
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
struct ChatStream: ChatParser {
    /// The events are the bubble's own (`ChatEvent`); these names are the
    /// stream's words for them.
    ///
    /// `system/init`: the turn reached Claude and this is its session.
    /// `system/permission_denied`: a tool call denied without a prompt —
    /// auto mode's classifier, a deny rule — or by a `PermissionRequest`
    /// hook (`decision_reason_type` `hook`: a card's answer). Measured on
    /// 2.1.281: `tool_name`, `tool_use_id`, `decision_reason_type`
    /// (`subcommandResults` for a rule on a compound command; `classifier`,
    /// `rule`, `mode`, `hook`, … in the schema) and `message`, the text the
    /// tool's result carries too.
    typealias Event = ChatEvent
    typealias ToolCall = ChatEvent.ToolCall
    typealias Denial = ChatEvent.Denial
    typealias Result = ChatEvent.Result

    /// The denial reason that is a card's answer: the card already says so.
    static let answeredReason = "hook"
    /// The denial reason that is auto mode's classifier: its own judgement,
    /// the one a turn that asks instead could get past. Any other (`rule`,
    /// `subcommandResults`, …) is a deny rule, which denies in every mode.
    static let retryableReason = "classifier"

    /// The key a line that is not a JSON object is counted under.
    static let unparsable = "(unparsable)"

    /// Words read but not known, with how often: `type`, or `system/<subtype>`.
    private(set) var unrecognized: [String: Int] = [:]

    private var buffer = Data()

    private static let quietTypes: Set<String> = ["rate_limit_event"]
    /// `hook_*` only appears with `--include-hook-events`, which a chat does
    /// not pass; it is listed so a measurement run reads the same.
    private static let quietSystem: Set<String> = [
        "status", "hook_started", "hook_progress", "hook_response", "compact_boundary",
        // A thinking model's token count, seen in a real turn.
        "thinking_tokens",
    ]

    init() {}

    /// Takes one chunk as read from the pipe and returns the events of every
    /// line it completed. The chunk may be a slice: indices are taken from
    /// `startIndex`, never from zero (`AGENTS.md` → Pitfalls).
    mutating func feed(_ chunk: Data) -> (events: [ChatEvent], replies: [Data]) {
        buffer.append(chunk)
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if let event = parse(line: line) { events.append(event) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        // One way: nothing is written back.
        return (events, [])
    }

    /// The pipe closed: a last line without a newline is still a line.
    mutating func finish() -> [Event] {
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
                let reason = json["decision_reason_type"] as? String
                return .permissionDenied(Denial(tool: json["tool_name"] as? String,
                                                toolUseID: json["tool_use_id"] as? String,
                                                reason: reason,
                                                message: json["message"] as? String,
                                                answered: reason == Self.answeredReason,
                                                retryable: reason == Self.retryableReason))
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
            return .toolResult(id: id, isError: block["is_error"] as? Bool ?? false,
                               output: Self.firstLine(of: block["content"]))
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

    /// The longest line kept from a tool's output.
    static let outputLimit = 160

    /// A result's `content` is a string or a list of blocks; the first
    /// non-blank line of its text, capped. Nothing else is kept: the output
    /// can be a whole file.
    static func firstLine(of content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        } else {
            return nil
        }
        // The scan stops at the first non-blank line rather than splitting
        // and trimming a whole file to keep one line of it.
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

    private static func content(of json: [String: Any]) -> [[String: Any]] {
        (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }
}
