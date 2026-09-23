import AppKit
import SwiftUI
import EvlatCore

/// All application wiring in one place. `main.swift` only calls into this, so
/// everything here stays testable (an executable target's top-level code cannot
/// be run from a test bundle).
///
/// Marked `@MainActor`: it is the application delegate, so every callback
/// already arrives on the main queue, and the model it drives is main-actor
/// isolated. Saying so once removes the need to assert it at each call site.
/// The pure statics below stay `nonisolated` — they touch no state and tests
/// call them directly.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public private(set) var panel: BarPanel?
    /// Where the edge is stored. Handed in: `.standard` is given only by
    /// `launch()`, so a test never reads or writes the user's domain. `nil`
    /// stores nothing — a controller built without it reads no edge and
    /// writes none.
    private let defaults: UserDefaults?
    /// The home the agents' settings files are found under, for the hook
    /// entries. Handed in, like `defaults`: only `launch()` resolves the real
    /// one (`resolvedHome`), so a test never reads or writes `~/.claude` or
    /// `~/.codex`. `nil` draws no hook entry and never calls the writer.
    private let home: URL?
    /// The one thing kept about the hook entries: each source's last refused
    /// write, drawn as a dim line under its entry until a write succeeds.
    /// The state itself is read from the file every time a menu is built.
    private var hookFailures: [AgentSource: HookSettings.Failure] = [:]
    public let registry = Registry()
    public let mascot = MascotModel()
    /// The indicators under the mascot. Fed from the same snapshot as the
    /// mascot in `refresh()`, observed by its own column.
    public let sessionRows = SessionRowsModel()
    /// The card's facts for the selected session. Written only while one is
    /// selected (`syncSelection`), observed by the card alone.
    public let detail = DetailModel()
    /// The usage block's lines. Fed from the same snapshot in `refresh()`,
    /// observed by the open bar's block alone.
    let usageBlock = UsageBlockModel()
    /// `phase-3`'s bucket: a counter and the last few lines. It feeds nothing
    /// into `registry` and never will — turning events into phases is the
    /// provider's job, one line below.
    ///
    /// `--capture` builds its own; this copy has no reader in-process, and
    /// giving it one needs either a read endpoint or a write under `~/`, both
    /// of which `002` rules out (R6). It is kept because the alternative is
    /// having nothing at all to hand such a reader the day it exists.
    public let hookDiagnostics = HookDiagnostics()
    /// The second provider. It holds the phase of every session that has ever
    /// spoken to this process, and it is the only place `waiting` comes from.
    public let hooks = HooksProvider(platform: AppController.darwinPlatform)
    /// Claude's usage windows, as its status line posts them. Stamped with
    /// this controller's `now`, the clock the usage block reads too, so a
    /// fixed-date test never sees a fresh report as stale.
    lazy var claudeUsage = ClaudeUsageProvider(now: { [unowned self] in
        MainActor.assumeIsolated { self.now() }
    })
    private var hookListener: HookListener?
    private var statusItem: NSStatusItem?
    private var gaze: GazeTracker?
    /// When a cursor over the bar opens it, and when leaving closes it.
    /// Internal so a test can open and close through it.
    let hover = HoverIntent()
    /// When a cursor staying on a row brings its card up, or takes the card
    /// there. A `var` so a test can hand it a scheduler before `installPanel`.
    var rowSwitch = RowSwitch()
    /// Where the cursor is now, for re-reading the row under a cursor that
    /// has not moved. A `var` so a test can hold it over a row.
    var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// The clock the usage block is read against. A `var` so a test can
    /// hold it still: its windows reset at fixed dates.
    var now: () -> Date = Date.init
    /// Whether the body is drawn open. Apart from the window's size on purpose:
    /// the window is resized when nothing on screen moves, and this is what the
    /// eye sees move (`openBar`, `closeBar`).
    let barState = BarState()
    /// How far the open list is scrolled. Apart from `barState` so a scroll
    /// re-evaluates the list and the card, not the whole body.
    let listScroll = ListScroll()
    private var poller: Timer?
    private var screenObserver: NSObjectProtocol?
    /// Is a coalesced refresh already on its way? See `scheduleRefresh`.
    private var refreshPending = false

    /// The visible bar's width. It leaves here once `003` brings the geometry
    /// abstraction; for now one constant in one place is enough.
    public static let barWidth: CGFloat = 54

    /// Transparent margin on the inner side of the window.
    ///
    /// The shape is flush with the screen edge and the window used to be exactly
    /// its bounding box, so the inner-edge drop shadow was clipped away by the
    /// window frame — the one part of the shadow that sells "growing out of the
    /// bezel" never rendered. The window is wider than the bar by this much and
    /// the shape is inset by the same amount.
    public static let shadowGutter: CGFloat = 18

    /// The widest the open bar gets: the longest name `SessionColumn` draws.
    /// The body opens only as far as the names it holds, or the summary line
    /// under them, need (`BarState.openWidth`); the window keeps room for this and the card
    /// beside it (`envelopeSize`). Opening lengthens the body too: the open
    /// list holds every session (`openLength`).
    public static let expandedBarWidth = SessionColumn.openWidth(namesWidth: SessionColumn.nameMaxWidth)

    /// The mascot sits at the head of the bar.
    public static let mascotSize: CGFloat = 34

    /// The shape's inner corner radius and the inverse curve at its ends.
    /// The flare takes `barFlare` off each end of the body: the window's top
    /// is not the body's top.
    public static let barCorner: CGFloat = 18
    public static let barFlare: CGFloat = 20
    /// Room between the body's end and what it holds, the same at both ends.
    /// Measured from the **body**, not the window: counted from the window,
    /// the flare ate 20 of 26 points and left the mascot 6 points under the
    /// body's top edge, closer than the 10 at its sides.
    public static let bodyMargin: CGFloat = 14
    /// Distance from the top of the window to the top of the mascot. Shared
    /// with the gaze anchor, which otherwise drifts whenever the layout changes.
    public static let mascotTopInset: CGFloat = barFlare + bodyMargin

    /// The session rings under the mascot. Large enough that the tool's mark
    /// inside reads: at 12 pt the two marks were only a texture, and 16 still
    /// looked too small on the live bar.
    public static let indicatorSize: CGFloat = 20
    public static let indicatorSpacing: CGFloat = 10
    /// From the mascot's bottom edge to the first ring.
    public static let indicatorTopGap: CGFloat = 18

    /// The bar's length hugs what it holds: the mascot, and under it one slot
    /// per ring (the "+N" count takes a slot of its own). The same margin
    /// closes the far end as opens the head, so an empty bar is the mascot
    /// with room around it and a full one is at most `slotCount` slots
    /// longer. A fixed length left the lower half of the bar empty.
    public static func barLength(slots: Int) -> CGFloat {
        let head = mascotTopInset + mascotSize + mascotTopInset
        guard slots > 0 else { return head }
        let column = CGFloat(slots) * indicatorSize + CGFloat(slots - 1) * indicatorSpacing
        return head + indicatorTopGap + column
    }

    /// Where the bar's head is laid out from: a full bar is centred on the
    /// edge, a shorter one hangs from the same head, so the mascot never moves.
    public static let anchorLength = barLength(slots: SessionRowsModel.slotCount)

    /// The top of a slot's ring, from the window's top. The card opens level
    /// with its row, held inside the window (`BarBody.cardTop`).
    public static func slotTop(_ index: Int) -> CGFloat {
        mascotTopInset + mascotSize + indicatorTopGap + CGFloat(index) * rowPitch
    }

    /// One row: its ring and one gap.
    public static var rowPitch: CGFloat { indicatorSize + indicatorSpacing }

    /// How many rows the open list shows at most. The half row is the sign
    /// that more follow (`006`, user's decision) — there is no scroll bar,
    /// arrow or count.
    public static let visibleRows: CGFloat = 7.5

    /// The open list's visible area starts half a gap above the first ring,
    /// so every row — ring, name and status line — is whole inside it.
    public static var listTop: CGFloat { slotTop(0) - indicatorSpacing / 2 }

    /// The visible area's height: every row up to seven and a half.
    public static func listHeight(rows: Int) -> CGFloat {
        min(CGFloat(max(0, rows)), visibleRows) * rowPitch
    }

    /// The summary line under the list ("20 sessions · 3 working").
    public static let summaryGap: CGFloat = 8
    public static let summaryHeight: CGFloat = 12
    public static func summaryTop(rows: Int) -> CGFloat {
        listTop + listHeight(rows: rows) + summaryGap
    }

    /// The usage block (`UsageBlock`): under the summary, or under the mascot
    /// when there is no session. From what is above to the block's hairline:
    public static let usageGap: CGFloat = 10
    /// From the hairline to the first line.
    public static let usageInset: CGFloat = 6
    /// One line of the block, a group's heading or a window alike, so the
    /// block's length is its line count.
    public static let usageLineHeight: CGFloat = 14

    /// The block's hairline, from the window's top. With no session there is
    /// no list and no summary: the block starts where the first ring would.
    public static func usageTop(rows: Int) -> CGFloat {
        let above = rows > 0 ? summaryTop(rows: rows) + summaryHeight : mascotTopInset + mascotSize
        return above + usageGap
    }

    /// The block's length from its hairline; nothing without a line.
    public static func usageHeight(lines: Int) -> CGFloat {
        lines > 0 ? usageInset + CGFloat(lines) * usageLineHeight : 0
    }

    /// The open body's length: the head, the visible list and the summary,
    /// the usage block under them, closed by the same margin as the head
    /// opens with. With no session the block hangs under the mascot; with
    /// neither, the head alone. Kept apart from the closed length
    /// (`BarState.openLength`), which the block never changes.
    public static func openLength(rows: Int, usageLines: Int = 0) -> CGFloat {
        if usageLines > 0 {
            return usageTop(rows: rows) + usageHeight(lines: usageLines) + mascotTopInset
        }
        guard rows > 0 else { return barLength(slots: 0) }
        return summaryTop(rows: rows) + summaryHeight + mascotTopInset
    }

    /// The open body's width: the names', the summary's or the block's,
    /// whichever needs most, within the window's room.
    static func openWidth(rows: [SessionRow], usage: [UsageLine],
                          in lang: String = L10n.language) -> CGFloat {
        min(max(SessionColumn.openWidth(rows: rows, in: lang), UsageBlock.minWidth(lines: usage, in: lang)),
            expandedBarWidth)
    }

    /// How far the open list scrolls: until the last row is whole, with half
    /// a gap under it — the mirror of the top, where half a row shows above.
    /// Zero while every row fits.
    public static func maxScrollOffset(rows: Int) -> CGFloat {
        max(0, CGFloat(max(0, rows)) * rowPitch - listHeight(rows: rows))
    }

    /// A notched wheel's step, per line it reports: AppKit's own default
    /// (`NSScrollView.verticalLineScroll`). A trackpad reports points.
    public static let lineScroll: CGFloat = 10

    /// The least scrolling that shows a row whole: up to it if it is cut at
    /// the top, down to it if it is cut at the bottom, nothing if it is in
    /// sight. A row's slot is its ring and half the gap each side.
    static func offset(revealing index: Int, rows: Int, from offset: CGFloat) -> CGFloat {
        let top = CGFloat(index) * rowPitch
        let height = listHeight(rows: rows)
        var next = offset
        if top < offset {
            next = top
        } else if top + rowPitch > offset + height {
            next = top + rowPitch - height
        }
        return min(max(0, next), maxScrollOffset(rows: rows))
    }

    /// Whether a row of the open list counts as on screen: its ring wholly in
    /// the visible area. Only such a row takes hover or keeps a card; the
    /// half row does not. `offset` is how far the list is scrolled. The one
    /// place this is decided.
    static func isRowVisible(_ index: Int, rows: Int, offset: CGFloat = 0) -> Bool {
        guard index >= 0, index < rows else { return false }
        let top = slotTop(index) - offset
        return top >= listTop - 0.5 && top + indicatorSize <= listTop + listHeight(rows: rows) + 0.5
    }

    /// The row under a point, measured from the docked edge and the window's
    /// top; `nil` over the mascot, outside the visible list, over a row not
    /// wholly visible or past `width` — the drawn body's. A slot is its ring
    /// and half the gap each side, so the cursor moving down the column is
    /// always over some row. Rows are fixed-height (`SessionColumn`), so
    /// this is the whole geometry.
    static func slot(fromEdge x: CGFloat, fromTop y: CGFloat, width: CGFloat,
                     rows: Int, offset: CGFloat = 0) -> Int? {
        guard x >= 0, x <= width,
              y >= listTop, y < listTop + listHeight(rows: rows) else { return nil }
        let index = Int((y + offset - listTop) / rowPitch)
        return isRowVisible(index, rows: rows, offset: offset) ? index : nil
    }

    /// Whether a point is over the open list's visible area: the body's
    /// width, from the first row's half gap to the last visible one's. The
    /// mascot, the summary line and the card are not the list.
    static func isOverList(fromEdge x: CGFloat, fromTop y: CGFloat, width: CGFloat, rows: Int) -> Bool {
        x >= 0 && x <= width && y >= listTop && y < listTop + listHeight(rows: rows)
    }

    /// The detail card beside the open list (`phase-4` draws it). Fixed here
    /// because the window is sized for it once and never again.
    public static let detailCardWidth: CGFloat = 260
    /// Between the open body's inner edge and the card: the card stands
    /// apart (`005`, user's decision). The gap is still "on the bar" for
    /// hover (`cardHoverRect`), so crossing it closes nothing.
    public static let detailCardGap: CGFloat = 8

    /// The card's hover area: the drawn card and the gap to the body, so a
    /// cursor on its way from a row to the card never leaves the bar. In the
    /// gap it is over no row (`slot` stops at the body's width), which drops
    /// a pending row switch like the card itself does. The gap is on the
    /// card's side toward the docked edge — right of it on the right edge,
    /// left of it on the left.
    static func cardHoverRect(_ card: CGRect, edge: BarPanel.Edge) -> CGRect {
        var rect = card
        rect.size.width += detailCardGap
        if edge.isLeft { rect.origin.x -= detailCardGap }
        return rect
    }
    /// The tallest the card gets: header, status title, the tool and its
    /// subject or a few lines of the last reply, the footer and the button —
    /// about 180 pt at the card's type sizes, with room to spare. The card
    /// caps its text lines to stay inside it.
    public static let detailCardMaxHeight: CGFloat = 200

    /// The window, built once and never resized: as wide as the widest open
    /// list with the card beside it (and the gap between) and the card's
    /// shadow, and as long as the
    /// full bar or the tallest card hanging from the fourth slot (and its
    /// shadow), whichever reaches further. The whole open list fits in it
    /// (`openLength`); a card further down is held at this floor
    /// (`BarBody.cardTop`) rather than growing the window toward the Dock. The head is still laid out from
    /// `anchorLength`, so everything past the full bar hangs below it,
    /// transparent: clicks fall through, hover is only the drawn part.
    ///
    /// Resizing at interaction time is what `004` could not make smooth — a
    /// window growing leftward showed its old content one frame at the old
    /// origin — and a card that lengthened the window would repeat it downward.
    ///
    /// The usage block (`009`) grew it once, downward: the longest open body
    /// is now seven and a half rows, the summary and a full block
    /// (`UsageBlockModel.maxLines`), with the shadow's room under it. What is
    /// added is transparent and hangs below the head, like the rest.
    public static let envelopeSize = CGSize(
        width: expandedBarWidth + detailCardGap + detailCardWidth + shadowGutter,
        height: max(anchorLength,
                    slotTop(SessionRowsModel.slotCount - 1) + detailCardMaxHeight + shadowGutter,
                    longestOpenLength + shadowGutter))

    /// The longest the open body gets: the visible list full, and the block.
    static var longestOpenLength: CGFloat {
        openLength(rows: Int(visibleRows.rounded(.up)), usageLines: UsageBlockModel.maxLines)
    }

    /// No directory watching, just polling.
    /// `DispatchSource.makeFileSystemObjectSource` needs an `open()` file
    /// descriptor and that is **Darwin** — it could live on this side, but
    /// polling is enough at this size and stays portable. The interval is
    /// measured and recorded in the phase notes.
    private static let pollInterval: TimeInterval = 1.5

    /// How long an arriving event waits for its neighbours before the seam is
    /// run once for all of them.
    ///
    /// Events do not trickle, they burst: a single turn sends a `PreToolUse`
    /// and a `PostToolUse` per tool call, and a subagent's land on the parent's
    /// session too. Refreshing per event would re-read the session directory
    /// that many times and hand `@Published` a write each time — the trap this
    /// repo names outright (`proje.md` → tuzaklar). A tenth of a second is far
    /// below anything the eye resolves and still an order of magnitude better
    /// than waiting out the poll above, which is what `PermissionRequest` used
    /// to do.
    public static let refreshCoalescing: TimeInterval = 0.1

    /// The real platform capabilities. This is the only place that touches
    /// Darwin; `EvlatCore` receives them as closures.
    nonisolated public static var darwinPlatform: Platform {
        Platform(isAlive: Self.isProcessAlive, processStartedAt: Self.processStartedAt)
    }

    /// Is a process **actually running** under this pid?
    ///
    /// `kill(pid, 0)` is not enough; it reports "alive" wrongly in two places:
    ///   - `pid <= 0` is special: `0` means the caller's own process group and
    ///     `-1` means every process. A stored or defaulted `0` would look alive
    ///     forever.
    ///   - **Zombies**: a process that exited but has not been reaped is still
    ///     in the table, so `kill` returns 0 while the session is dead.
    /// `sysctl`/`kinfo_proc` answers both — `p_stat` reveals the zombie. v1
    /// walks the same path (`SessionHost.parentPID`) and needs no permission.
    nonisolated static func isProcessAlive(_ pid: Int32) -> Bool {
        guard let info = procInfo(pid) else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    /// When the process started. Used to tell a recycled pid apart: the record
    /// carries its own `startedAt`, and if the two disagree some other process
    /// now owns that pid.
    nonisolated static func processStartedAt(_ pid: Int32) -> Date? {
        guard let info = procInfo(pid) else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private nonisolated static func procInfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info
    }

    /// The provider bound to the real location. Path and liveness both come
    /// from outside, so a test can fake either.
    ///
    /// `EVLAT_SESSIONS` overrides the directory. It exists because the "nothing
    /// is live" state cannot be produced on a machine that has live sessions,
    /// and that state is exactly what the idle-cost measurement needs. v1 uses
    /// the same pattern (`EVLAT_PORT`, `EVLAT_PET`). Without it the directory
    /// follows the resolved home, so `EVLAT_HOME` moves it too.
    nonisolated public static func sessionsDirectory(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment["EVLAT_SESSIONS"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return SessionsProvider.defaultDirectory(home: resolvedHome(environment))
    }

    /// The home the app works under: `EVLAT_HOME` (tilde expanded, blank
    /// ignored), else the user's. It exists so the hook entries can be tried
    /// by hand against a temporary directory. Only `launch()` and the
    /// sessions directory ask for it; a controller built without a home
    /// never does.
    ///
    /// Launched with `open`, the shell's environment does not reach the app
    /// and this is the real home: a hand check runs the binary directly.
    nonisolated static func resolvedHome(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let raw = environment["EVLAT_HOME"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated public static func makeSessionsProvider() -> SessionsProvider {
        SessionsProvider(directory: sessionsDirectory(), platform: darwinPlatform)
    }

    /// `EVLAT_PHASE=working` forces a phase at launch, the scriptable twin of
    /// the "Force state" menu item.
    ///
    /// It is the other half of the measurement instrument `003/phase-2` needs
    /// (`phase-2.md` → Ölçüm: *fix the phase, point `EVLAT_SESSIONS` at an empty
    /// directory*). The menu reaches the same state, but a measurement has to
    /// be launched and torn down from a script, and a clip that has to be
    /// selected by hand cannot be put in a window beside another one.
    ///
    /// It writes `override` and nothing else, so "Follow sessions" in the menu
    /// clears it exactly like any other forced phase. An unreadable value is
    /// ignored rather than refused.
    nonisolated public static func forcedPhase(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Phase? {
        guard let raw = environment["EVLAT_PHASE"]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        return Phase(rawValue: raw)
    }

    /// `EVLAT_SELECT=<entity|first>` opens the list at launch with that
    /// session's card up — the scriptable way to measure and look at the
    /// card, the same pattern as `EVLAT_PHASE`. An unknown entity selects
    /// nothing.
    enum ForcedSelection: Equatable {
        case first
        case entity(String)
    }

    nonisolated static func forcedSelection(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ForcedSelection? {
        guard let raw = environment["EVLAT_SELECT"]?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw.lowercased() == "first" ? .first : .entity(raw)
    }

    /// `EVLAT_SCROLL=<pt>` opens the list at launch scrolled this far (held
    /// to the list's bounds) — for looking at and measuring the middle and
    /// the end, the same pattern as `EVLAT_SELECT`. An unreadable value is
    /// ignored.
    nonisolated static func forcedScroll(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CGFloat? {
        guard let raw = environment["EVLAT_SCROLL"]?.trimmingCharacters(in: .whitespaces),
              let value = Double(raw), value.isFinite else { return nil }
        return CGFloat(value)
    }

    /// `EVLAT_EDGE=left|right` docks the bar there at launch, over what is
    /// stored — for looking at and measuring one edge from a script, the
    /// same pattern as `EVLAT_PHASE`. It is read, never written: the next
    /// launch without it is back to the stored edge. Any other value is
    /// ignored.
    nonisolated static func forcedEdge(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BarPanel.Edge? {
        switch environment["EVLAT_EDGE"]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "left": return .left
        case "right": return .right
        default: return nil
        }
    }

    /// The stored edge's key. The domain is shared with v1
    /// (`dev.kalaomer.evlat`), whose keys are plain camelCase; the dotted
    /// prefix keeps the two apart.
    nonisolated static let edgeKey = "bar.edge"

    /// The edge the user chose, `right` or `left`; anything else — nothing
    /// stored, `top`, a number — is `nil`, and the caller falls back to the
    /// right. Reading writes nothing: an unknown value stays as it is, and
    /// the menu is the only writer (`chooseEdge`).
    nonisolated static func storedEdge(_ defaults: UserDefaults?) -> BarPanel.Edge? {
        switch defaults?.string(forKey: edgeKey) {
        case "left": return .left
        case "right": return .right
        default: return nil
        }
    }

    /// The stored form of an edge the menu offers.
    private nonisolated static func storedValue(_ edge: BarPanel.Edge) -> String {
        edge.isLeft ? "left" : "right"
    }

    /// The eyes' real centre, not an approximation of it: the inset and half
    /// the mascot below the top, and half the bar's width in from the docked
    /// edge (the window is wider than the bar). Read off shared constants so
    /// the anchor does not drift when the layout moves.
    static func gazeAnchor(frame: NSRect, edge: BarPanel.Edge) -> CGPoint {
        CGPoint(x: edge.x(atInset: barWidth / 2, in: frame),
                y: frame.maxY - mascotTopInset - mascotSize / 2)
    }

    /// How long `--capture` listens when no number follows it.
    nonisolated public static var defaultCaptureWindow: TimeInterval { 30 }

    /// `--capture [SECONDS]`, or `nil` when the flag is absent.
    ///
    /// `--list` is a separate process from the running app and cannot read its
    /// counters, so this is how the bucket is ever seen: the flag makes the
    /// diagnostics run **as** the endpoint for a bounded window. A malformed or
    /// missing number falls back to the default rather than refusing — the flag
    /// is a measuring instrument, and refusing to measure is the worse answer.
    nonisolated public static func captureWindow(_ arguments: [String]) -> TimeInterval? {
        guard let index = arguments.firstIndex(of: "--capture") else { return nil }
        let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        // `isFinite` and the ceiling are not decoration: `Double("inf")` and
        // `Double("1e400")` both parse and are both > 0, and the first thing
        // done with the value is `Int(window)`, which **traps** on either.
        // A day is past any measurement and still safely inside `Int`.
        guard let text = next, let seconds = Double(text),
              seconds > 0, seconds.isFinite, seconds <= 86_400 else {
            return defaultCaptureWindow
        }
        return seconds
    }

    /// `Evlat --list`: print the signals and exit, opening no window.
    /// This set's stand-in for v1's `GET /status`; the full local API lands in
    /// `002`.
    ///
    /// With `capturingFor`, it also **binds** the hook port for that many
    /// seconds and prints every event that arrives. Without it, the endpoint is
    /// only asked whether someone is already answering there.
    nonisolated public static func printSignalsAndExit(capturingFor window: TimeInterval? = nil) -> Never {
        let provider = makeSessionsProvider()
        let registry = Registry()
        registry.register(provider)
        // The one reload this process does; timed, because it runs on the
        // app's main queue when the bar opens.
        let codex = CodexUsageProvider(home: resolvedHome())
        registry.register(codex)
        let started = DispatchTime.now()
        registry.reload()
        let reloadMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        // One scan, every derived value — see Registry.Snapshot for why the
        // separate accessors are gone.
        let snapshot = registry.snapshot()
        print("provider: \(SessionsProvider.id)  ·  directory: \(sessionsDirectory().path)")
        print("live sessions: \(snapshot.ordered.count)  ·  aggregate: \(snapshot.aggregate.rawValue)  ·  hasLive: \(snapshot.hasLive)")
        // Resolved here too, so the lookup can be checked against the live
        // sessions on this machine without opening a card.
        for signal in snapshot.ordered {
            print(listLine(signal, host: SessionHost.resolve(pid: signal.activity?.pid)))
        }
        // Apart from the sessions and outside their count: a usage window is
        // not a session (`Registry.Snapshot`).
        for signal in snapshot.usage {
            print(usageLine(signal))
        }
        // The format is undocumented and the provider goes quiet when it
        // drifts; quiet must not read as "Codex has no limits".
        if codex.lastReadFailed {
            print("codex usage: unreadable (format may have drifted)"
                + (codex.currentSignals().isEmpty ? "" : "; showing the last good reading"))
        }
        print(String(format: "usage reload: %.1f ms", reloadMs))
        if !provider.unrecognizedStatuses.isEmpty {
            print("unrecognised status: \(provider.unrecognizedStatuses.sorted().joined(separator: ", "))")
        }
        if provider.recordsMissingUpdatedAt > 0 {
            print("records with unreadable updatedAt: \(provider.recordsMissingUpdatedAt) (format may have drifted)")
        }
        // The row's stamp comes from `statusUpdatedAt`; falling back to
        // `updatedAt` silently would restore the skew that moved it there.
        if provider.recordsMissingStatusUpdatedAt > 0 {
            print("records with unreadable statusUpdatedAt: \(provider.recordsMissingStatusUpdatedAt) (format may have drifted)")
        }
        // The drift that would otherwise look like a healthy idle machine.
        if provider.recordsUnparseable > 0 {
            print("records that could not be parsed: \(provider.recordsUnparseable) (format may have drifted)")
        }
        printHookEndpoint(capturingFor: window)
        exit(0)
    }

    /// One `--list` row. Separate so its privacy has a test: the row names the
    /// session and its phase, and **never** its `activity` — the tool, the
    /// command and the last reply stay on the card. `--list` output is what
    /// ends up pasted into bug reports. The terminal is named, the pid is not.
    nonisolated static func listLine(_ signal: Signal, host: SessionHost? = nil) -> String {
        let raw = signal.rawStatus.map { " (raw: \($0))" } ?? ""
        let phase = signal.phase.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        let terminal = host.map { "  → \($0.diagnostic)" } ?? ""
        return "  \(phase) \(signal.label)\(raw)  ← \(signal.detail ?? "")\(terminal)"
    }

    /// One `--list` usage row: group, window, percent, reset, observation and
    /// fidelity. The percent is printed as the source said it, past 100 too —
    /// this is the diagnostic the bar's clipped bar is checked against. Dates
    /// are ISO 8601 so the line reads the same in every locale.
    nonisolated static func usageLine(_ signal: Signal) -> String {
        let iso = ISO8601DateFormatter()
        let percent = signal.progress.map { percentText($0 * 100) } ?? "—"
        let window = signal.usage.map { "\($0.group) \($0.windowMinutes)m" } ?? "\(signal.entity) (no window)"
        let resets = signal.usage.map { "  resets \(iso.string(from: $0.resetsAt))" } ?? ""
        return "  usage    \(window)  \(percent)\(resets)  seen \(iso.string(from: signal.updatedAt))"
            + "  (\(signal.fidelity.rawValue))"
    }

    /// A percent for the diagnostics, as the source said it. `Int(_:)` traps
    /// on NaN, infinity **and any finite value past its range** — `1e30` from
    /// a local POST would take `--capture` down — so the odd value is printed
    /// as it came, the diagnostic surviving the number it exists to show.
    nonisolated static func percentText(_ percent: Double) -> String {
        let scaled = percent.rounded()
        guard scaled.isFinite, abs(scaled) < Double(Int32.max) else { return "\(percent)%" }
        return "\(Int(scaled))%"
    }

    /// One `--capture` line for a status line's report: its windows and the
    /// keys it did not draw. This is where `unrecognizedWindows` is seen —
    /// `--list` is another process and never receives a report. The report
    /// holds nothing else of the body, so nothing else can be printed.
    nonisolated static func usageCaptureLine(_ report: UsageReport) -> String {
        let windows = report.windows.map { "\($0.minutes)m \(percentText($0.usedPercent))" }
        let unrecognized = report.unrecognizedWindows.isEmpty
            ? "" : "  (unrecognised: \(report.unrecognizedWindows.sorted().joined(separator: ", ")))"
        return "  usage    claude  \(windows.isEmpty ? "no windows" : windows.joined(separator: ", "))\(unrecognized)"
    }

    /// The hook endpoint's own diagnostics.
    ///
    /// Failing to bind is the way this feature breaks in the field and it
    /// produces **no symptom at all**: v1 and v2 carry the same bundle id and
    /// the same executable name, so a v1 left running holds 48151, v2 starts
    /// fine, and no event ever arrives. That state is printed here.
    private nonisolated static func printHookEndpoint(capturingFor window: TimeInterval?) {
        let choice = HookListener.resolvePort()
        if let rejected = choice.rejectedOverride {
            print("EVLAT_PORT=\(rejected) ignored: not a usable port number")
        }
        guard let window = window else {
            print("hook endpoint: 127.0.0.1:\(choice.port)  ·  \(probeHookEndpoint(port: choice.port))")
            return
        }

        // Line buffering, because stdout is fully buffered whenever it is not a
        // terminal: under `… --capture 135 | tee log` nothing would appear
        // until the process exited, and a Ctrl-C inside the window would lose
        // every line — the exact failure streaming was chosen to avoid.
        setvbuf(stdout, nil, _IOLBF, 0)
        let diagnostics = HookDiagnostics()
        let listener = HookListener(port: choice.port) { delivery in
            switch delivery {
            case .hook(let event):
                // Streamed, not only summarised: under a `PostToolUse` burst a
                // fixed-size bucket drops exactly the rare event a measurement
                // is looking for (one `Stop` carrying an `agent_id`).
                print(diagnostics.record(event).text)
            case .usage(let report):
                // Not recorded with the hooks: a status line runs on every
                // assistant message and would crowd them out of the bucket.
                print(usageCaptureLine(report))
            }
        }
        listener.start()
        let status = listener.awaitSettled()
        print("hook endpoint: \(status.text)")
        guard case .listening = status else {
            // A busy port says "in use" but not WHO — and that is the whole
            // question when the port is held by the other Evlat.
            print("  ·  \(probeHookEndpoint(port: choice.port))")
            return
        }
        print("capturing for \(Int(window)) s …")
        // Events are delivered to the main queue; this is what runs it. The
        // timer is not idle decoration: a run loop with no input source at all
        // returns from `run(until:)` immediately, and the capture would then
        // print an empty summary and exit without ever having listened.
        let deadline = Date().addingTimeInterval(window)
        RunLoop.main.add(Timer(fire: deadline, interval: 0, repeats: false) { _ in }, forMode: .default)
        RunLoop.main.run(until: deadline)
        listener.stop()
        // Events cross on `DispatchQueue.main.async`, so the ones handed over
        // just before the deadline have not run yet. Without this drain they
        // are neither printed nor counted, and the totals a measurement is
        // read from would be short by the last few.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        diagnostics.summary.forEach { print($0) }
    }

    /// Is anything answering there, and which Evlat is it?
    ///
    /// A `GET /health` rather than a trial bind: binding takes the port away
    /// from the running app for as long as it is held, and a hook that arrived
    /// in that window would be answered by a process about to exit. The body
    /// tells the two apps apart — v1 answers the bare word `ok`, v2 answers
    /// `{"ok":true}` (`phase-2` corrected it).
    ///
    /// **Only "cannot connect" means free.** Every other failure — a process
    /// that accepts the connection and never answers, or speaks something
    /// that is not HTTP — means the port is taken. Reading those as free
    /// would print "nothing is listening" in precisely the situation this
    /// diagnostic exists for: a v1 holding 48151 while v2 failed to bind.
    private nonisolated static func probeHookEndpoint(port: UInt16, timeout: TimeInterval = 1) -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return "unreadable address" }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let semaphore = DispatchSemaphore(value: 0)
        // Guarded: on the wait's own timeout this thread would otherwise write
        // the same variable the session's callback thread is writing.
        let lock = NSLock()
        var answer: String?
        URLSession(configuration: configuration).dataTask(with: url) { data, _, error in
            let result: String
            if let error = error as? URLError, error.code == .cannotConnectToHost {
                result = "free — nothing is listening"
            } else if let error = error {
                result = "in use — did not answer (\(error.localizedDescription))"
            } else {
                switch String(data: data ?? Data(), encoding: .utf8) ?? "" {
                case "{\"ok\":true}": result = "in use — an Evlat v2 answers"
                case "ok": result = "in use — an Evlat v1 answers"
                case let body: result = "in use — answered \(body.prefix(40))"
                }
            }
            lock.withLock { answer = result }
            semaphore.signal()
        }.resume()
        // The request has its own timeout; this one only keeps a lost callback
        // from hanging the diagnostics for ever.
        _ = semaphore.wait(timeout: .now() + timeout + 2)
        return lock.withLock { answer } ?? "no answer within \(timeout + 2) s"
    }

    public init(defaults: UserDefaults? = nil, home: URL? = nil) {
        self.defaults = defaults
        self.home = home
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: no Dock icon, no Cmd-Tab entry. The bar should behave
        // like part of the system rather than like an app.
        NSApp.setActivationPolicy(.accessory)
        registry.register(Self.makeSessionsProvider())
        // The undo switch for this whole set: with this one line gone the
        // listener still binds and the events still parse, and the bar is
        // exactly what `001` shipped.
        registry.register(hooks)
        // Only with a home: a controller built without one (every test) must
        // never fall through to the real `~/.codex` (`008`'s rule). Read when
        // the bar opens, not here.
        // Memory only, no file: safe without a home. Before Codex so the
        // block's order does not hang on registration (it sorts by group).
        registry.register(claudeUsage)
        if let home { registry.register(CodexUsageProvider(home: home)) }
        startHookListener()
        installStatusItem()

        // The environment over the stored choice, the right over nothing.
        // Read here, never written back: only the menu writes.
        let panel = installPanel(edge: Self.forcedEdge() ?? Self.storedEdge(defaults) ?? .right)
        panel.show()
        hover.onChange = { [weak self] open in
            guard let self else { return }
            if open {
                self.openBar()
                // A cursor that entered over a ring and stayed still sends no
                // move after the bar opens: its row is read here instead.
                self.pointerMoved(NSEvent.mouseLocation)
            } else {
                self.closeBar()
            }
        }

        // A phase forced from the environment, for looking at one state and for
        // measuring it. Set before the first refresh so the mascot never shows
        // the aggregate for a frame first.
        mascot.override = Self.forcedPhase()

        // The seam runs here: provider → Registry → MascotModel → view.
        refresh()
        // Scrolled first, so a selection in sight at that offset stays there.
        if let offset = Self.forcedScroll() {
            hover.openNow()
            if !barState.isOpen { openBar() }
            listScroll.set(offset, max: Self.maxScrollOffset(rows: sessionRows.rows.count))
        }
        switch Self.forcedSelection() {
        case .first?: sessionRows.rows.first.map { select($0.entity) }
        case .entity(let entity)?: select(entity)
        case nil: break
        }
        poller = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }  // Timer callback is nonisolated
        }

        // The edge is read at each call: `dock` moves this same panel.
        let tracker = GazeTracker(model: mascot) { [weak panel] in
            guard let panel else { return .zero }
            return Self.gazeAnchor(frame: panel.frame, edge: panel.edge)
        }
        tracker.start()
        gaze = tracker

        panel.onPointer = { [weak self] pointer in
            guard let self else { return }
            switch pointer {
            case .entered:
                self.hover.pointerEntered()
            case .exited:
                // Off the bar is off every row: a switch still pending
                // would otherwise select after the cursor has gone.
                self.rowSwitch.cancel()
                if self.barState.hovered != nil { self.barState.hovered = nil }
                self.hover.pointerExited()
            case .moved(let point):
                // A move is only reported inside the bar, so it also says
                // "still here" — which is what cancels a close pending from a
                // missed exit/enter pair.
                self.hover.pointerEntered()
                self.gaze?.observe(point)
                self.pointerMoved(point)
            }
        }

        // Resolution changes, an unplugged display, or the Dock moving to the
        // right edge all change `visibleFrame`. Without this the bar keeps a
        // stale origin: it detaches from the edge — the whole premise of the
        // flare — or lands on coordinates no screen has and becomes
        // unreachable. `.canJoinAllSpaces` covers space switches, not geometry.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated { panel?.reposition() }
        }
    }

    /// Builds the window at the envelope's size, once. Nothing resizes it
    /// afterwards: a window growing leftward showed its old content one frame
    /// at the old origin, and the body teleported left before sliding back.
    /// The room the open body and the card need is kept, transparent, and only
    /// the drawn parts move. Clicks on the transparent part fall through to
    /// the window below; the hover areas are held to what is drawn
    /// (`setVisibleWidth`, `setVisibleLength`). Internal so a test can hold
    /// the frame still across sessions arriving and the bar opening.
    ///
    /// The edge is handed in: this reads neither the environment nor the
    /// stored setting, so a test never docks by the user's choice.
    @discardableResult
    func installPanel(edge: BarPanel.Edge = .right) -> BarPanel {
        // The body's edge is written here once, before it is drawn; after
        // this only `dock` writes it.
        barState.edge = edge
        let panel = BarPanel(edge: edge,
                             size: Self.envelopeSize,
                             anchorLength: Self.anchorLength,
                             trackingInset: Self.shadowGutter,
                             content: BarBody(mascot: mascot, rows: sessionRows,
                                              state: barState, scroll: listScroll, detail: detail,
                                              usage: usageBlock,
                                              onCardFrame: { [weak self] rect in
                                                  self?.cardFrameChanged(rect)
                                              },
                                              onGoButtonFrame: { [weak self] rect in
                                                  self?.goButtonFrameChanged(rect)
                                              }))
        panel.setVisibleWidth(Self.barWidth)
        panel.setVisibleLength(barState.length)
        panel.onClick = { [weak self] point in
            self?.click(at: point) ?? false
        }
        panel.onScroll = { [weak self] point, deltaY, precise in
            self?.scroll(at: point, deltaY: deltaY, precise: precise) ?? false
        }
        panel.onMenu = { [weak self] point in
            self?.menu(at: point)
        }
        rowSwitch.onSelect = { [weak self] entity in self?.select(entity) }
        self.panel = panel
        return panel
    }

    /// Moves the bar to another edge, live: the same panel, so hover, the
    /// gaze anchor and the screen observer stay wired to it. An open list and
    /// card close first, through the intent — a closed bar the intent
    /// believed open would ignore the next enter — then the window, its hover
    /// areas and the body take the new edge. Activates nothing.
    func dock(_ edge: BarPanel.Edge) {
        hover.closeNow()
        // The intent may already have believed the bar closed.
        if barState.isOpen { closeBar() }
        panel?.edge = edge
        if barState.edge != edge { barState.edge = edge }
    }

    /// Binds the hook port. Every event that arrives goes to
    /// `handleHookEvent`, which is where the seam starts.
    private func startHookListener() {
        let choice = HookListener.resolvePort()
        if let rejected = choice.rejectedOverride {
            NSLog("Evlat: EVLAT_PORT=%@ ignored, not a usable port number", rejected)
        }
        let listener = HookListener(
            port: choice.port,
            // Binding is asynchronous, so the outcome cannot be returned from
            // here. It is not swallowed either: `Evlat --list` reads the port
            // back over `/health` and says who holds it.
            onStatus: { status in
                if case .unavailable = status { NSLog("Evlat: hook endpoint %@", status.text) }
            },
            onDelivery: { [weak self] delivery in
                MainActor.assumeIsolated { self?.handleDelivery(delivery) }
            })
        listener.start()
        hookListener = listener
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hookListener?.stop()
        poller?.invalidate()
        gaze?.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Entry point for the executable shell. Top-level code in `main.swift` is
    /// not main-actor isolated even though it does run on the main thread, so
    /// the hop is stated here once instead of at the call site.
    nonisolated public static func launch() -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            // The one place the user's domain and home are handed in.
            let controller = AppController(defaults: .standard, home: resolvedHome())
            app.delegate = controller
            app.run()
        }
        exit(0)
    }

    /// Whatever the listener accepted. Each goes to its own provider; both
    /// only schedule a read, so a status line's burst coalesces like a hook's.
    func handleDelivery(_ delivery: LocalAPI.Delivery) {
        switch delivery {
        case .hook(let event):
            handleHookEvent(event)
        case .usage(let report):
            // Not `hookDiagnostics`: that bucket is the hooks' and nothing of
            // the status line's body belongs in it.
            claudeUsage.handle(report)
            scheduleRefresh()
        }
    }

    /// One event, from the listener's callback. Internal so the coalescing has
    /// a test; the listener is the only caller in the app.
    func handleHookEvent(_ event: HookEvent) {
        hookDiagnostics.record(event)
        hooks.handle(event)
        scheduleRefresh()
    }

    /// Runs the seam once for a burst of events.
    ///
    /// A plain `async` would not do: the events of one turn arrive over
    /// seconds, each on its own run-loop turn, so there would be nothing to
    /// coalesce with. This is not the timer `plan.md` rules out either — that
    /// one was a scheduled **state change** (`review` → `idle` after 25 s),
    /// which is derived at read time now. This schedules a read.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshCoalescing) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    /// One scan, every value. The registry is not asked twice: a file changing
    /// in between could leave `phase` and `hasLive` contradicting each other.
    ///
    /// **What is compared is what is written**, field by field, not the
    /// snapshot. The snapshot carries every row's stamp and a hook row's stamp
    /// moves on every single event, so comparing snapshots would report
    /// "changed" for precisely the burst the deadband exists to absorb. The
    /// mascot's face, whether anything is live, and the visible fields of the
    /// indicator rows are the whole of what this writes.
    ///
    /// Internal rather than private so the deadband is testable: it fails
    /// silently — the app keeps working and simply re-evaluates the bar at
    /// event rate.
    func refresh() {
        let snapshot = registry.snapshot()
        if mascot.phase != snapshot.aggregate {
            // The only trace the seam leaves in the field. `--capture` shows
            // the events and `--list` the file rows, but neither runs in this
            // process, so without this line a face that never changes is
            // indistinguishable from events that never arrive.
            //
            // Read it from **stderr**, which means running the binary rather
            // than opening the bundle. Both were measured: the unified log
            // redacts this to `(Foundation) <private>`, and `%{public}@` does
            // not help — that is an `os_log` specifier and `NSLog` prints it
            // verbatim, arguments dropped.
            NSLog("Evlat: aggregate %@ → %@", mascot.phase.rawValue, snapshot.aggregate.rawValue)
            mascot.phase = snapshot.aggregate
        }
        if mascot.hasLive != snapshot.hasLive { mascot.hasLive = snapshot.hasLive }

        // Same snapshot, so the rings and the face cannot disagree. The model
        // keeps its own deadband over what it draws.
        let before = sessionRows.rows
        sessionRows.update(from: snapshot.ordered)
        // The block's own deadband: its lines move with the drawn percent and
        // the minute, not with a relay's stamp. The clock is read here, so a
        // window that resets leaves within one poll.
        let usageBefore = usageBlock.lines
        usageBlock.update(from: snapshot.usage, now: now())
        let rowsChanged = before != sessionRows.rows
        if rowsChanged || usageBefore != usageBlock.lines {
            // The body follows the column and the block — drawn, not the
            // window. Both lengths are kept, the closed and the open one; the
            // block is only in the open one. The hover area is AppKit's and
            // hears nothing from SwiftUI, so it is told the one drawn.
            let rowCount = sessionRows.rows.count
            let length = Self.barLength(slots: sessionRows.slotsInUse)
            let openLength = Self.openLength(rows: rowCount, usageLines: usageBlock.lines.count)
            let usageTop = Self.usageTop(rows: rowCount)
            if abs(barState.usageTop - usageTop) > 0.5 { barState.usageTop = usageTop }
            var lengthChanged = false
            if abs(barState.length - length) > 0.5 {
                barState.length = length
                lengthChanged = true
            }
            if abs(barState.openLength - openLength) > 0.5 {
                barState.openLength = openLength
                lengthChanged = true
            }
            if lengthChanged { panel?.setVisibleLength(barState.drawnLength) }
            // A shorter list takes the offset back to its new end, so the
            // last row stays whole and nothing is scrolled past.
            listScroll.set(listScroll.offset, max: Self.maxScrollOffset(rows: sessionRows.rows.count))
            // The open body is as wide as the names it holds, the summary and
            // the block.
            let width = Self.openWidth(rows: sessionRows.rows, usage: usageBlock.lines)
            if abs(barState.openWidth - width) > 0.5 {
                barState.openWidth = width
                if barState.isOpen { panel?.setVisibleWidth(width) }
            }
            if rowsChanged {
                // The rows' trace on stderr, for the same reason as the line above.
                let rows = sessionRows.rows.map { "\($0.phase.rawValue):\($0.entity.prefix(8))" }
                NSLog("Evlat: rows [%@] closed +%ld", rows.joined(separator: ", "), sessionRows.overflow)
                // The mark and a pending switch are keyed by session, and only a
                // move re-reads them. A column that reorders under a still cursor
                // would otherwise leave the mark on a row the cursor has left and
                // bring up the card of a session it no longer points at.
                if barState.isOpen { pointerMoved(mouseLocation()) }
            }
        }
        syncSelection(snapshot.ordered)
    }

    /// The card follows the selected session through the same snapshot: its
    /// slot when the column reorders, its facts when they move. Nothing is
    /// written without a selection. A session that has no visible row any
    /// more — gone, pushed out of the visible list or scrolled out of it —
    /// has nothing for the card to hang from, so the card closes.
    private func syncSelection(_ signals: [Signal]) {
        guard let selected = barState.selected else { return }
        guard let slot = visibleSlot(of: selected) else {
            deselect()
            return
        }
        if barState.selectedSlot != slot { barState.selectedSlot = slot }
        detail.update(row: sessionRows.rows[slot],
                      signal: signals.first { $0.entity == selected })
    }

    /// The session's row index, if its row is wholly in sight.
    private func visibleSlot(of entity: String) -> Int? {
        let rows = sessionRows.rows
        guard let slot = rows.firstIndex(where: { $0.entity == entity }),
              Self.isRowVisible(slot, rows: rows.count, offset: listScroll.offset) else { return nil }
        return slot
    }

    /// Selects a row's session: the row switch after its wait, or
    /// `EVLAT_SELECT` at launch. The list opens (at once, if it was closed),
    /// the row is scrolled into sight if it is not — only `EVLAT_SELECT` can
    /// name such a row; hover reaches visible rows alone — and the card comes
    /// up level with it. Activates nothing — the app stays in the background,
    /// the panel is never key.
    func select(_ entity: String) {
        guard let index = sessionRows.rows.firstIndex(where: { $0.entity == entity }) else { return }
        rowSwitch.cancel()
        hover.openNow()
        if !barState.isOpen { openBar() }
        let count = sessionRows.rows.count
        listScroll.set(Self.offset(revealing: index, rows: count, from: listScroll.offset),
                       max: Self.maxScrollOffset(rows: count))
        if barState.selected != entity { barState.selected = entity }
        syncSelection(registry.snapshot().ordered)
    }

    private func deselect() {
        rowSwitch.cancel()
        detail.cardClosed()
        goButtonRect = nil
        if barState.selected != nil { barState.selected = nil }
        if barState.selectedSlot != nil { barState.selectedSlot = nil }
        panel?.setCardRect(nil)
    }

    /// The cursor over the open list: its row is marked at once (a row
    /// reads as something to point at), and the card follows after the wait
    /// (`RowSwitch`). Written only when the row changes — moves arrive at
    /// display rate.
    func pointerMoved(_ point: CGPoint) {
        let row = row(atScreen: point)
        if barState.hovered != row { barState.hovered = row }
        rowSwitch.hover(row, selected: barState.selected)
    }

    /// A scroll over the bar, from the hosting view. Taken only over the
    /// open list; anywhere else it goes on to SwiftUI.
    func scroll(at point: CGPoint, deltaY: CGFloat, precise: Bool) -> Bool {
        guard barState.isOpen, let panel, let bounds = panel.contentView?.bounds,
              Self.isOverList(fromEdge: panel.edge.inset(of: point.x, in: bounds),
                              fromTop: point.y - bounds.minY,
                              width: barState.openWidth, rows: sessionRows.rows.count) else {
            return false
        }
        scrolled(by: precise ? deltaY : deltaY * Self.lineScroll)
        return true
    }

    /// Moves the list by `deltaY` — positive shows what is above, the way
    /// `scrollingDeltaY` points — held to its bounds. Directly, no spring:
    /// the list follows the finger. A card whose row leaves the sight
    /// closes; then the still cursor's row is read again, so its mark and a
    /// pending switch are for the row now under it. The snapshot is not read
    /// again: scrolling reorders nothing, and a scan per event would read the
    /// sessions directory at display rate.
    func scrolled(by deltaY: CGFloat) {
        guard barState.isOpen,
              listScroll.set(listScroll.offset - deltaY,
                             max: Self.maxScrollOffset(rows: sessionRows.rows.count)) else { return }
        // Before the re-read: closing the card cancels the pending switch,
        // and the re-read then schedules the one for the row under the cursor.
        if let selected = barState.selected, visibleSlot(of: selected) == nil { deselect() }
        pointerMoved(mouseLocation())
    }

    /// The row under a screen point, while the bar is open.
    private func row(atScreen point: CGPoint) -> String? {
        guard let panel, barState.isOpen,
              let slot = Self.slot(fromEdge: panel.edge.inset(of: point.x, in: panel.frame),
                                   fromTop: panel.frame.maxY - point.y,
                                   width: barState.openWidth, rows: sessionRows.rows.count,
                                   offset: listScroll.offset),
              sessionRows.rows.indices.contains(slot) else { return nil }
        return sessionRows.rows[slot].entity
    }

    /// The only click the bar takes is `[Go to session]`'s. Rows and rings
    /// take none: the card comes by hover (`005`, user's decision), and a
    /// click on a row it already speaks for has nothing left to do.
    private func click(at point: CGPoint) -> Bool {
        guard barState.selected != nil, let button = goButtonRect, button.contains(point) else {
            return false
        }
        goToSession()
        return true
    }

    /// The card's drawn rectangle, from the view: with the gap, the second
    /// hover area.
    private func cardFrameChanged(_ rect: CGRect?) {
        panel?.setCardRect(barState.selected == nil ? nil
                           : rect.map { Self.cardHoverRect($0, edge: barState.edge) })
    }

    /// `[Go to session]`'s drawn rectangle, in the content view's (flipped)
    /// coordinates like a click; `nil` without a card.
    private var goButtonRect: CGRect?

    func goButtonFrameChanged(_ rect: CGRect?) {
        goButtonRect = barState.selected == nil ? nil : rect
    }

    /// Looks the terminal up again and brings it forward; the list and the
    /// card close, since the user is elsewhere now. Evlat itself is never
    /// activated (`SessionHost.activate`). If the app is gone, nothing opens
    /// and the card says so.
    func goToSession() {
        guard detail.go() else { return }
        hover.closeNow()
        // The intent may already have believed the bar closed.
        if barState.isOpen { closeBar() }
    }

    /// Opening is the drawn body widening and lengthening; the window is
    /// already big enough. The hover area takes the open size at once, so
    /// the cursor following the body's edge as it travels is still over the
    /// bar.
    func openBar() {
        // The expensive reads (a usage file's tail) happen here and only
        // here: the one moment their result is about to be seen. Which
        // providers answer is theirs to say (`Reloadable`); the scan after it
        // is what brings the new reading onto the body being opened.
        registry.reload()
        refresh()
        panel?.setVisibleWidth(barState.openWidth)
        panel?.setVisibleLength(barState.openLength)
        sessionRows.setOpen(true)
        barState.isOpen = true
    }

    /// Closing: the body narrows back to the edge and the hover area with it.
    func closeBar() {
        // The list and the card close together; the selection does not
        // outlive them.
        deselect()
        if barState.hovered != nil { barState.hovered = nil }
        barState.isOpen = false
        sessionRows.setOpen(false)
        listScroll.set(0, max: 0)
        panel?.setVisibleWidth(Self.barWidth)
        panel?.setVisibleLength(barState.length)
    }

    /// Menu-bar entry. Its menu is rebuilt each time it opens
    /// (`menuNeedsUpdate`), so the edge's mark is never stale.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.on.square",
                                     accessibilityDescription: "Evlat")
        item.menu = trayMenu()
        statusItem = item
    }

    /// The tray's menu: empty until it opens, filled by `menuNeedsUpdate`.
    func trayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// Only the tray's root menu has this delegate; its submenus are rebuilt
    /// with it.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu, diagnostics: true, in: L10n.language)
    }

    /// Every title the menus ask the catalogue for; the phases' are
    /// `StatusLine`'s.
    static let menuKeys = ["menu.edge", "menu.edge.right", "menu.edge.left",
                           "menu.quit", "menu.force", "menu.force.follow",
                           "menu.hooks.install", "menu.hooks.update", "menu.hooks.remove",
                           "menu.hooks.hint.claude", "menu.hooks.hint.codex", "menu.hooks.hint.remove",
                           "menu.hooks.error.unreadable", "menu.hooks.error.malformed",
                           "menu.hooks.error.noDirectory", "menu.hooks.error.changedUnderneath",
                           "menu.hooks.error.unwritable"]

    /// A refused write's line. A switch, not a string built from the case,
    /// so a new failure does not compile until it has a line.
    nonisolated static func failureKey(_ failure: HookSettings.Failure) -> String {
        switch failure {
        case .unreadable: return "menu.hooks.error.unreadable"
        case .malformed: return "menu.hooks.error.malformed"
        case .noDirectory: return "menu.hooks.error.noDirectory"
        case .changedUnderneath: return "menu.hooks.error.changedUnderneath"
        case .unwritable: return "menu.hooks.error.unwritable"
        }
    }

    /// What a hook entry does, fixed when the menu is built: the click does
    /// what its title said, even if the file changed while the menu was open.
    struct HookEntry {
        let source: AgentSource
        let remove: Bool
    }

    /// The one menu: *Edge ▸ Right / Left*, the current one marked, one
    /// entry per agent that is there, and *Quit*. The tray's (`diagnostics`)
    /// adds *Force state ▸*.
    func makeMenu(diagnostics: Bool, in lang: String = L10n.language) -> NSMenu {
        let menu = NSMenu()
        fill(menu, diagnostics: diagnostics, in: lang)
        return menu
    }

    private func fill(_ menu: NSMenu, diagnostics: Bool, in lang: String) {
        let edges = NSMenu()
        for (edge, key) in [(BarPanel.Edge.right, "menu.edge.right"), (.left, "menu.edge.left")] {
            let entry = edges.addItem(withTitle: L10n.t(key, in: lang),
                                      action: #selector(chooseEdge(_:)), keyEquivalent: "")
            entry.representedObject = Self.storedValue(edge)
            entry.state = barState.edge == edge ? .on : .off
            entry.target = self
        }
        let edgeItem = menu.addItem(withTitle: L10n.t("menu.edge", in: lang), action: nil,
                                    keyEquivalent: "")
        edgeItem.submenu = edges

        if diagnostics {
            // Forcing a phase so it can be looked at: `waiting` and `failed`
            // need a live session to be seen otherwise.
            let forced = NSMenu()
            let follow = forced.addItem(withTitle: L10n.t("menu.force.follow", in: lang),
                                        action: #selector(clearOverride), keyEquivalent: "")
            follow.target = self
            forced.addItem(.separator())
            let locale = Locale(identifier: lang)
            for phase in Phase.allCases {
                let name = L10n.t(StatusLine.statusKey(phase: phase, waitKind: nil), in: lang)
                let entry = forced.addItem(withTitle: name.prefix(1).uppercased(with: locale) + name.dropFirst(),
                                           action: #selector(setOverride(_:)), keyEquivalent: "")
                entry.representedObject = phase.rawValue
                entry.target = self
            }
            let forcedItem = menu.addItem(withTitle: L10n.t("menu.force", in: lang), action: nil,
                                          keyEquivalent: "")
            forcedItem.submenu = forced
        }

        addHookEntries(to: menu, in: lang)

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L10n.t("menu.quit", in: lang),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

    }

    /// One entry per agent whose directory exists, titled by what the file
    /// holds now: install, update or remove. The file is read each time a
    /// menu is built, never cached and never written here. A directory that
    /// is not there means the agent is not installed; no entry offers to
    /// create it.
    private func addHookEntries(to menu: NSMenu, in lang: String) {
        guard let home else { return }
        let sources = AgentSource.allCases.filter { source in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: source.configDirectory(home: home).path,
                                                  isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !sources.isEmpty else { return }
        menu.addItem(.separator())
        for source in sources {
            // A file that cannot be read offers the install: the click then
            // says why it cannot happen, in the line below.
            let state = (try? HookSettings.state(at: source.settingsFile(home: home), for: source)) ?? .missing
            let key: String
            switch state {
            case .missing: key = "menu.hooks.install"
            case .outdated: key = "menu.hooks.update"
            case .current: key = "menu.hooks.remove"
            }
            let name = L10n.t("source.\(source.rawValue)", in: lang)
            let entry = menu.addItem(withTitle: L10n.t(key, ["source": name], in: lang),
                                     action: #selector(changeHooks(_:)), keyEquivalent: "")
            entry.representedObject = HookEntry(source: source, remove: state == .current)
            entry.target = self
            // What the agent needs after the write. Removing only matters to
            // Codex, whose trust is keyed by a group's index.
            switch (state, source) {
            case (.current, .claude): break
            case (.current, .codex): entry.toolTip = L10n.t("menu.hooks.hint.remove", in: lang)
            case (_, .claude): entry.toolTip = L10n.t("menu.hooks.hint.claude", in: lang)
            case (_, .codex): entry.toolTip = L10n.t("menu.hooks.hint.codex", in: lang)
            }
            if let failure = hookFailures[source] {
                let line = menu.addItem(withTitle: L10n.t(Self.failureKey(failure), in: lang),
                                        action: nil, keyEquivalent: "")
                line.isEnabled = false
                line.indentationLevel = 1
            }
        }
    }

    /// A hook entry: the writer, then the outcome kept for the next menu —
    /// no dialog, no success message; the title changing is the answer.
    /// Like the edge, the open list closes and nothing is activated.
    @objc func changeHooks(_ sender: NSMenuItem) {
        guard let home, let entry = sender.representedObject as? HookEntry else { return }
        let file = entry.source.settingsFile(home: home)
        do {
            if entry.remove {
                try HookSettings.remove(at: file, for: entry.source)
            } else {
                try HookSettings.install(at: file, for: entry.source)
            }
            hookFailures[entry.source] = nil
        } catch {
            hookFailures[entry.source] = error as? HookSettings.Failure ?? .unwritable
        }
        hover.closeNow()
        // The intent may already have believed the bar closed.
        if barState.isOpen { closeBar() }
    }

    /// A right click (or ctrl-click) on the bar, in the content view's
    /// (flipped) coordinates: the menu over the mascot, nothing anywhere
    /// else. A left click on the mascot stays reserved.
    func menu(at point: CGPoint) -> NSMenu? {
        guard let panel, let bounds = panel.contentView?.bounds,
              Self.isOverMascot(fromEdge: panel.edge.inset(of: point.x, in: bounds),
                                fromTop: point.y - bounds.minY) else { return nil }
        return makeMenu(diagnostics: false)
    }

    /// Room around the mascot a right click still counts on.
    static let mascotHitSlack: CGFloat = 4

    /// Whether a point, measured from the docked edge and the window's top,
    /// is on the mascot: the closed bar's width, and the mascot's height
    /// with a little room.
    static func isOverMascot(fromEdge x: CGFloat, fromTop y: CGFloat) -> Bool {
        x >= 0 && x <= barWidth
            && y >= mascotTopInset - mascotHitSlack
            && y <= mascotTopInset + mascotSize + mascotHitSlack
    }

    /// The edge entry: stored, then applied at once. Stored even under
    /// `EVLAT_EDGE`, which only overrides the launch. Activates nothing.
    @objc private func chooseEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let edge: BarPanel.Edge = raw == "left" ? .left : .right
        defaults?.set(Self.storedValue(edge), forKey: Self.edgeKey)
        dock(edge)
    }

    @objc private func clearOverride() { mascot.override = nil }

    @objc private func setOverride(_ sender: NSMenuItem) {
        mascot.override = (sender.representedObject as? String).flatMap(Phase.init(rawValue:))
    }
}

/// Whether the bar's body is drawn open. Its own model so the one view that
/// reads it — `BarBody` — is the only one rebuilt when it flips.
@MainActor
final class BarState: ObservableObject {
    /// The edge the body is drawn against. Written by `installPanel` before
    /// the first frame and by `dock` after it, nowhere else.
    @Published var edge: BarPanel.Edge = .right
    @Published var isOpen = false
    /// How far the body opens: as wide as the names or the summary line
    /// need, within `SessionColumn`'s bounds (`SessionColumn.openWidth(rows:)`).
    @Published var openWidth = SessionColumn.openWidth(namesWidth: 0)
    /// How long the closed body is drawn along the edge, from the head. The
    /// window is longer; this is the part that is bar.
    @Published var length = AppController.barLength(slots: 0)
    /// How long the open body is: the whole list up to seven and a half rows
    /// and the summary. Kept beside `length` the way `openWidth` is kept
    /// beside the closed width, so `refresh` never writes the open body back
    /// to the closed length.
    @Published var openLength = AppController.openLength(rows: 0)
    /// Where the usage block's hairline is: under the summary, or under the
    /// mascot with no session. Written by `refresh` with the lengths.
    @Published var usageTop = AppController.usageTop(rows: 0)
    /// The length the body is drawn at now.
    var drawnLength: CGFloat { isOpen ? openLength : length }
    /// The session whose card is up, by entity; `nil`: no card.
    @Published var selected: String?
    /// The row under the cursor on the open list, marked before its card
    /// comes up. Written only when it changes.
    @Published var hovered: String?
    /// Its row's slot, which the card hangs from. Follows the row as the
    /// column reorders.
    @Published var selectedSlot: Int?
}

/// The bar's colours: codenotch's. The body is pure, opaque black so it reads
/// as the bezel rather than something laid over the desktop; text is white,
/// and secondary text the reference frame's `#808080`.
enum BarPalette {
    static let body = Color.black
    static let textPrimary = Color.white
    static let textSecondary = Color(.sRGB, red: 128 / 255, green: 128 / 255, blue: 128 / 255)
}

/// The bar's motion, in one place.
enum BarMotion {
    /// How long the body takes to open or close. The window waits this long
    /// before it shrinks behind a closing body.
    static let bodyDuration: TimeInterval = 0.24
    static let body = Animation.smooth(duration: bodyDuration)
    /// Names arrive once the body has made some room, and leave at once.
    static let namesIn = Animation.easeOut(duration: 0.18).delay(0.07)
    static let namesOut = Animation.easeIn(duration: 0.1)
    /// The body lengthening or shortening as sessions come and go: the curve
    /// the window's own resize used to run on, now drawn.
    static let length = Animation.easeOut(duration: 0.22)
    /// The card comes out of the bar's side: a few points of travel toward
    /// the screen, a touch of growth and a fade on one soft curve. A plain
    /// 0.1 s fade made it pop in (user's feedback, `005`).
    static let cardIn = Animation.smooth(duration: 0.26)
    /// It leaves quicker than it came, and more quietly.
    static let cardOut = Animation.easeIn(duration: 0.14)
    /// What the card says changing from one session to the next.
    static let cardContent = Animation.easeOut(duration: 0.16)
    static let cardTravel: CGFloat = 8

    /// The card's arrival and departure. Attached to the card itself, not to
    /// its placing, so the growth is anchored on the card's own edge beside
    /// the bar rather than on the screen edge, and it travels out of the bar
    /// — leftward from a right bar, rightward from a left one.
    static func cardTransition(edge: BarPanel.Edge) -> AnyTransition {
        let anchor: UnitPoint = edge.isLeft ? .leading : .trailing
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.96, anchor: anchor))
                .combined(with: .offset(x: edge.isLeft ? -cardTravel : cardTravel))
                .animation(cardIn),
            removal: .opacity
                .combined(with: .scale(scale: 0.98, anchor: anchor))
                .animation(cardOut))
    }
}

