import Foundation

/// What one `POST /usage/{source}` said: the rate-limit windows and nothing
/// else.
///
/// The body is the agent's status line input — Claude Code's is
/// **documented** (`code.claude.com/docs/en/statusline`) — and it carries far
/// more than limits: the model, the working directory, the session id, the
/// cost. None of it has a field here, so none of it can be kept, printed or
/// logged by accident — the parser reads the definition's root
/// (`StatusLineUsage`) and lets the dictionary go.
///
/// Pure and clockless, like `LocalAPI`: when the numbers were seen is stamped
/// by the provider that receives the report.
public struct UsageReport: Equatable {
    public struct Window: Equatable {
        /// The window's length. The key → minutes mapping is this adapter's
        /// (`five_hour` → 300); the bar derives its label from the minutes.
        public let minutes: Int
        /// As the source said it: 0–100, and past 100 when the limit was run
        /// over.
        public let usedPercent: Double
        public let resetsAt: Date

        public init(minutes: Int, usedPercent: Double, resetsAt: Date) {
            self.minutes = minutes
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    /// Whose status line said it: the provider it goes to.
    public let source: AgentID
    public let windows: [Window]
    /// Keys under the root this adapter does not draw — Claude's
    /// `spend_limit`, which has no length, and Antigravity's `3p-*`. Named so a new window is **visible**
    /// (`--capture` prints it) instead of silently missing, the way
    /// `SessionsProvider.unrecognizedStatuses` keeps an unknown status.
    public let unrecognizedWindows: Set<String>

    public init(windows: [Window], unrecognizedWindows: Set<String>, source: AgentID) {
        self.source = source
        self.windows = windows
        self.unrecognizedWindows = unrecognizedWindows
    }

    /// Reads an agent's status line JSON, as its definition says
    /// (`StatusLineUsage`). No root is an empty report, not an error:
    /// Claude's `rate_limits` is absent before the session's first API
    /// answer and for anyone without a subscription. A window whose fields
    /// are missing or of the wrong type is left out; the other still counts.
    /// An agent with no status line reads as an empty report.
    public init(statusLine json: [String: Any], source agent: some Agent) {
        self.init(statusLine: json, source: agent.id, usage: agent.statusLineUsage)
    }

    public init(statusLine json: [String: Any], source: AgentID, usage: StatusLineUsage?) {
        guard let usage, let root = json[usage.root] as? [String: Any] else {
            self.init(windows: [], unrecognizedWindows: [], source: source)
            return
        }
        let known = Set(usage.windows.map(\.key))
        let windows = usage.windows.compactMap { entry -> Window? in
            guard let fields = root[entry.key] as? [String: Any] else { return nil }
            return Self.window(fields, minutes: entry.minutes, usage.reading)
        }
        self.init(windows: windows, unrecognizedWindows: Set(root.keys).subtracting(known), source: source)
    }

    private static func window(_ fields: [String: Any], minutes: Int,
                               _ reading: StatusLineUsage.Reading) -> Window? {
        switch reading {
        case .usedPercentage:
            guard let used = number(fields["used_percentage"]),
                  let resets = number(fields["resets_at"]) else { return nil }
            return Window(minutes: minutes, usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        // Used is the rest of the fraction.
        case .remainingFraction:
            guard let remaining = number(fields["remaining_fraction"]),
                  let text = fields["reset_time"] as? String,
                  let resets = date(text) else { return nil }
            return Window(minutes: minutes, usedPercent: (1 - remaining) * 100, resetsAt: resets)
        }
    }

    /// RFC 3339, with or without fractional seconds. A formatter set for
    /// fractions rejects the plain form, so both are tried; built once,
    /// since the status line posts on every draw.
    static func date(_ text: String) -> Date? {
        plainFormatter.date(from: text) ?? fractionalFormatter.date(from: text)
    }

    private static let plainFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A JSON number and nothing else. `JSONSerialization` hands booleans
    /// back as `NSNumber` too, and `as? Double` would take `true` for 1.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
