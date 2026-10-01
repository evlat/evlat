import Foundation
import EvlatCore

/// What a row of each kind can do, from one exhaustive `switch` on
/// `Signal.Kind`: a new kind does not compile until it has a line here, and
/// no view branches on the kind itself. Read from the kind, never from the
/// provider's name.
struct RowTraits: Equatable {
    /// What sits inside the ring.
    enum Mark: Equatable { case tool, face, none }
    /// Whose name the small caps beside the row's say.
    enum Tag: Equatable {
        case machine, evlat, sender

        /// The small caps as drawn — **the one rule**: the row's tag, the
        /// card's header and the duplicate numbers' groups all read it.
        ///
        /// An outside job's tag answers "where" first: a remote one
        /// is tagged with its machine, since what it is already reads in its
        /// label; the card, with room for both, says the sender and then the
        /// machine. A name, never catalogue text.
        func text(machine: String?, sender: String?, inCard: Bool = false) -> String? {
            switch self {
            case .machine: return machine
            // The card has the mascot's face for "Evlat" and no machine to
            // add: the row's tag only.
            case .evlat: return inCard ? machine : SessionRow.jobTag
            case .sender:
                guard inCard, let machine, let sender else { return machine ?? sender }
                return "\(sender) · \(machine)"
            }
        }
    }
    /// The card's one button.
    enum Button: Equatable { case goToSession, backToChat, none }
    /// What `Signal.detail` is to the card: a chat's folder (the footer), an
    /// outside job's own line (the body), or a source's diagnostic, not drawn.
    enum Detail: Equatable { case folder, note, none }

    let mark: Mark
    let tag: Tag
    /// `.goToSession` holds on this Mac only: a remote session's terminal is
    /// on another computer (`SessionRow.hasTerminal`).
    let button: Button
    let detail: Detail
    /// Whether the signal's stamp is the moment its phase began, so the
    /// row's time is known even when first seen already in it. A session's
    /// stamp moves on every tool event and is not.
    let stampIsPhaseStart: Bool
    /// Whether `Signal.progress` is drawn: the sender's own claim of how far
    /// it is. A usage window's progress is its own block's.
    let showsProgress: Bool
    /// Whether a seen finish reads `idle`. A session goes on after its turn,
    /// so once seen it is idle again; an outside job or a chat turn has
    /// nothing after its end and keeps its word ("done", "failed").
    let passiveReadsIdle: Bool