/// The bar's body: the shape, the mascot at its head, the session rings
/// beneath it, and — while the bar is open — their names.
///
/// **Everything is laid out from the screen edge.** The shape, the mascot and
/// the rings hang off the docked side — trailing on the right, leading on the
/// left — so the window growing or shrinking moves none of them; opening is
/// the shape's inner edge travelling into the screen and the names fading in.
/// The mascot and the column observe their own models, so a gaze write
/// re-evaluates the mascot alone and a beat the rings alone.
///
/// The left is the right's mirror by alignments and the sign of `x`, all
/// read off one `isLeft` — not `layoutDirection`, which would also reverse
/// the card's text and the name's raised number, and not a flipped scale,
/// which would mirror the text and the mascot's gaze.
struct BarBody: View {
    let mascot: MascotModel
    let rows: SessionRowsModel
    @ObservedObject var state: BarState
    /// Handed down, not observed: only the list and the card's placing move
    /// with a scroll.
    var scroll = ListScroll()
    var detail = DetailModel()
    /// Handed down, not observed: only the block reads it, and only while
    /// the bar is open.
    var usage = UsageBlockModel()
    /// The card's drawn rectangle as it lays out, `nil` when it goes: the
    /// panel's second hover area is held to it.
    var onCardFrame: (CGRect?) -> Void = { _ in }
    /// `[Go to session]`'s drawn rectangle, for the click.
    var onGoButtonFrame: (CGRect?) -> Void = { _ in }
    /// The card's top above its row's ring: its header lines up with the
    /// row's name.
    static let cardLead: CGFloat = 16

