import Foundation

/// Claude Code's rate-limit windows, as its status line reports them through
/// `POST /usage/claude`.
///
/// `Fidelity` is `.official`: the fields are Claude Code's documented status
/// line input, unlike Codex's rollout file. Held in memory only — nothing is
/// written to disk, so a restart shows no Claude group until the status line
/// next runs.
///
/// **Windows merge one by one.** A report updates the windows it carries and
/// leaves the others: Claude Code sends each window only when it has it, so a
/// missing one means "not said", not "gone". An empty report erases nothing. A
/// window that stopped coming is dropped once it is past its own reset —
/// Claude Code releases an expired window, so nothing will ever replace it.
///
/// **Not thread-safe, by design.** Reports are delivered on the main queue and
/// `currentSignals()` is called there too (`Provider`'s contract).
public final class ClaudeUsageProvider: Provider {
    /// The local instance's id and group; a machine's instance derives its
    /// own from them.
    public static let id = "claude-usage"
    /// The name the windows are grouped under on the bar. A proper name, not
    /// catalogue text (`Signal.Usage.group`).
    public static let group = "Claude"

    /// `claude-usage`, or `claude-usage@{machine id}` for a remote machine's
    /// status line: its own entities, so a remote window never overwrites
    /// the local one even when both are the same account.
    public let id: String
    /// `Claude`, or `Claude · {machine name}`.
    public let group: String
    private let machine: Signal.Machine.Identity?

    private struct Stored {
        let window: UsageReport.Window
        let observed: Date
    }

    private let now: () -> Date
    private var windows: [Int: Stored] = [:]
    /// Every key under `rate_limits` this process has seen and not drawn.
    public private(set) var unrecognizedWindows: Set<String> = []

    /// The clock is injected (`HooksProvider`'s pattern): the observation
    /// stamp is the provider's, since `LocalAPI` has no clock.
    public init(now: @escaping () -> Date, machine: Signal.Machine.Identity? = nil) {
        self.now = now
        self.machine = machine
        id = machine.map { "\(Self.id)@\($0.id)" } ?? Self.id
        group = machine.map { "\(Self.group) · \($0.name)" } ?? Self.group
    }

    public func handle(_ report: UsageReport) {
        let seen = now()
        let reported = Set(report.windows.map(\.minutes))
        // Only when the window did not come again: one that did is replaced
        // below, whatever its reset says.
        windows = windows.filter { reported.contains($0.key) || $0.value.window.resetsAt > seen }
        for window in report.windows {
            windows[window.minutes] = Stored(window: window, observed: seen)
        }
        unrecognizedWindows.formUnion(report.unrecognizedWindows)
    }

    /// From memory, never pruned here: a window past its reset may stay a
    /// signal until the next report, and the bar does not draw it
    /// (`UsageBlockModel`).
    public func currentSignals() -> [Signal] {
        windows.keys.sorted().compactMap { minutes in
            windows[minutes].map { stored in
                Signal(provider: id, entity: "usage:\(id):\(minutes)", kind: .usage,
                       phase: .idle, progress: stored.window.usedPercent / 100, label: group,
                       fidelity: .official, updatedAt: stored.observed,
                       usage: Signal.Usage(group: group, windowMinutes: minutes,
                                           resetsAt: stored.window.resetsAt),
                       // Dimming is not this provider's to know and no
                       // rule reads it on a usage row (`Snapshot` splits them
                       // out first); staleness is read from `updatedAt`. The
                       // machine is here for the group order and the name.
                       machine: machine.map { Signal.Machine(name: $0.name) })
            }
        }
    }
}
