import Foundation

/// The body of `POST /signal`: an outside program's row, read and
/// cleaned. The sender is unknown, so everything here is a limit — on what
/// it may name, how long its row lives and what its text may draw.
///
/// Each POST is the **whole** row (stateless full replacement): a field that
/// is absent is absent, never "keep the last one". A script then needs no
/// memory of what it sent before.
///
/// The identity is **not** read from the body. `provider`, `entity`,
/// `fidelity` and `kind` are written by `signal(phaseStart:machine:dim:)`
/// alone — and the machine, for a report that came through a tunnel, is the
/// listener's, never the sender's — so a
/// sender can neither take over a session's row nor claim an internal
/// provider's name — by construction, not by a deny list.
public struct SignalReport: Equatable {
    /// The route. A POST only: a browser's no-cors request is a GET, so the
    /// `Origin` check covers every browser that could reach this
    /// (`LocalAPI.dispatch`).
    public static let path = "/signal"
    /// The listener's key travels in this header (`LocalAPI.Listener`), in the
    /// `X-Evlat-*` family the hook command already speaks.
    public static let keyHeader = "X-Evlat-Key"
    /// `Signal.provider` for every outside row.
    public static let provider = "signal"

    /// A row may ask to live at most a day…
    public static let ttlLimit = 86400
    /// …and a finished one at most an hour. On a finish the limit is only the
    /// validation of what was sent: a `done` or `failed` row lives until the
    /// user sees it, at most `SignalsProvider.finishLifetime`, whatever its ttl
    /// (`SignalsProvider`). The cut stays so the parse is unchanged.
    public static let finishedTTLLimit = 3600
    public static let idLimit = 64
    public static let labelLimit = 80
    public static let detailLimit = 200
    public static let senderLimit = 24
    /// Combining marks kept in a row (`clean`).
    public static let markRun = 3

    /// The words a sender may use. `idle` is not among them: a row that says
    /// it is doing nothing has no place on the bar. No new `Phase` value is
    /// opened — `done` is the bar's `review`, "just finished".
    public enum Word: String, CaseIterable, Equatable {
        case working, waiting, done, failed

        public var phase: Phase {
            switch self {
            case .working: return .working
            case .waiting: return .waiting
            case .done: return .review
            case .failed: return .failed
            }
        }
    }

    /// `[A-Za-z0-9._-]{1,64}`. No `:`, so `signal:<id>` can never be read as
    /// another producer's namespace.
    public let id: String
    /// Seconds from now; `0` removes the row. Already cut to the finished
    /// limit for `done` and `failed`.
    public let ttl: Int
    /// `nil` only when `ttl == 0`: a removal reads no phase.
    public let word: Word?
    /// Never empty: the `id` when the sender gave none.
    public let label: String
    /// 0…1, finite.
    public let progress: Double?
    public let detail: String?
    public let sender: String?

    /// Why a body was refused. The raw value is the stable `code` of the
    /// `400` body (`LocalAPI.error`); a script can branch on it.
    public enum Rejection: String, Error, CaseIterable, Equatable {
        case invalidId, invalidTtl, invalidPhase, invalidProgress
        case invalidLabel, invalidDetail, invalidSender

        public var code: String { rawValue }

        /// English, like every error body here: it is read by a developer or
        /// a script, and must not change with the interface language.
        public var message: String {
            switch self {
            case .invalidId: return "id must match [A-Za-z0-9._-]{1,64}"
            case .invalidTtl: return "ttl must be a whole number of seconds from 0 to 86400"
            case .invalidPhase: return "phase must be one of working, waiting, done, failed"
            case .invalidProgress: return "progress must be a number from 0 to 1"
            case .invalidLabel: return "label must be a string"
            case .invalidDetail: return "detail must be a string"
            case .invalidSender: return "sender must be a string"
            }
        }
    }

    /// Reads a JSON object. Text that is too long is **cut**, not refused —
    /// a slightly long label is not worth failing someone's build over; a
    /// value of the wrong kind is refused, because it is the writer's bug and
    /// staying silent would hide it.
    public static func parse(json: [String: Any]) -> Result<SignalReport, Rejection> {
        guard let id = json["id"] as? String, isValid(id: id) else { return .failure(.invalidId) }
        guard let seconds = wholeNumber(json["ttl"]), (0...ttlLimit).contains(seconds) else {
            return .failure(.invalidTtl)
        }
        // A removal says nothing else: whatever else the body holds is not
        // read, so a stale phase in a script's `--clear` cannot refuse it.
        guard seconds > 0 else {
            return .success(SignalReport(id: id, ttl: 0, word: nil, label: id,
                                         progress: nil, detail: nil, sender: nil))
        }
        guard let spoken = json["phase"] as? String, let word = Word(rawValue: spoken) else {
            return .failure(.invalidPhase)
        }
        var progress: Double?
        if let value = present(json["progress"]) {
            guard let number = number(value), (0...1).contains(number) else { return .failure(.invalidProgress) }
            progress = number
        }
        guard let label = text(json["label"], limit: labelLimit) else { return .failure(.invalidLabel) }
        guard let detail = text(json["detail"], limit: detailLimit) else { return .failure(.invalidDetail) }
        guard let sender = text(json["sender"], limit: senderLimit) else { return .failure(.invalidSender) }
        let finished = word == .done || word == .failed
        return .success(SignalReport(id: id, ttl: finished ? min(seconds, finishedTTLLimit) : seconds,
                                     word: word, label: label.value ?? id, progress: progress,
                                     detail: detail.value, sender: sender.value))
    }