    /// Level with the row, but never so low that the tallest card would leave
    /// the window: the top is held at a **constant** floor, not at the card's
    /// measured height — that moves with every tool event and the top would
    /// jump. The held card still spans the lower rows. A scrolled list takes
    /// its row up by `offset`, and the card with it, point for point.
    static func cardTop(slot: Int, offset: CGFloat = 0) -> CGFloat {
        min(max(0, AppController.slotTop(slot) - offset - cardLead), cardTopLimit)
    }

    /// The fourth slot's ring, where `006` put the floor. The window grew
    /// for the usage block (`009`); the floor did not, so a card still
    /// hangs where it did.
    static var cardTopLimit: CGFloat {
        AppController.slotTop(SessionRowsModel.slotCount - 1)
    }

    private var isLeft: Bool { state.edge.isLeft }
    /// The docked side's top corner: where the body, the mascot and the
    /// column hang from.
    private var head: Alignment { isLeft ? .topLeading : .topTrailing }

    var body: some View {
        ZStack(alignment: head) {
            // Top-aligned in the envelope: the far end moves, the head stays.
            // The shadow and the inner edge are the shape's, so they shorten
            // with it.
            shapeLayer
                // Opening widens and lengthens it on one curve: the change of
                // `isOpen` is the innermost, so it wins over the length's.
                .frame(width: state.isOpen ? state.openWidth : AppController.barWidth,
                       height: state.drawnLength)
                .animation(BarMotion.body, value: state.isOpen)
                .animation(BarMotion.body, value: state.openWidth)
                .animation(BarMotion.length, value: state.length)
                .animation(BarMotion.length, value: state.openLength)
            card
            // The mascot is the head of the bar; the rings line up beneath,
            // their visible area starting half a gap above the first ring.
            MascotView(model: mascot, size: AppController.mascotSize)
                .frame(width: AppController.barWidth)
                .padding(.top, AppController.mascotTopInset)
            SessionColumn(model: rows, scroll: scroll, edge: state.edge, showsNames: state.isOpen,
                          selected: state.selected, hovered: state.hovered,
                          openWidth: state.openWidth)
                .padding(.top, AppController.listTop)
            usageBlock
        }
        // Pinned to the screen edge and the head. What is left on the other
        // side is the shadow's room, the open body's and the card's; what is
        // left below is the card's.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: head)
    }

