import Foundation
import EvlatCore

/// One indicator's worth of a session: what is drawn, and nothing else.
///
/// There is no stamp here on purpose. A hook row's stamp moves on every
/// `PostToolUse`; carried into this type it would make two identical rows
/// compare unequal and the deadband in `SessionRowsModel.update` would let the
/// whole burst through.
public struct SessionRow: Equatable, Identifiable {
    public let entity: String
    public let label: String
    public let phase: Phase

    public var id: String { entity }

    public init(entity: String, label: String, phase: Phase) {
        self.entity = entity
        self.label = label
        self.phase = phase
    }

    public init(_ signal: Signal) {
        self.init(entity: signal.entity, label: signal.label, phase: signal.phase)
    }

    /// Whether this row moves on the beat. `working` turns its arc, `waiting`
    /// pulses; the rest are still (`review`'s fade is a one-off on arrival).
    public var beats: Bool {
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
    /// Slots under the mascot at most. The bar's length follows the slots in
    /// use (`AppController.barLength`); past this the last slot becomes a count.
    public static let slotCount = 4

    /// Seconds between beats. Near the clips' own tempo (a `working` clip
    /// changes pose every 0.5–2.3 s); the measured cost is in `004/phase-2`'s
    /// notes.
    public static let beatInterval: TimeInterval = 3.0

    @Published public private(set) var rows: [SessionRow] = []
    /// How many live sessions have no slot. Zero means no overflow slot.
    @Published public private(set) var overflow: Int = 0
    /// The beat counter. Indicators hang their gesture on a **change** of this
    /// value (`keyframeAnimator(trigger:)`), so it only ever counts up.
    @Published public private(set) var beat: Int = 0

    private var clock: Timer?
    /// When each row entered its current phase, as a count of observed phase
    /// changes — no clock needed, only an order. A row first seen gets 0.
    private var entered: [String: Int] = [:]
    private var lastPhase: [String: Phase] = [:]
    private var changes = 0
    /// How many times a clock has been started. For the rhythm test: a list
    /// write that restarted the clock would push the next beat out every time
    /// a busy session writes — and a busy session writes constantly
    /// (`AGENTS.md` → Tuzaklar, the rhythm trap).
    private(set) var clockStarts = 0

    public init() {}

    deinit { clock?.invalidate() }

    public var isBeating: Bool { clock != nil }

    /// Rings drawn plus the count's slot, if there is one: what the bar's
    /// length is fitted to.
    public var slotsInUse: Int { rows.count + (overflow > 0 ? 1 : 0) }

    /// ≤ `slotCount` rows: all of them. More: the first `slotCount - 1` and a
    /// count of the rest, so the overflow takes the last slot and the bar
    /// never grows past `slotCount` slots.
    nonisolated public static func slots(_ all: [SessionRow])
        -> (rows: [SessionRow], overflow: Int) {
        guard all.count > slotCount else { return (all, 0) }
        let shown = Array(all.prefix(slotCount - 1))
        return (shown, all.count - shown.count)
    }

    /// Writes what is drawn, and only when it changed.
    ///
    /// Compared field by field, the same deadband `AppController.refresh`
    /// keeps for the mascot: a moving stamp never reaches `@Published`.
    ///
    /// **The order within a phase is the order rows entered it, newest
    /// first.** The session that just finished leads the idle rows instead of
    /// dropping back to its place by entity. The key moves only on a phase
    /// change, never on the stamp a busy session refreshes with every tool
    /// event, so the column stays still between changes; ties (rows never
    /// seen changing) fall back to the entity.
    public func update(from signals: [Signal]) {
        for signal in signals where lastPhase[signal.entity] != signal.phase {
            if lastPhase[signal.entity] == nil {
                entered[signal.entity] = 0
            } else {
                changes += 1
                entered[signal.entity] = changes
            }
            lastPhase[signal.entity] = signal.phase
        }
        let live = Set(signals.map(\.entity))
        lastPhase = lastPhase.filter { live.contains($0.key) }
        entered = entered.filter { live.contains($0.key) }

        let ordered = signals.sorted { a, b in
            if a.phase.priority != b.phase.priority { return a.phase.priority > b.phase.priority }
            let ea = entered[a.entity] ?? 0, eb = entered[b.entity] ?? 0
            return ea != eb ? ea > eb : a.entity < b.entity
        }
        let next = Self.slots(ordered.map(SessionRow.init))
        if rows != next.rows { rows = next.rows }
        if overflow != next.overflow { overflow = next.overflow }
        setBeating(next.rows.contains(where: \.beats))
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
