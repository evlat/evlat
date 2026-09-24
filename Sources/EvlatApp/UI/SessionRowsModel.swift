import Foundation
import EvlatCore

/// One indicator's worth of a session: what is drawn, and nothing else.
///
/// There is no stamp here on purpose. A hook row's stamp moves on every
/// `PostToolUse`; carried into this type it would make two identical rows
/// compare unequal and the deadband in `SessionRowsModel.update` would let the
/// whole burst through. `enteredAt` is not that stamp: it moves only when the
/// phase does, which writes the row anyway.
public struct SessionRow: Equatable, Identifiable {
    public let entity: String
    public let label: String
    public let phase: Phase
    /// The tool the session runs in; its mark is drawn inside the ring.
    public let source: AgentSource?
    /// 0, or this row's number among rows with the same name in the same tool
    /// (2, 3, …). The first of them keeps the bare name.
    public let duplicate: Int
    /// When the column saw this row enter its phase; `nil` when it was first
    /// seen already in it — how long is not known, and the status line says
    /// no duration rather than invent one. The model's own clock, never the
    /// signal's stamp: that one moves on every tool event.
    public let enteredAt: Date?
    /// What a waiting row waits for: the status line's two words. The only
    /// piece of `Signal.activity` a row carries — the rest (last tool, count,
    /// reply) moves on every tool event and belongs to the card, so a busy
    /// session's burst never rewrites the column.
    public let waitKind: Signal.Activity.WaitKind?
    /// `Signal.isLive`: false for a remote row nobody can currently hear.
    /// Such a row is listed but does not beat, and sorts under the live ones.
    public let isLive: Bool

    public var id: String { entity }

    public init(entity: String, label: String, phase: Phase,
                source: AgentSource? = nil, duplicate: Int = 0,
                enteredAt: Date? = nil, waitKind: Signal.Activity.WaitKind? = nil,
                isLive: Bool = true) {
        self.entity = entity
        self.isLive = isLive
        self.label = label
        self.phase = phase
        self.source = source
        self.duplicate = duplicate
        self.enteredAt = enteredAt
        // Only a waiting row has something to wait for. `reconcile` already
        // keeps the block on waiting rows alone; this keeps the row honest if
        // that ever loosens.
        self.waitKind = phase == .waiting ? waitKind : nil
    }

    public init(_ signal: Signal, duplicate: Int = 0, enteredAt: Date? = nil) {
        self.init(entity: signal.entity, label: signal.label, phase: signal.phase,
                  source: signal.source, duplicate: duplicate,
                  enteredAt: enteredAt, waitKind: signal.activity?.waitKind,
                  isLive: signal.isLive)
    }

    /// Whether this row moves on the beat. `working` turns its arc, `waiting`
    /// pulses; the rest are still (`review`'s fade is a one-off on arrival).
    /// A dimmed row never beats: its phase is the last thing a silent
    /// machine said, and a clock kept running for it would spend the idle
    /// budget on nobody.
    public var beats: Bool {
        guard isLive else { return false }
        switch phase {
        case .working, .waiting: return true
        case .idle, .review, .failed: return false
        }
    }
}

/// The session column's own model, apart from `MascotModel`.
///
/// Apart because the two change at very different rates: the mascot's gaze is
/// written as the cursor moves, and a column that observed the mascot would be
/// re-evaluated at that rate for nothing. Each view observes the model it
/// draws.
///
/// **It also owns the beat clock, alone.** Indicators are not animated
/// continuously — any continuous SwiftUI animation costs ~7% on this machine
/// (`proje.md` → Tuzaklar) — they make one gesture per beat and are still in
/// between, the same argument `003` made for the mascot's clips.
@MainActor
public final class SessionRowsModel: ObservableObject {
    /// Slots under the mascot on the **closed** bar at most. Its length
    /// follows the slots in use (`AppController.barLength`); past this the
    /// last slot becomes a count. The open list has no such cap (`006`).
    public static let slotCount = 4

    /// Seconds between beats. Near the clips' own tempo (a `working` clip
    /// changes pose every 0.5–2.3 s); the measured cost is in `004/phase-2`'s
    /// notes.
    public static let beatInterval: TimeInterval = 3.0

    /// Every live session, in the column's order: the open list draws all
    /// of them, the closed bar a prefix (`closedRows`).
    @Published public private(set) var rows: [SessionRow] = []
    /// The beat counter. Indicators hang their gesture on a **change** of this
    /// value (`keyframeAnimator(trigger:)`), so it only ever counts up.
    @Published public private(set) var beat: Int = 0

    private var clock: Timer?
    /// When each row entered its current phase, as a count of observed phase
    /// changes — no clock needed, only an order. A row first seen gets 0.
    private var entered: [String: Int] = [:]
    private var lastPhase: [String: Phase] = [:]
    private var changes = 0
    /// When each row entered its phase, by the clock — only for rows seen
    /// changing. The ordering above needs no clock; the status line does.
    private var enteredAt: [String: Date] = [:]
    private let now: () -> Date
    /// How many times a clock has been started. For the rhythm test: a list
    /// write that restarted the clock would push the next beat out every time
    /// a busy session writes — and a busy session writes constantly
    /// (`AGENTS.md` → Tuzaklar, the rhythm trap).
    private(set) var clockStarts = 0