    /// Beside the open body, `detailCardGap` from its inner edge, level with
    /// the selected row. The window already has room for it at every slot
    /// (`AppController.envelopeSize`), so it is never pushed around.
    @ViewBuilder private var card: some View {
        if state.isOpen, state.selected != nil, let slot = state.selectedSlot {
            DetailCard(model: detail, onButtonFrame: onGoButtonFrame)
                .animation(BarMotion.cardContent, value: state.selected)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    onCardFrame(rect)
                }
                .onDisappear { onCardFrame(nil) }
                .transition(BarMotion.cardTransition(edge: state.edge))
                .modifier(CardPlacing(scroll: scroll, slot: slot))
                .padding(isLeft ? .leading : .trailing, state.openWidth + AppController.detailCardGap)
                .animation(BarMotion.length, value: slot)
        }
    }

    /// Under the summary, outside the scrolled list: it stays put while the
    /// list moves. In the tree only while open, so its model and its minute
    /// tick are not observed on the closed bar; it comes and goes with the
    /// names. It follows the list's length on the body's own curve.
    @ViewBuilder private var usageBlock: some View {
        if state.isOpen {
            UsageBlock(model: usage, edge: state.edge, width: state.openWidth)
                .transition(.asymmetric(insertion: .opacity.animation(BarMotion.namesIn),
                                        removal: .opacity.animation(BarMotion.namesOut)))
                .padding(.top, state.usageTop)
                .animation(BarMotion.length, value: state.usageTop)
        }
    }

    /// The card's top, level with its row wherever the list is scrolled. A
    /// modifier of its own so a scroll re-evaluates this padding and not the
    /// body, the mascot or the card's content. The offset is written without
    /// an animation and the spring above is keyed on the slot alone, so the
    /// card follows the finger directly.
    private struct CardPlacing: ViewModifier {
        @ObservedObject var scroll: ListScroll
        let slot: Int

        func body(content: Content) -> some View {
            content.padding(.top, BarBody.cardTop(slot: slot, offset: scroll.offset))
        }
    }

    private var shapeLayer: some View {
        let shape = BarShape(corner: AppController.barCorner,
                             flare: AppController.barFlare, edge: state.edge)
        return shape
            .fill(BarPalette.body)
            // A thin inner edge separates the body from a dark wall behind it
            // and makes the flare's curve readable. `outline` drops the segment
            // that lies on the screen edge: stroking the closed path put a
            // hairline on the screen's outermost pixel column.
            .overlay(shape.outline.stroke(Color.white.opacity(0.10), lineWidth: 1))
            // The shadow deepens the curve; it is what sells "growing out of the
            // bezel". It needs the gutter above to render at all.
            // Cast into the screen, away from the docked edge.
            .shadow(color: .black.opacity(0.35), radius: 10, x: isLeft ? 3 : -3, y: 0)
    }
}