    static func of(_ kind: Signal.Kind) -> RowTraits {
        switch kind {
        case .session:
            return RowTraits(mark: .tool, tag: .machine, button: .goToSession, detail: .none,
                             stampIsPhaseStart: false, showsProgress: false, passiveReadsIdle: true)
        case .job:
            // Evlat's own chat: the mascot's face, the "EVLAT" tag,
            // `[Back to chat]`; its stamp is the chat's phase start.
            return RowTraits(mark: .face, tag: .evlat, button: .backToChat, detail: .folder,
                             stampIsPhaseStart: true, showsProgress: false, passiveReadsIdle: false)
        case .custom:
            // A program outside: no tool, no terminal, nothing to go
            // back to — the ring speaks the phase alone and its sender's name
            // is the tag. `SignalsProvider` keeps the stamp while the phase holds.
            return RowTraits(mark: .none, tag: .sender, button: .none, detail: .note,
                             stampIsPhaseStart: true, showsProgress: true, passiveReadsIdle: false)
        case .usage:
            // Never in the column (`Registry.Snapshot` splits it off); the
            // line is here so the switch stays exhaustive.
            return RowTraits(mark: .none, tag: .machine, button: .none, detail: .none,
                             stampIsPhaseStart: false, showsProgress: false, passiveReadsIdle: true)
        }
    }
}

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
    /// on the same machine (2, 3, …). The first of them keeps the bare name.
    public let duplicate: Int
    /// The git branch drawn after the name, when it is what tells this row
    /// from another of the same name (`SessionRowsModel.names`); `nil`
    /// otherwise, which is most rows.
    public let branch: String?
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
    /// The remote computer's name, drawn small beside the row's; `nil` on
    /// this Mac. A proper name, not catalogue text.
    public let machine: String?
    /// Why a remote row cannot be heard and since when (`Signal.Machine.Dim`);
    /// `nil` while it can, and always on this Mac. Its moment is frozen while
    /// the row is dimmed, so it passes the deadband without writing.
    public let dim: Signal.Machine.Dim?
    /// What the row is; what that lets it do is `traits`.
    public let kind: Signal.Kind
    /// How far an outside job says it is, in whole percents (0…100); `nil`
    /// when it says nothing or its kind draws none. Whole on purpose: this is
    /// the deadband — a sender stepping by 0.001 would otherwise rewrite the
    /// column at its own rate, and 1% of the ring is ~0.6 pt anyway.
    public let progress: Int?
    /// The outside program's own name for itself (`Signal.sender`): drawn as
    /// the tag, never branched on.
    public let sender: String?
    /// The snapshot's layer is `passive` (`Registry.Layer`): a finish already
    /// seen, or a row with nothing to say. Drawn as a grey ring, still — a
    /// look, not an opacity: dimness is `dim`'s, and a row can be both.
    public let passive: Bool
    /// How a passive row ended, for the small dot inside its grey ring when
    /// it has no mark to draw (an outside job): `review` or `failed`; `nil`
    /// on an active row and on one that is just idle. A passive session's `phase` is `idle` — that is what it is now —
    /// so this is the only place its last finish is still read.
    public let outcome: Phase?

    var traits: RowTraits { .of(kind) }

    /// The small caps beside the name: the machine's for a remote row,
    /// "EVLAT" for a chat, the sender's for an outside job on this Mac and
    /// the machine's for one elsewhere (`RowTraits.Tag.text`).
    public var tag: String? { traits.tag.text(machine: machine, sender: sender) }
    public static let jobTag = "Evlat"

    /// Only a session on this Mac has a terminal to look up and go to.
    public var hasTerminal: Bool { traits.button == .goToSession && machine == nil }

    /// `Signal.isLive`: false for a remote row nobody can currently hear.
    /// Such a row is listed but does not beat, and sorts under the live ones.
    public var isLive: Bool { dim == nil }

    public var id: String { entity }

    public init(entity: String, label: String, phase: Phase,
                source: AgentSource? = nil, duplicate: Int = 0, branch: String? = nil,
                enteredAt: Date? = nil, waitKind: Signal.Activity.WaitKind? = nil,
                machine: String? = nil, dim: Signal.Machine.Dim? = nil, kind: Signal.Kind = .session,
                progress: Int? = nil, sender: String? = nil, passive: Bool = false) {
        self.entity = entity
        let finished = phase == .review || phase == .failed
        self.passive = passive
        self.outcome = passive && finished ? phase : nil
        // What the row says now: a seen session is idle again; an outside
        // job or a chat turn keeps its last word (`RowTraits.passiveReadsIdle`).
        let phase = passive && finished && RowTraits.of(kind).passiveReadsIdle ? .idle : phase
        self.kind = kind
        self.progress = RowTraits.of(kind).showsProgress ? progress.map { min(100, max(0, $0)) } : nil
        self.sender = sender
        self.label = label
        self.phase = phase
        self.source = source
        self.duplicate = duplicate
        self.branch = branch
        self.enteredAt = enteredAt
        // Only a waiting row has something to wait for. `reconcile` already
        // keeps the block on waiting rows alone; this keeps the row honest if
        // that ever loosens.
        self.waitKind = phase == .waiting ? waitKind : nil
        self.machine = machine
        self.dim = dim
    }

    public init(_ signal: Signal, duplicate: Int = 0, branch: String? = nil,
                enteredAt: Date? = nil, passive: Bool = false) {
        self.init(entity: signal.entity, label: signal.label, phase: signal.phase,
                  source: signal.source, duplicate: duplicate, branch: branch,
                  enteredAt: enteredAt, waitKind: signal.activity?.waitKind,
                  machine: signal.machine?.name, dim: signal.machine?.dim, kind: signal.kind,
                  progress: signal.progress.flatMap(Self.percent), sender: signal.sender,
                  passive: passive)
    }

    /// 0…1 to whole percents. `SignalReport` already holds the value to a
    /// finite 0…1; anything else is dropped rather than trapped on.
    static func percent(_ fraction: Double) -> Int? {
        let value = (fraction * 100).rounded()
        guard value.isFinite else { return nil }
        return Int(min(100, max(0, value)))
    }

    /// Whether this row moves on the beat. `working` turns its arc, `waiting`
    /// pulses; the rest are still (`review`'s fade is a one-off on arrival).
    /// A working row with a known progress does not turn: the filling arc is
    /// its movement, and a turning ring says "how far is not known".
    /// A dimmed row never beats: its phase is the last thing a silent
    /// machine said, and a clock kept running for it would spend the idle
    /// budget on nobody.
    /// A passive row never beats either: it has already been heard.
    public var beats: Bool {
        guard isLive, !passive else { return false }
        switch phase {
        case .working: return progress == nil
        case .waiting: return true
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
/// (`AGENTS.md` → Pitfalls) — they make one gesture per beat and are still
/// in between, the same argument the mascot's clips make.
@MainActor
public final class SessionRowsModel: ObservableObject {
    /// Slots under the mascot on the **closed** bar at most. Its length
    /// follows the slots in use (`AppController.barLength`); past this the
    /// last slot becomes a count. The open list has no such cap.
    public static let slotCount = 4

    /// Seconds between beats. Near the clips' own tempo (a `working` clip
    /// changes pose every 0.5–2.3 s); its cost was measured at this value.
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
    /// (`AGENTS.md` → Pitfalls, the rhythm trap).
    private(set) var clockStarts = 0

    /// Reads a folder's branch (`GitHead.branch`); injected so the tests
    /// need no repository. The default reads nothing.
    private let readBranch: (String) -> String?
    /// Branches read so far, by folder, `nil` included: a folder is read once,
    /// then again only after `forgetBranches()`. Pruned with the rows.
    private var branches: [String: String?] = [:]

    /// `now` is injected so the tests can move time by hand.
    public init(now: @escaping () -> Date = Date.init,
                readBranch: @escaping (String) -> String? = { _ in nil }) {
        self.now = now
        self.readBranch = readBranch
    }

    /// Drops every branch read, so the next `update` reads them again. The
    /// shell calls it as the bar opens, before the scan that sizes the body:
    /// a `git checkout` made while the bar was closed is drawn on this
    /// opening, and the width is right from the first frame.
    public func forgetBranches() {
        branches.removeAll()
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

    /// Numbers for rows that share a name, a tool **and** the drawn tag —
    /// two Codex sessions in one folder are both called after it. The same
    /// name in two tools needs none: the mark in the ring tells them apart;
    /// nor on two computers, nor from two senders on this Mac: the tag beside
    /// it does. Two senders on one machine share its tag and are numbered.
    /// Counted over every live row, not the visible ones, and in entity
    /// order, so a number does not change when the rows reorder or
    /// scroll into the count.
    nonisolated static func duplicateNumbers(_ signals: [Signal]) -> [String: Int] {
        names(signals, branch: { _ in nil }).mapValues(\.number).filter { $0.value > 0 }
    }

    /// What tells same-named rows apart: a branch where they are on
    /// different ones, a number where nothing else does.
    ///
    /// **A branch is drawn only inside a group of the same name** (tool and
    /// tag, as for the numbers), and only when the group holds more than one
    /// branch — "no branch" counting as one. A row alone under its name stays
    /// bare, as it does today: most people run one session per repository and
    /// would read a branch on every row as noise. Two sessions in one
    /// worktree say the same branch, which tells them apart no better than
    /// the name, so they are numbered instead.
    ///
    /// The numbers then run within (name, drawn branch): `shop-api ⑂ feat`
    /// twice is `shop-api` and `shop-api²`, both with the branch.
    ///
    /// `branch` is asked only for the rows of a group of two or more, so a
    /// column of distinct names touches no file.
    nonisolated static func names(_ signals: [Signal], branch: (Signal) -> String?)
        -> [String: (number: Int, branch: String?)] {
        // A struct, not a joined string: a sender may hold any separator.
        struct Group: Hashable {
            let tag: String?, source: AgentSource?, label: String
        }
        var groups: [Group: [Signal]] = [:]
        for signal in signals {
            let tag = RowTraits.of(signal.kind).tag.text(machine: signal.machine?.name, sender: signal.sender)
            let key = Group(tag: tag, source: signal.source, label: signal.label)
            groups[key, default: []].append(signal)
        }
        var result: [String: (number: Int, branch: String?)] = [:]
        for members in groups.values where members.count > 1 {
            let read = Dictionary(uniqueKeysWithValues: members.map { ($0.entity, branch($0)) })
            let drawn = Set(read.values).count > 1
            var byBranch: [String?: [String]] = [:]
            for member in members {
                byBranch[drawn ? read[member.entity] ?? nil : nil, default: []].append(member.entity)
            }
            for (shown, entities) in byBranch {
                for (index, entity) in entities.sorted().enumerated() {
                    result[entity] = (entities.count > 1 && index > 0 ? index + 1 : 0, shown)
                }
            }
        }
        return result
    }

    /// The branch of a row, read through the cache. Only a session on this
    /// Mac has a folder here to read: a remote row's folder is on its server.
    private func branch(of signal: Signal) -> String? {
        guard signal.kind == .session, signal.machine == nil,
              let folder = signal.detail, folder.hasPrefix("/") else { return nil }
        if let known = branches[folder] { return known }
        let read = readBranch(folder)
        branches[folder] = read
        return read
    }

    /// Writes what is drawn, and only when it changed.
    ///
    /// Compared field by field, the same deadband `AppController.refresh`
    /// keeps for the mascot: a moving stamp never reaches `@Published`. The
    /// whole list is compared, so a phase change on a row the closed bar
    /// counts but does not draw is written too — on purpose: the open list
    /// draws it.
    ///
    /// **The layers are the snapshot's** (`Registry.Layer`): waiting,
    /// working, news, passive, read from `snapshot.layers` and never worked
    /// out again here — a second copy of the rule is the one the tests would
    /// not cover. News is ordered by its finish, newest first, the same key
    /// the snapshot uses.
    ///
    /// **Within any other layer the order is the order rows entered their
    /// phase, newest first.** The session that just went idle leads the
    /// passive rows instead of dropping back to its place by entity. The key
    /// moves only on a phase change, never on the stamp a busy session
    /// refreshes with every tool event, so the column stays still between
    /// changes; ties (rows never seen changing) fall back to the entity.
    ///
    /// **Live rows come first**, the same first key `Registry.Snapshot`
    /// sorts by; without it this re-sort would mix dimmed rows back in among
    /// the live ones.
    public func update(from snapshot: Registry.Snapshot) {
        let signals = snapshot.ordered
        let layers = snapshot.layers
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
            let la = layers[a.entity] ?? .passive, lb = layers[b.entity] ?? .passive
            if la != lb { return la < lb }
            if la == .news, a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            let ea = entered[a.entity] ?? 0, eb = entered[b.entity] ?? 0
            return ea != eb ? ea > eb : a.entity < b.entity
        }
        let names = Self.names(signals, branch: branch(of:))
        let folders = Set(signals.compactMap(\.detail))
        branches = branches.filter { folders.contains($0.key) }
        let next = ordered.map {
            // A chat's or an outside job's stamp is the moment its phase
            // began (`ChatSession`, `SignalsProvider`), never moved by a tool
            // event: its time is known even for a row first seen already in
            // it — one read back at launch.
            SessionRow($0, duplicate: names[$0.entity]?.number ?? 0,
                       branch: names[$0.entity]?.branch,
                       enteredAt: enteredAt[$0.entity]
                           ?? (RowTraits.of($0.kind).stampIsPhaseStart ? $0.updatedAt : nil),
                       passive: layers[$0.entity] == .passive)
        }
        if rows != next { rows = next }
        setBeating(drawnRows.contains(where: \.beats))
    }

    /// The same, for a caller holding rows rather than a snapshot: the
    /// layers still come from `Registry.Snapshot`, with nothing seen.
    public func update(from signals: [Signal]) {
        update(from: Registry.Snapshot(signals: signals))
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
