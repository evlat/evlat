import Foundation

/// Codex's rate-limit windows, read from its own session log:
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
///
/// **The format is undocumented** (seen in codex-cli 0.156.1), so `Fidelity`
/// is `.derived`, and when it drifts this provider goes **quiet** rather than
/// guessing: a window whose fields are missing or of the wrong type is left
/// out, and a file with nothing usable leaves the last good reading in place
/// and raises `lastReadFailed`. A wrong number on the bar is worse than none.
///
/// Reading happens only in `reload()` (`Reloadable`): the shell calls it when
/// the bar opens. `currentSignals()` answers from memory — it is asked every
/// 1.5 s and on every hook event, and the newest rollout can be tens of MB.
public final class CodexUsageProvider: Provider, Reloadable {
    public static let id = "codex-usage"
    public var id: String { Self.id }
    /// The name the windows are grouped under on the bar. A proper name, not
    /// catalogue text (`Signal.Usage.group`).
    public static let group = "Codex"
    /// How much of the newest file is read, from its end. Never the whole
    /// file: a long session's rollout was measured at 62 MB.
    public static let tailBytes = 256 * 1024

    private let directory: URL
    private var reading: [Signal] = []
    /// The newest rollout was there and nothing in its tail could be used:
    /// no `rate_limits` line, all of them malformed, or one line longer than
    /// the tail. The last good reading (if any) is still what is shown; this
    /// is what `--list` prints so the silence is not mistaken for health.
    /// No rollout at all is **not** a failure — Codex may never have run.
    public private(set) var lastReadFailed = false
    /// Files opened so far. Only `reload()` moves it; a test holds
    /// `currentSignals()` to that.
    public private(set) var reads = 0

    /// Rooted at `home`, with no default: a caller that has no home reads
    /// nothing, so a test never falls through to the real `~/.codex`.
    public init(home: URL) {
        directory = Self.sessionsDirectory(home: home)
    }

    public static func sessionsDirectory(home: URL) -> URL {
        home.appendingPathComponent(".codex/sessions")
    }

    public func currentSignals() -> [Signal] { reading }

    public func reload() {
        // The newest by mtime across **every** day directory: a long session
        // keeps writing into the directory of the day it started.
        guard let newest = Self.newestRollout(in: directory) else {
            lastReadFailed = false
            return
        }
        reads += 1
        guard let tail = Self.tail(of: newest), let found = Self.lastReading(in: tail) else {
            // No fallback to an older file: its reading would pass for a new one.
            lastReadFailed = true
            return
        }
        lastReadFailed = false
        reading = found
    }

    // MARK: - Finding the file

    private static func newestRollout(in directory: URL) -> URL? {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles])) ?? []
        }
        var best: (url: URL, modified: Date)?
        // Exactly `YYYY/MM/DD/rollout-*.jsonl`; anything elsewhere is not a
        // session log this reader understands.
        for year in children(directory) {
            for month in children(year) {
                for day in children(month) {
                    for file in children(day) where
                        file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        guard let modified = values?.contentModificationDate else { continue }
                        if best == nil || modified > best!.modified { best = (file, modified) }
                    }
                }
            }
        }
        return best?.url
    }

    /// The complete lines in the last `tailBytes` of the file. The first
    /// segment is dropped unless the tail starts at a line boundary: a cut
    /// line is never parsed, whether or not it would happen to parse.
    private static func tail(of file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        // One byte earlier than the window, to see whether it starts on a
        // line boundary.
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) - 1 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        guard start > 0 else { return data }
        // `Data` indices stay absolute in a slice (`AGENTS.md` → Pitfalls):
        // `startIndex`/`index(after:)`, never offsets from zero.
        guard let newline = data.firstIndex(of: 0x0A) else { return Data() }
        return data[data.index(after: newline)...]
    }

    // MARK: - Reading the lines

    private static let marker = Data("rate_limits".utf8)

    /// The last line, from the end, that carries a `rate_limits` object with
    /// at least one usable window and a readable stamp; its windows as signals.
    static func lastReading(in tail: Data) -> [Signal]? {
        for line in tail.split(separator: 0x0A).reversed() {
            // Most of the tail is conversation; only the lines that can
            // matter are parsed.
            guard line.range(of: marker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any],
                  let stamp = (object["timestamp"] as? String).flatMap(date(fromISO:)) else { continue }
            // A line whose windows are all null (`limit_id: premium` today)
            // or all malformed says nothing: the one before it still speaks.
            let windows = ["primary", "secondary"].compactMap { window(limits[$0]) }
            guard !windows.isEmpty else { continue }
            return windows.map { signal(for: $0, observed: stamp) }
        }
        return nil
    }

    private struct Window {
        let usedPercent: Double
        let minutes: Int
        let resetsAt: Date
    }

    private static func window(_ value: Any?) -> Window? {
        guard let fields = value as? [String: Any],
              let used = number(fields["used_percent"]),
              let minutes = number(fields["window_minutes"]),
              let resets = number(fields["resets_at"]),
              minutes > 0, minutes == minutes.rounded(), minutes <= Double(Int32.max) else { return nil }
        return Window(usedPercent: used, minutes: Int(minutes),
                      resetsAt: Date(timeIntervalSince1970: resets))
    }

    /// A JSON number and nothing else. `JSONSerialization` hands booleans
    /// back as `NSNumber` too, and `as? Double` would take `true` for 1.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func signal(for window: Window, observed: Date) -> Signal {
        Signal(provider: id, entity: "usage:\(id):\(window.minutes)", kind: .usage,
               phase: .idle, progress: window.usedPercent / 100, label: group,
               fidelity: .derived, updatedAt: observed,
               usage: Signal.Usage(group: group, windowMinutes: window.minutes,
                                   resetsAt: window.resetsAt))
    }

    // The line's stamp is ISO 8601 with fractional seconds; one without them
    // is still a stamp. A formatter set for fractions rejects the plain form,
    // so both are tried. Built once: they are expensive to make.
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    private static func date(fromISO text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }
}
