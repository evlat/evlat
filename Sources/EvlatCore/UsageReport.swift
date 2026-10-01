import Foundation

/// What one `POST /usage/claude` said: the rate-limit windows and nothing else.
///
/// The body is Claude Code's status line input, which is **documented**
/// (`code.claude.com/docs/en/statusline`), and it carries far more than
/// limits: the model, the working directory, the session id, the cost. None of
/// it has a field here, so none of it can be kept, printed or logged by
/// accident — the parser reads `rate_limits` and lets the dictionary go.
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
    public let source: AgentSource
    public let windows: [Window]
    /// Keys under `rate_limits` this adapter does not draw — `spend_limit`
    /// today, which has no length. Named so a new window is **visible**
    /// (`--capture` prints it) instead of silently missing, the way
    /// `SessionsProvider.unrecognizedStatuses` keeps an unknown status.
    public let unrecognizedWindows: Set<String>

    public init(windows: [Window], unrecognizedWindows: Set<String>, source: AgentSource = .claude) {
        self.source = source
        self.windows = windows
        self.unrecognizedWindows = unrecognizedWindows
    }

    /// The windows Claude Code documents, and how long each one is.
    static let claudeWindows: [(key: String, minutes: Int)] = [("five_hour", 300), ("seven_day", 10080)]

    /// Reads Claude Code's status line JSON. No `rate_limits` is an empty
    /// report, not an error: it is absent before the session's first API
    /// answer and for anyone without a subscription. A window whose fields
    /// are missing or of the wrong type is left out; the other still counts.
    public init(claudeStatusLine json: [String: Any]) {
        guard let limits = json["rate_limits"] as? [String: Any] else {
            self.init(windows: [], unrecognizedWindows: [])
            return
        }
        let known = Set(Self.claudeWindows.map(\.key))
        let windows = Self.claudeWindows.compactMap { entry -> Window? in
            guard let fields = limits[entry.key] as? [String: Any],
                  let used = Self.number(fields["used_percentage"]),
                  let resets = Self.number(fields["resets_at"]) else { return nil }
            return Window(minutes: entry.minutes, usedPercent: used,
                          resetsAt: Date(timeIntervalSince1970: resets))
        }
        self.init(windows: windows, unrecognizedWindows: Set(limits.keys).subtracting(known))
    }

    /// The Antigravity CLI's Gemini windows, and how long each one is.
    /// Its `quota` holds two pools of the same two lengths: `gemini-*` and
    /// `3p-*` (the other vendors' models it offers). Only Gemini's is
    /// drawn — the bar has room for one more group of two windows
    /// (`UsageBlockModel.maxLines`) — so `3p-*` stays unrecognized and
    /// visible in `--capture`.
    static let antigravityWindows: [(key: String, minutes: Int)] = [("gemini-5h", 300), ("gemini-weekly", 10080)]

    /// Reads the Antigravity CLI's status line JSON (`agy` 1.2.14, measured;
    /// undocumented): `quota.<bucket>.remaining_fraction` (0–1) and
    /// `reset_time` (RFC 3339). Used is the rest of the fraction. Like
    /// Claude's, a missing `quota` is an empty report and a broken window is
    /// left out alone.
    public init(antigravityStatusLine json: [String: Any]) {
        guard let quota = json["quota"] as? [String: Any] else {
            self.init(windows: [], unrecognizedWindows: [], source: .antigravity)
            return
        }
        let known = Set(Self.antigravityWindows.map(\.key))
        let windows = Self.antigravityWindows.compactMap { entry -> Window? in
            guard let fields = quota[entry.key] as? [String: Any],
                  let remaining = Self.number(fields["remaining_fraction"]),
                  let text = fields["reset_time"] as? String,
                  let resets = Self.date(text) else { return nil }
            return Window(minutes: entry.minutes, usedPercent: (1 - remaining) * 100, resetsAt: resets)
        }
        self.init(windows: windows, unrecognizedWindows: Set(quota.keys).subtracting(known),
                  source: .antigravity)
    }

    /// RFC 3339, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// A JSON number and nothing else. `JSONSerialization` hands booleans
    /// back as `NSNumber` too, and `as? Double` would take `true` for 1.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