    /// The row as the bar sees it. The identity is written here and nowhere
    /// else. `phaseStart` is the stamp: when this phase began, which the
    /// provider keeps across updates of the same phase (`SignalsProvider`).
    ///
    /// `machine` is the remote computer the report came from: its
    /// id namespaces the row — `signal:<machine>:<id>`, so the same id on two
    /// machines and on this Mac is three rows — and its name, with `dim`, is
    /// the row's `Signal.machine`. `nil` for this Mac's own port.
    ///
    /// Only valid for a report that has a word; a removal has no row.
    public func signal(phaseStart: Date, machine: Signal.Machine.Identity? = nil,
                       dim: Signal.Machine.Dim? = nil) -> Signal? {
        guard let word else { return nil }
        let entity = machine.map { "\(Self.provider):\($0.id):\(id)" } ?? "\(Self.provider):\(id)"
        return Signal(provider: Self.provider, entity: entity, kind: .custom,
                      phase: word.phase, progress: progress, label: label, detail: detail,
                      fidelity: .manual, rawStatus: word.rawValue, updatedAt: phaseStart,
                      machine: machine.map { Signal.Machine(name: $0.name, dim: dim) }, sender: sender)
    }

    // MARK: - Reading

    static func isValid(id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard (1...idLimit).contains(scalars.count) else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true   // 0-9 A-Z a-z
            case 0x2E, 0x5F, 0x2D: return true                         // . _ -
            default: return false
            }
        }
    }

    /// A JSON `null` is an absent field, not a wrong one: a script that
    /// serialises an unset variable as `null` is saying "none".
    private static func present(_ value: Any?) -> Any? {
        guard let value, !(value is NSNull) else { return nil }
        return value
    }

    /// A JSON number and nothing else (`UsageReport.number`): `JSONSerialization`
    /// hands booleans back as `NSNumber` too, and `true` must not read as 1.
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// `60` and `60.0` alike; `1.5` is not a number of seconds.
    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let value = present(value), let number = number(value),
              number == number.rounded(.towardZero), abs(number) <= Double(Int32.max) else { return nil }
        return Int(number)
    }

    /// The outer optional is "the field is valid"; the inner one is "it says
    /// something". Absent, `null` and text that cleans away to nothing all
    /// come out as `Cleaned(value: nil)`.
    private struct Cleaned { let value: String? }

    private static func text(_ value: Any?, limit: Int) -> Cleaned? {
        guard let value = present(value) else { return Cleaned(value: nil) }
        guard let string = value as? String else { return nil }
        let cleaned = clean(string, limit: limit)
        return Cleaned(value: cleaned.isEmpty ? nil : cleaned)
    }

    /// Cleaned first, cut second, trimmed last — so the limit counts what is
    /// drawn and a cut never leaves the space it landed on.
    ///
    /// A line break (and a tab) becomes a space: the row is one line. Every
    /// other control (`Cc`) and format (`Cf`) character is dropped: bidi
    /// overrides and isolates would let a label draw itself backwards over its
    /// neighbours, and zero-width characters make two different labels look
    /// the same. The price is that a joined emoji sequence falls apart into
    /// its pieces (`U+200D` is `Cf`); the row stays readable.
    ///
    /// The limit counts characters as seen (`Character`, a grapheme), not
    /// bytes and not scalars: a flag is one. So a run of combining marks
    /// (`Mn`, `Me`) is cut to `markRun` first — hundreds on one letter are one
    /// grapheme that passes any count and draws over the rows around it;
    /// a written script needs two or three, a keycap two.
    public static func clean(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var marks = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
                marks = 0
                scalars.append(" ")
            default:
                switch scalar.properties.generalCategory {
                case .control, .format: continue
                case .nonspacingMark, .enclosingMark:
                    marks += 1
                    if marks <= markRun { scalars.append(scalar) }
                default:
                    marks = 0
                    scalars.append(scalar)
                }
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }
}
