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

    public let windows: [Window]
    /// Keys under `rate_limits` this adapter does not draw — `spend_limit`
    /// today, which has no length. Named so a new window is **visible**
    /// (`--capture` prints it) instead of silently missing, the way
    /// `SessionsProvider.unrecognizedStatuses` keeps an unknown status.
    public let unrecognizedWindows: Set<String>

    public init(windows: [Window], unrecognizedWindows: Set<String>) {
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

    /// A JSON number and nothing else. `JSONSerialization` hands booleans
    /// back as `NSNumber` too, and `as? Double` would take `true` for 1.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