    /// `now` is injected so the tests can move time by hand.
    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    deinit { clock?.invalidate() }

    public var isBeating: Bool { clock != nil }

    /// Whether the open list is drawn, handed in by `AppController`. Not
    /// published: nothing observes it; it only tells the clock which rows are
    /// drawn.
    public private(set) var isOpen = false

    /// The closed bar's rings: the slot rule over the whole list.
    public var closedRows: [SessionRow] { Self.slots(rows).rows }
    /// How many live sessions have no slot on the closed bar. Zero means no
    /// overflow slot.
    public var overflow: Int { Self.slots(rows).overflow }

    /// Rings drawn on the closed bar plus the count's slot, if there is one:
    /// what the closed bar's length is fitted to.
    public var slotsInUse: Int { closedRows.count + (overflow > 0 ? 1 : 0) }

    /// The rows in the view tree: the whole list open, the prefix closed.
    private var drawnRows: [SessionRow] { isOpen ? rows : closedRows }

    /// The clock follows the drawn rows, so opening can start it and closing
    /// stop it: a working row hidden in the count beats for no one.
    public func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        setBeating(drawnRows.contains(where: \.beats))
    }

    /// ≤ `slotCount` rows: all of them. More: the first `slotCount - 1` and a
    /// count of the rest, so the overflow takes the last slot and the bar
    /// never grows past `slotCount` slots.
    nonisolated public static func slots(_ all: [SessionRow])
        -> (rows: [SessionRow], overflow: Int) {
        guard all.count > slotCount else { return (all, 0) }
        let shown = Array(all.prefix(slotCount - 1))
        return (shown, all.count - shown.count)
    }

    /// Numbers for rows that share a name **and** a tool — two Codex sessions
    /// in one folder are both called after it. The same name in two tools
    /// needs none: the mark in the ring tells them apart. Counted over every
    /// live row, not the visible ones, and in entity order, so a number does
    /// not change when the rows reorder or scroll into the count.
    nonisolated static func duplicateNumbers(_ signals: [Signal]) -> [String: Int] {
        var groups: [String: [String]] = [:]
        for signal in signals {
            groups["\(signal.source?.rawValue ?? "-")/\(signal.label)", default: []].append(signal.entity)
        }
        var numbers: [String: Int] = [:]
        for entities in groups.values where entities.count > 1 {
            for (index, entity) in entities.sorted().enumerated() where index > 0 {
                numbers[entity] = index + 1
            }
        }
        return numbers
    }

    /// Writes what is drawn, and only when it changed.
    ///
    /// Compared field by field, the same deadband `AppController.refresh`
    /// keeps for the mascot: a moving stamp never reaches `@Published`. The
    /// whole list is compared, so a phase change on a row the closed bar
    /// counts but does not draw is written too — on purpose: the open list
    /// draws it.
    ///
    /// **The order within a phase is the order rows entered it, newest
    /// first.** The session that just finished leads the idle rows instead of
    /// dropping back to its place by entity. The key moves only on a phase
    /// change, never on the stamp a busy session refreshes with every tool
    /// event, so the column stays still between changes; ties (rows never
    /// seen changing) fall back to the entity.
    ///
    /// **Live rows come first**, the same first key `Registry.Snapshot`
    /// sorts by; without it this re-sort would mix dimmed rows back in among
    /// the live ones.
    public func update(from signals: [Signal]) {
        for signal in signals where lastPhase[signal.entity] != signal.phase {
            if lastPhase[signal.entity] == nil {
                entered[signal.entity] = 0
            } else {
                changes += 1
                entered[signal.entity] = changes
                enteredAt[signal.entity] = now()
            }
            lastPhase[signal.entity] = signal.phase
        }
        let live = Set(signals.map(\.entity))
        lastPhase = lastPhase.filter { live.contains($0.key) }
        entered = entered.filter { live.contains($0.key) }
        enteredAt = enteredAt.filter { live.contains($0.key) }

        let ordered = signals.sorted { a, b in
            if a.isLive != b.isLive { return a.isLive }
            if a.phase.priority != b.phase.priority { return a.phase.priority > b.phase.priority }
            let ea = entered[a.entity] ?? 0, eb = entered[b.entity] ?? 0
            return ea != eb ? ea > eb : a.entity < b.entity
        }
        let numbers = Self.duplicateNumbers(signals)
        let next = ordered.map {
            SessionRow($0, duplicate: numbers[$0.entity] ?? 0, enteredAt: enteredAt[$0.entity])
        }
        if rows != next { rows = next }
        setBeating(drawnRows.contains(where: \.beats))
    }

    /// The clock follows one Bool and nothing else. A change in the list that
    /// leaves the Bool where it was does not touch the clock, so the rhythm
    /// runs on through every write.
    private func setBeating(_ wanted: Bool) {
        guard wanted != isBeating else { return }
        guard wanted else {
            clock?.invalidate()
            clock = nil
            return
        }
        let timer = Timer(timeInterval: Self.beatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat &+= 1 }  // Timer callback is nonisolated
        }
        // The beat is peripheral; letting the system coalesce it with other
        // wakeups costs nothing anyone can see.
        timer.tolerance = Self.beatInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
        clockStarts += 1
    }
}
