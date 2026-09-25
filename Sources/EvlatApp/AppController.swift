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
    /// The same for the status line relay's entry.
    private var usageFailure: SettingsFile.Failure?
    /// The same for `~/.local/bin/evlat` (`014`).
    private(set) var commandLinkFailure: CommandLinkWriter.Failure?
    /// A refused login item change (`SMAppService`'s error is not kept: the
    /// row says it did not happen, System Settings says why).
    private(set) var loginItemFailed = false
    /// "Open at login". Handed in like `defaults`: only `launch()` gives the
    /// real service, and an isolated launch an in-memory one
    /// (`LoginItem.service(environment:)`). `nil` — every test that does not
    /// hand one — has no row and never calls it.
    let loginItem: LoginItem?
    /// This process's binary, what `~/.local/bin/evlat` points at. A test
    /// points it at a bundle of its own.
    var executable: URL? = Bundle.main.executableURL
    public let registry = Registry()
    /// Finds `claude` for the chats; its login `PATH` is also the command
    /// link row's (`014`). Nothing runs until a chat or the row asks.
    let claudeLocator = ClaudeLocator()
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
    /// Outside programs' rows, as `POST /signal` left them (`012`). Stamped
    /// with this controller's clock, like the usage windows: a row's life is
    /// read against it.
    lazy var signals = SignalsProvider(now: { [unowned self] in
        MainActor.assumeIsolated { self.now() }
    })
    private var hookListener: HookListener?
    /// The key file this process wrote, removed on quit (`012` kapı).
    private let signalKeyWritten = SignalKey.Written()
    /// The chats (`011`) and their `claude -p` turns; `nil` until launch.
    /// Registered in `registry` as the `evlat` provider. Internal so a test
    /// hands its own store (a fake `claude`, a temporary root).
    var chats: ChatStore?
    /// The balloon (`011/phase-2`): what it draws and its window, built on
    /// first use.
    let chatModel = ChatModel()
    private(set) var chatPanel: ChatPanel?
    /// Is the balloon on screen? The one place that says so: hover and the
    /// toggles read it.
    private(set) var isChatOpen = false
    /// The chat the balloon speaks for; made by the first prompt, so an
    /// opened and closed balloon leaves no row.
    private(set) var currentChat: String?
    /// A folder picked from the balloon's label before the first prompt
    /// (`011/phase-4`); it wins over the one the files suggest.
    private(set) var chosenFolder: String?
    /// The folder or save panel is up: the balloon is ordered out for it, and its
    /// losing the keyboard to the panel is not a close.
    private var choosingInPanel = false
    /// The balloon's shortcut (`HotKey`, ⇧⌘Space unless changed); `nil`
    /// until launch — a test hands a fake, and a controller without one
    /// registers nothing.
    var hotKey: HotKeyRegistration?
    /// The one shortcut recorder: Settings → Chat's row (`014`, Karar 7).
    /// While it records nothing is registered (`applyHotKey`).
    private(set) lazy var hotKeyRecorder: HotKeyRecorder = makeHotKeyRecorder()
    /// The system's own shortcuts, read as a recording starts; a test hands
    /// its own table.
    var systemHotKeys: () -> SystemHotKeys = SystemHotKeys.current
    /// The last registration's answer while the shortcut is on; `nil` when
    /// off or never tried. A failure is the menu's dim line.
    private(set) var hotKeyStatus: OSStatus?
    /// The remote machines' listeners and `ssh` processes; `nil` until
    /// launch. Its providers are registered in `registry` by it.
    private(set) var remote: RemoteTunnels?
    /// The machines came from `EVLAT_MACHINES` (or none, because of
    /// `EVLAT_PORT`): then adding or removing one is not written back.
    private var remoteFromEnvironment = true
    /// Each machine's `/signal` key (`013`), by machine id. Written back to
    /// `RemoteMachine.signalKeysStorageKey` under the list's own rule: only
    /// a stored list's, never the environment's.
    private var remoteSignalKeys: [String: String] = [:]
    /// The `ssh` the tunnels run, which the window's installer runs too.
    private var remoteSSHPath = AppController.sshPath()
    /// The settings window (`014`, R6), once opened, and its model.
    private(set) var settingsWindow: AppWindow?
    private(set) var settings: SettingsModel?
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

    /// The open body's width: the names' (a remote row's with its machine),
    /// the summary's or the block's (a machine's heading included),
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
    /// added is transparent and hangs below the head, like the rest. `010`
    /// grew it by three lines more, for one remote machine's group.
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

    /// `excluding` names the sessions that are Evlat's own chats (`011`):
    /// their `claude -p` turns write records too.
    nonisolated public static func makeSessionsProvider(
        excluding: @escaping () -> Set<String> = { [] }
    ) -> SessionsProvider {
        SessionsProvider(directory: sessionsDirectory(), platform: darwinPlatform, excluding: excluding)
    }

    /// Where the chats are kept (`ChatStore.root`) — only with a home: a
    /// controller built without one (every test) never touches disk, the
    /// rule `hookFailures`' writer follows.
    nonisolated static func chatRoot(
        home: URL?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let home else { return nil }
        return ChatStore.root(environment: environment, home: home)
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

    /// The setup was shown (`014`, R9): set the first time it opens, so it
    /// opens by itself once. Written only by a process that is not isolated.
    nonisolated static let setupSeenKey = "setup.seen"

    /// Whether the setup opens by itself at this launch (`SetupTrigger`):
    /// storage and a home, never shown, no edge ever stored, no agent's
    /// hooks installed (or old), not isolated. Reads, writes nothing.
    func shouldOpenSetup(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let states = home.map { home in
            Self.presentSources(home: home).map { source in
                (try? HookSettings.state(at: source.settingsFile(home: home), for: source)) ?? .missing
            }
        } ?? []
        return SetupTrigger.shouldOpen(hasStorage: defaults != nil && home != nil,
                                       seen: defaults?.bool(forKey: Self.setupSeenKey) ?? false,
                                       hasStoredEdge: defaults?.object(forKey: Self.edgeKey) != nil,
                                       hookStates: states, environment: environment)
    }

    /// Marks the setup shown; an isolated process keeps nothing.
    func markSetupSeen(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !Isolation.isIsolated(environment) else { return }
        defaults?.set(true, forKey: Self.setupSeenKey)
    }

    /// The agents whose directory exists under `home`: an agent that is not
    /// there has no entry and no row (`008`).
    nonisolated static func presentSources(home: URL) -> [AgentSource] {
        AgentSource.allCases.filter { source in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: source.configDirectory(home: home).path,
                                                  isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// The edge the user chose, `right` or `left`; anything else — nothing
    /// stored, `top`, a number — is `nil`, and the caller falls back to the
    /// right. Reading writes nothing: an unknown value stays as it is, and
    /// `setEdge` is the only writer.
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

    /// Whether `argv[1]` asks for the diagnostics (`--list` or `--capture`).
    /// Only the first argument: anything later belongs to whatever else the
    /// arguments say (`012`'s panel finding — `Evlat signal x -- cmd --capture 5`
    /// must not print a capture).
    nonisolated public static func isDiagnostics(_ arguments: [String]) -> Bool {
        LaunchMode.of(arguments) == .diagnostics
    }

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
        printRemoteMachines()
        exit(0)
    }

    /// The configured machines. This process opens no tunnel: the running
    /// app holds the server's 48151, and a second `ssh` here would race it
    /// for the port — the state is the app's, on its stderr
    /// (`Evlat: tunnel …`).
    private nonisolated static func printRemoteMachines() {
        let environment = ProcessInfo.processInfo.environment
        let configuration = remoteConfiguration(defaults: .standard, environment: environment)
        for line in remoteMachineLines(configuration, environment: environment) { print(line) }
    }

    nonisolated static func remoteMachineLines(_ configuration: RemoteMachine.Configuration,
                                               environment: [String: String]) -> [String] {
        var lines: [String] = []
        let origin = configuration.fromEnvironment ? "EVLAT_MACHINES" : RemoteMachine.storageKey
        if configuration.machines.isEmpty {
            let port = environment["EVLAT_PORT"].map { !$0.isEmpty } ?? false
            let reason = environment["EVLAT_MACHINES"] == nil && port
                ? " (EVLAT_PORT is set without EVLAT_MACHINES: no tunnel is opened)" : ""
            lines.append("remote machines: none\(reason)")
        } else {
            lines.append("remote machines: \(configuration.machines.count) (from \(origin))")
            for machine in configuration.machines {
                lines.append("  machine  \(machine.name)  → \(machine.target)"
                    + "  ·  tunnel: held by the running app, see its stderr")
            }
        }
        for rejected in configuration.rejected {
            lines.append("  EVLAT_MACHINES entry \(rejected) ignored: not a usable ssh target")
        }
        return lines
    }

    /// One `--list` row. Separate so its privacy has a test: the row names the
    /// session and its phase, and **never** its `activity` — the tool, the
    /// command and the last reply stay on the card. `--list` output is what
    /// ends up pasted into bug reports. The terminal is named, the pid is not.
    nonisolated static func listLine(_ signal: Signal, host: SessionHost? = nil) -> String {
        let raw = signal.rawStatus.map { " (raw: \($0))" } ?? ""
        let phase = signal.phase.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        let terminal = host.map { "  → \($0.diagnostic)" } ?? ""
        let machine = signal.machine.map { "  @ \($0.name)\($0.reachable ? "" : " (not reachable)")" } ?? ""
        // An outside job's `detail` is its sender's free text, not a
        // source's diagnostic: the line names who sent it instead.
        let origin = RowTraits.of(signal.kind).tag == .sender
            ? "signal \(signal.sender ?? "-")" : signal.detail ?? ""
        return "  \(phase) \(signal.label)\(raw)  ← \(origin)\(terminal)\(machine)"
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
            printSignalEndpoint(port: choice.port)
            return
        }

        // Line buffering, because stdout is fully buffered whenever it is not a
        // terminal: under `… --capture 135 | tee log` nothing would appear
        // until the process exited, and a Ctrl-C inside the window would lose
        // every line — the exact failure streaming was chosen to avoid.
        setvbuf(stdout, nil, _IOLBF, 0)
        let diagnostics = HookDiagnostics()
        // The capture holds the port, so it is the one that writes the key:
        // an outside program's `/signal` is printed here like a hook.
        let written = SignalKey.Written()
        let listener = HookListener(port: choice.port,
                                    signalKey: signalKeyWriter(home: resolvedHome(), written: written)) { delivery in
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
            case .permission(let request):
                // No chat runs in a capture; the listener has already
                // refused it (nobody here answers).
                print("permission request refused: \(request.tool)")
            case .signal(let report):
                print(signalCaptureLine(report))
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
        written.remove()
        // Events cross on `DispatchQueue.main.async`, so the ones handed over
        // just before the deadline have not run yet. Without this drain they
        // are neither printed nor counted, and the totals a measurement is
        // read from would be short by the last few.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        diagnostics.summary.forEach { print($0) }
    }

    /// One `--capture` line for a `/signal`: its id, phase and ttl. The
    /// `detail` is not printed, nor the label — the `listLine` rule: what a
    /// program says about its work stays on the bar.
    nonisolated static func signalCaptureLine(_ report: SignalReport) -> String {
        let phase = report.ttl > 0 ? (report.word?.rawValue ?? "?") : "clear"
        return "  signal   \(report.id)  \(phase)  ttl \(report.ttl)"
            + (report.sender.map { "  from \($0)" } ?? "")
    }

    /// `--list`'s word on `/signal`: the key file, and a keyed probe that
    /// clears an id nobody uses (`ttl: 0`), so it leaves no row.
    private nonisolated static func printSignalEndpoint(port: UInt16) {
        let environment = ProcessInfo.processInfo.environment
        guard let url = SignalKey.location(port: port, environment: environment) else {
            print("signal key: none (EVLAT_PORT is set without EVLAT_HOME: an isolated process has no key)")
            return
        }
        let key = SignalKey.read(from: url)
        print("signal key: \(url.path)\(key == nil ? " (absent)" : "")")
        print("signal: \(signalProbeText(key == nil ? nil : probeSignalEndpoint(port: port, key: key!)))")
    }

    /// What a probe's answer means. `nil` is "there was no key to send".
    nonisolated static func signalProbeText(_ answer: SignalProbe?) -> String {
        switch answer {
        case nil: return "no key file"
        case .status(200)?: return "ok"
        case .status(403)?: return "key mismatch (403)"
        case .status(404)?: return "no /signal route (404: v1 or older v2)"
        case .status(let code)?: return "answered \(code)"
        case .notRunning?: return "not running"
        case .failed(let reason)?: return "did not answer (\(reason))"
        }
    }

    enum SignalProbe: Equatable {
        case status(Int)
        case notRunning
        case failed(String)
    }

    /// `POST /signal` with the key, as `probeHookEndpoint` does `/health`:
    /// the command's own client (`SignalClient`), so the probe and the
    /// command cannot disagree about what a post looks like.
    nonisolated static func probeSignalEndpoint(port: UInt16, key: String,
                                                timeout: TimeInterval = 1) -> SignalProbe {
        let probe = SignalCommand.Post(id: "_probe", word: nil, ttl: 0)
        switch SignalClient.send(probe.body, port: port, key: key, timeout: timeout) {
        case .status(let code, _): return .status(code)
        case .notRunning: return .notRunning
        case .failed(let reason): return .failed(reason)
        }
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
        // Invalidated when done: a session holds its delegate queue until then.
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: url) { data, _, error in
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

    public convenience init(defaults: UserDefaults? = nil, home: URL? = nil) {
        self.init(defaults: defaults, home: home, loginItem: nil)
    }

    init(defaults: UserDefaults?, home: URL?, loginItem: LoginItem?) {
        self.defaults = defaults
        self.home = home
        self.loginItem = loginItem
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: no Dock icon, no Cmd-Tab entry. The bar should behave
        // like part of the system rather than like an app.
        NSApp.setActivationPolicy(.accessory)
        // Before the record provider: a chat's `claude -p` turn writes a
        // session record, and the chat's sessions are left out of it.
        let chats = ChatStore(root: Self.chatRoot(home: home), platform: Self.darwinPlatform,
                              locator: claudeLocator,
                              now: { [unowned self] in MainActor.assumeIsolated { self.now() } },
                              trash: ChatStore.trash(environment: ProcessInfo.processInfo.environment),
                              defaultMode: { [unowned self] in MainActor.assumeIsolated { self.defaultMode } },
                              onChange: { [weak self] in MainActor.assumeIsolated { self?.scheduleRefresh() } })
        self.chats = chats
        registry.register(Self.makeSessionsProvider(excluding: { [weak chats] in chats?.sessionIDs ?? [] }))
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
        registry.register(chats.provider)
        // Memory only; its rows come from the listener below.
        registry.register(signals)
        startHookListener()
        startRemoteTunnels()
        installStatusItem()
        // Here and nowhere else: `installPanel` runs in every test, and a
        // test must never take the user's shortcut.
        let hotKey = HotKey()
        hotKey.onPress = { [weak self] in MainActor.assumeIsolated { self?.hotKeyPressed() } }
        self.hotKey = hotKey
        applyHotKey()

        // The environment over the stored choice, the right over nothing.
        // Read here, never written back: only `setEdge` writes.
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
        if let section = Self.forcedSettings() { openSettings(section: section) }
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

        panel.onPointer = { [weak self] pointer in self?.pointer(pointer) }

        // Resolution changes, an unplugged display, or the Dock moving to the
        // right edge all change `visibleFrame`. Without this the bar keeps a
        // stale origin: it detaches from the edge — the whole premise of the
        // flare — or lands on coordinates no screen has and becomes
        // unreachable. `.canJoinAllSpaces` covers space switches, not geometry.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                // The balloon is placed once, beside the mascot; a bar that
                // moves under it would leave it pointing at nothing.
                self?.closeChat()
                panel?.reposition()
            }
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
        panel.onDrag = { [weak self] drag in
            self?.drag(drag) ?? false
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
        closeChat()
        hover.closeNow()
        // The intent may already have believed the bar closed.
        if barState.isOpen { closeBar() }
        panel?.edge = edge
        if barState.edge != edge { barState.edge = edge }
    }

    /// The cursor over the bar. While the balloon is open hover is not told:
    /// the balloon is the one thing talking, and an intent that believed
    /// the bar open while it stayed closed would ignore the next enter.
    /// The eyes still follow the cursor.
    func pointer(_ pointer: BarHostingView.Pointer) {
        switch pointer {
        case .entered:
            guard !isChatOpen else { return }
            hover.pointerEntered()
        case .exited:
            // Off the bar is off every row: a switch still pending
            // would otherwise select after the cursor has gone.
            rowSwitch.cancel()
            if barState.hovered != nil { barState.hovered = nil }
            hover.pointerExited()
        case .moved(let point):
            gaze?.observe(point)
            guard !isChatOpen else { return }
            // A move is only reported inside the bar, so it also says
            // "still here" — which is what cancels a close pending from a
            // missed exit/enter pair.
            hover.pointerEntered()
            pointerMoved(point)
        }
    }

    // MARK: - The balloon

    /// The mascot's left click and the shortcut.
    func toggleChat() {
        isChatOpen ? closeChat() : openChat()
    }

    /// Out of the mascot, with the keyboard, Evlat still in the background
    /// (`ChatPanel`). The open list and its card close first: the balloon is
    /// the one thing talking.
    ///
    /// Which chat it speaks for (`011/phase-5`): `chat` when one is asked
    /// for (`[Back to chat]`); none when `fresh` (files dropped on a closed
    /// balloon start their own); else a chat still on the bar — running
    /// first, then the latest unseen end — else none, and the empty
    /// balloon shows the history. Old chats are pruned first.
    func openChat(chat requested: String? = nil, fresh: Bool = false) {
        guard let bar = panel else { return }
        if isChatOpen {
            // Already out: only a chat asked for changes what it shows.
            if let requested { show(requested) }
            return
        }
        chats?.prune()
        if let requested, chats?.open(requested) == true {
            currentChat = requested
        } else {
            currentChat = fresh ? nil : openingChat()
        }
        hover.closeNow()
        // The cursor that came to click the mascot has already asked for
        // the bar to open; `closeNow` leaves a pending opening alone, and
        // a leave on a closed bar is what drops it (seen by eye: the list
        // opened under a fresh balloon).
        hover.pointerExited()
        // The intent may already have believed the bar closed.
        if barState.isOpen { closeBar() }
        let balloon = chatPanel ?? makeChatPanel()
        isChatOpen = true
        if chatModel.edge != bar.edge { chatModel.edge = bar.edge }
        syncChat()
        refreshFolder()
        // Asked each time: `claude` may have been installed since. Known at
        // once after the first find (or with `EVLAT_CLAUDE`).
        chats?.locateClaude { [weak self] found in
            guard let self, self.chatModel.claudeMissing == found else { return }
            self.chatModel.claudeMissing = !found
        }
        chatModel.opened()
        // A short fade in: it comes out of the mascot rather than popping.
        // Leaving is at once — Esc should feel instant.
        balloon.alphaValue = 0
        balloon.present(beside: bar, edge: bar.edge)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            balloon.animator().alphaValue = 1
        }
    }

    /// A chat still on the bar, for a balloon opened with none asked for:
    /// the one it showed last, if it still has a row; else a running one;
    /// else the latest end nobody has seen. `nil` when the bar has none.
    private func openingChat() -> String? {
        guard let chats else { return nil }
        let now = now()
        if let id = currentChat, chats.chat(id)?.signal(at: now) != nil { return id }
        return chats.provider.chats.values
            .filter { $0.signal(at: now) != nil }
            .max { a, b in
                if a.isRunning != b.isRunning { return b.isRunning }
                return (a.since ?? .distantPast) < (b.since ?? .distantPast)
            }?.id
    }

    /// The balloon switches to a chat: from the history, or `[Back to chat]`
    /// while it is out. What was typed for another chat stays in the line.
    func show(_ id: String?) {
        if let id, chats?.open(id) != true { return }
        currentChat = id
        chosenFolder = nil
        syncChat()
        refreshFolder()
        chatModel.opened()
    }

    /// Ordered out. Nothing is handed back: the app in front never lost
    /// being the active one, so the keyboard is simply its again.
    func closeChat() {
        guard isChatOpen else { return }
        isChatOpen = false
        chatPanel?.orderOut(nil)
    }

    private func makeChatPanel() -> ChatPanel {
        let balloon = ChatPanel(content: ChatView(model: chatModel))
        balloon.onClose = { [weak self] in
            guard let self, !self.choosingInPanel else { return }
            self.closeChat()
        }
        balloon.onFiles = { [weak self] items in self?.attach(items) }
        balloon.onDropTarget = { [weak self] over in
            guard let self, self.chatModel.dropTargeted != over else { return }
            self.chatModel.dropTargeted = over
        }
        chatModel.onAttachmentsChange = { [weak self] in self?.refreshFolder() }
        chatModel.onFolder = { [weak self] in self?.folderTapped() }
        chatModel.onSend = { [weak self] text in self?.send(text) }
        chatModel.onAnswer = { [weak self] request, decision in
            self?.chats?.perform(.answer(request: request, decision: decision))
            self?.syncChat()
        }
        chatModel.onStop = { [weak self] in
            guard let self, let id = self.currentChat else { return }
            self.chats?.perform(.stop(chat: id))
            self.syncChat()
        }
        chatModel.onCopy = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        // The browser comes forward and the balloon, losing the keyboard,
        // closes: Evlat activates nothing itself.
        chatModel.onOpenLink = { url in NSWorkspace.shared.open(url) }
        chatModel.onMode = { [weak self] in self?.showModes() }
        chatModel.onRetry = { [weak self] line in self?.retryAsking(line) }
        chatModel.onNew = { [weak self] in self?.show(nil) }
        chatModel.onOpen = { [weak self] id in self?.show(id) }
        chatModel.onPin = { [weak self] id, pinned in
            self?.chats?.setPinned(id, pinned)
            self?.syncChat()
        }
        chatModel.onRemove = { [weak self] id in
            self?.chats?.remove(id)
            self?.forgetCurrentIfGone()
        }
        chatModel.onClearHistory = { [weak self] in
            self?.chats?.clearHistory()
            self?.forgetCurrentIfGone()
        }
        chatModel.onSaveFile = { [weak self] path in self?.saveFile(path) }
        chatModel.onRevealFile = { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        chatPanel = balloon
        return balloon
    }

    /// A prompt from the balloon: the chat is made with the first one, in
    /// the folder the label shows (`pendingFolder`); the files go with it,
    /// named from that folder.
    /// `attaching` is false for a prompt Evlat words itself (a retry): the
    /// chips stay for the user's own next line.
    private func send(_ text: String, attaching: Bool = true) {
        guard let chats else { return }
        let id = currentChat ?? chats.newChat(folder: pendingFolder, mode: chosenMode)
        currentChat = id
        chosenMode = nil
        let folder = chats.chat(id)?.folder ?? ""
        let files = (attaching ? chatModel.takeAttachments() : []).map { ChatFolder.attachmentPath($0.path, in: folder) }
        chosenFolder = nil
        chats.perform(.send(chat: id, text: text, attachments: files))
        syncChat()
        refreshFolder()
    }

    // MARK: - Dropped files (`011/phase-4`)

    /// The folder a chat made now would run in: the one picked from the
    /// label, else the one the files suggest, else (`nil`) its own
    /// workspace. Never the home (`ChatFolder`).
    var pendingFolder: String? {
        chosenFolder ?? ChatFolder.folder(for: chatModel.attachments, home: NSHomeDirectory())
    }

    /// The corner label follows the files until the first prompt, then
    /// stays with the chat's folder.
    private func refreshFolder() {
        if let id = currentChat, let chat = chats?.chat(id) {
            chatModel.setFolder(chat.isWorkspace ? nil : chat.folder, locked: true)
        } else {
            chatModel.setFolder(pendingFolder, locked: false)
        }
    }

    /// Files for the next prompt: chips in the balloon, which opens for
    /// them if it is not open yet.
    func attach(_ items: [ChatFolder.Item]) {
        guard !items.isEmpty else { return }
        chatModel.add(items)
        // Dropped on a closed balloon, the files start a chat of their own
        // rather than joining one that may still be running.
        if !isChatOpen { openChat(fresh: true) }
    }

    /// A file drag over the bar. The mascot catches it while it is over the
    /// drawn bar — its eyes open and follow it (`MascotPose.catching`) and
    /// a ring shows where to let go — and lets go of it when it leaves or
    /// lands. Called only while a drag is on; it writes nothing that did
    /// not change.
    func drag(_ drag: BarHostingView.Drag) -> Bool {
        switch drag {
        case .over(let point, let screen):
            let over = isOverDrawnBar(point)
            setCatching(over)
            if over { gaze?.observe(screen) }
            return over
        case .left:
            setCatching(false)
            return false
        case .drop(let point, let items):
            setCatching(false)
            guard isOverDrawnBar(point), !items.isEmpty else { return false }
            attach(items)
            return true
        }
    }

    private func setCatching(_ on: Bool) {
        if mascot.catching != on { mascot.catching = on }
    }

    /// The drawn bar, not the window: the transparent room beside and below
    /// it is the desktop's.
    private func isOverDrawnBar(_ point: CGPoint) -> Bool {
        guard let panel, let bounds = panel.contentView?.bounds else { return false }
        let x = panel.edge.inset(of: point.x, in: bounds)
        let y = point.y - bounds.minY
        let width = barState.isOpen ? barState.openWidth : Self.barWidth
        return x >= 0 && x <= width && y >= 0 && y <= barState.drawnLength
    }

    /// The label: before the first prompt it picks another folder, after
    /// it shows the chat's in Finder. Picking brings Evlat forward — the
    /// user asked for a panel (Karar 7) — and hands the front back after.
    private func folderTapped() {
        if let id = currentChat, let chat = chats?.chat(id) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: chat.folder, isDirectory: true)])
            return
        }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.canCreateDirectories = true
        open.directoryURL = pendingFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        // The balloon sits above ordinary windows (`.statusBar`) and would
        // cover the panel; it steps aside and comes back after.
        let previous = NSWorkspace.shared.frontmostApplication
        choosingInPanel = true
        chatPanel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK, let url = open.url { self.chosenFolder = url.path }
                self.refreshFolder()
                self.handBack(to: previous)
            }
        }
    }

    /// After the folder panel: the app that was in front gets the front
    /// back, and only **then** does the balloon return with the keyboard —
    /// the Spotlight pattern it opened with. Returned while Evlat was still
    /// active, the resign that follows took the keyboard from it and closed
    /// it, and Evlat stayed in front (seen by eye; `deactivate` is not
    /// synchronous).
    ///
    /// The balloon is ordered out until then, so its closing rules are back
    /// in force at once. The resign is waited for a moment at most: if it
    /// never comes (the app that was in front quit meanwhile), the balloon
    /// returns anyway rather than stay "open" and unseen.
    private func handBack(to previous: NSRunningApplication?) {
        choosingInPanel = false
        var token: NSObjectProtocol?
        var done = false
        let reopen = { [weak self] in
            guard !done else { return }
            done = true
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let self, self.isChatOpen, let bar = self.panel else { return }
            self.chatPanel?.present(beside: bar, edge: bar.edge)
        }
        guard NSApp.isActive else { return reopen() }
        token = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                       object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { reopen() }
        }
        let handedBack = previous.map { $0 != NSRunningApplication.current && $0.activate() } ?? false
        if !handedBack { NSApp.deactivate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handBackWait) { reopen() }
    }

    /// How long the balloon waits for Evlat to step back after the folder
    /// panel before it returns regardless.
    static let handBackWait: TimeInterval = 1

    /// The balloon's lines follow its chat. A finished chat on screen is
    /// seen: its row leaves the bar for the history (`011/phase-5`). The
    /// history and a workspace's files are written here too, each only
    /// when it changed.
    private func syncChat() {
        let chat = currentChat.flatMap { chats?.chat($0) }
        chatModel.update(from: chat)
        chatModel.setHasChat(chat != nil)
        if isChatOpen, let chat, chat.isFinished, !chat.seen { chats?.markSeen(chat.id) }
        chatModel.setHistory(chats?.history.filter { $0.id != currentChat }.map {
            ChatModel.HistoryItem(id: $0.id, title: $0.title ?? L10n.t("chat.folder.workspace"),
                                  folder: $0.isWorkspace ? nil : $0.folder,
                                  when: $0.lastActivity, pinned: $0.pinned)
        } ?? [])
        chatModel.setFiles(chat.map { chats?.workspaceFiles($0.id).map(\.path) ?? [] } ?? [])
        refreshMode()
    }

    /// After a × or a clear: a balloon speaking for a chat that is gone
    /// goes back to empty.
    private func forgetCurrentIfGone() {
        if let id = currentChat, chats?.chat(id) == nil {
            currentChat = nil
            refreshFolder()
        }
        syncChat()
    }

    /// `[Save…]` on a made file: a copy where the user says. The panel
    /// needs Evlat in front, like the folder panel, and hands the front
    /// back after.
    private func saveFile(_ path: String) {
        let source = URL(fileURLWithPath: path)
        let save = NSSavePanel()
        save.nameFieldStringValue = source.lastPathComponent
        save.canCreateDirectories = true
        save.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let previous = NSWorkspace.shared.frontmostApplication
        choosingInPanel = true
        chatPanel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        save.begin { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK, let target = save.url {
                    do {
                        if FileManager.default.fileExists(atPath: target.path) {
                            // The panel already asked whether to replace it.
                            _ = try FileManager.default.replaceItemAt(target, withItemAt: Self.copyForReplace(source))
                        } else {
                            try FileManager.default.copyItem(at: source, to: target)
                        }
                    } catch {
                        NSLog("Evlat: file not saved (%@)", error.localizedDescription)
                    }
                }
                self?.handBack(to: previous)
            }
        }
    }

    /// `replaceItemAt` moves the new item in: a temporary copy is moved,
    /// never the workspace's own file.
    nonisolated static func copyForReplace(_ source: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let file = copy.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: file)
        return file
    }

    func hotKeyPressed() {
        toggleChat()
    }

    // MARK: - Permission mode (`011/phase-3` ek)

    /// A new chat's mode, stored by its CLI value; none stored is auto.
    nonisolated static let permissionModeKey = "chat.permissionMode"

    nonisolated static func storedMode(_ defaults: UserDefaults?) -> PermissionMode {
        PermissionMode(stored: defaults?.string(forKey: permissionModeKey)) ?? .standard
    }

    /// Without storage — every test, and an isolated process (`EVLAT_PORT`,
    /// `EVLAT_CHATS`), which must not change the user's default — kept here.
    private var modeUnstored = PermissionMode.standard
    private var modeDefaults: UserDefaults? {
        ChatStore.isolated(ProcessInfo.processInfo.environment) ? nil : defaults
    }
    var defaultMode: PermissionMode { modeDefaults.map(Self.storedMode) ?? modeUnstored }

    /// The mode picked for a chat not made yet; `nil` is the default.
    private(set) var chosenMode: PermissionMode?

    /// The mode the label shows: the chat's, or the next chat's.
    private func refreshMode() {
        if let id = currentChat, let chat = chats?.chat(id) {
            chatModel.setMode(chat.mode)
        } else {
            chatModel.setMode(chosenMode ?? defaultMode)
        }
    }

    /// The label's menu at the pointer: the three modes, the current one
    /// ticked, each with what it does as its tooltip.
    private func showModes() {
        let menu = NSMenu()
        for mode in PermissionMode.allCases {
            let item = menu.addItem(withTitle: L10n.t(ChatModel.modeKey(mode)),
                                    action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.toolTip = L10n.t(ChatModel.modeDetailKey(mode))
            item.state = chatModel.mode == mode ? .on : .off
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// A mode picked from the label: the chat's from its next turn, and
    /// the default for the chats after it.
    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(PermissionMode.init(rawValue:)) else { return }
        choose(mode)
    }

    func choose(_ mode: PermissionMode) {
        if let id = currentChat, chats?.chat(id) != nil {
            chats?.setMode(id, mode)
        } else {
            chosenMode = mode
        }
        setDefaultMode(mode)
    }

    /// The next chats' mode, and nothing else (`014`, R1): the open chat —
    /// and a mode picked in the balloon for a chat not made yet — keeps
    /// its own. Stored under `modeDefaults`' isolation.
    func setDefaultMode(_ mode: PermissionMode) {
        if let modeDefaults { modeDefaults.set(mode.rawValue, forKey: Self.permissionModeKey) } else { modeUnstored = mode }
        refreshMode()
    }

    /// `[Retry in Ask mode]` on a "not done" line: this chat asks from now
    /// on — the default stays — and Claude is asked to try the call again,
    /// so it comes back as a card.
    func retryAsking(_ line: ChatSession.NotDone) {
        guard let id = currentChat, let chat = chats?.chat(id), !chat.isRunning else { return }
        chats?.setMode(id, .ask)
        refreshMode()
        send(L10n.t("chat.notDone.prompt", ["command": line.subject ?? line.tool]), attaching: false)
    }

    /// The stored switch, default on.
    nonisolated static let hotKeyKey = "chat.hotkey"
    /// The stored combination (`HotKeyCombination.stored`); none stored is
    /// ⇧⌘Space. Its own key, so the switch above keeps what it held.
    nonisolated static let hotKeyCombinationKey = "chat.hotkey.combination"

    nonisolated static func hotKeyEnabled(_ defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: hotKeyKey) as? Bool ?? true
    }

    nonisolated static func storedHotKey(_ defaults: UserDefaults?) -> HotKeyCombination {
        HotKeyCombination(stored: defaults?.object(forKey: hotKeyCombinationKey)) ?? .standard
    }

    /// Without storage (every test) the switch and the combination are kept
    /// here: still applied, like the edge, only not remembered.
    private var hotKeyUnstored = true
    private var hotKeyCombinationUnstored = HotKeyCombination.standard
    var isHotKeyOn: Bool { defaults.map(Self.hotKeyEnabled) ?? hotKeyUnstored }
    var hotKeyCombination: HotKeyCombination {
        defaults.map(Self.storedHotKey) ?? hotKeyCombinationUnstored
    }

    /// Registers or unregisters the shortcut as the switch says; the answer
    /// is kept for the menu. While the recorder is up nothing is registered:
    /// a registered combination never reaches a window, so pressing the
    /// current one again could not be recorded.
    func applyHotKey() {
        guard let hotKey else { return }
        if isHotKeyOn, !hotKeyRecorder.isRecording {
            let status = hotKey.register(hotKeyCombination)
            hotKeyStatus = status
            if status != noErr { NSLog("Evlat: the shortcut was not registered (%d)", status) }
        } else {
            hotKey.unregister()
            hotKeyStatus = nil
        }
        // A refused registration is the settings' Chat dot and line: read
        // again whoever changed the shortcut (the menu, the recorder).
        if settingsWindow?.isVisible == true { settings?.setup.reload() }
    }

    /// The shortcut's "Turn Off" / "Turn On": stored, then applied.
    /// Activates nothing.
    @objc func toggleHotKey(_ sender: Any?) {
        setHotKey(on: !isHotKeyOn)
    }

    /// The shortcut's switch, stored, then applied (`014`, R1).
    func setHotKey(on: Bool) {
        if let defaults {
            defaults.set(on, forKey: Self.hotKeyKey)
        } else {
            hotKeyUnstored = on
        }
        applyHotKey()
    }

    /// The shortcut's "Change…": Settings → Chat, recording. Evlat comes
    /// forward with the window (`014`, Karar 7 — the bar's own recorder
    /// panel is gone). The balloon closes first: one window has the
    /// keyboard. A recorded combination is stored and turns the shortcut
    /// on; a cancel puts the old one back.
    @objc func recordHotKey(_ sender: Any?) {
        if isChatOpen { closeChat() }
        openSettings(section: .chat)
        hotKeyRecorder.start()
    }

    private func makeHotKeyRecorder() -> HotKeyRecorder {
        let recorder = HotKeyRecorder(systemHotKeys: { [weak self] in self?.systemHotKeys() ?? .current() })
        // Let go while listening: a registered key never reaches a window,
        // so the current one could not be pressed again.
        recorder.onStart = { [weak self] in self?.applyHotKey() }
        recorder.onFinish = { [weak self] combination in
            guard let self else { return }
            if let combination { self.storeHotKey(combination) } else { self.applyHotKey() }
        }
        return recorder
    }

    /// A recorded combination: stored, the switch turned on, applied.
    func storeHotKey(_ combination: HotKeyCombination) {
        if let defaults {
            defaults.set(combination.stored, forKey: Self.hotKeyCombinationKey)
            defaults.set(true, forKey: Self.hotKeyKey)
        } else {
            hotKeyCombinationUnstored = combination
            hotKeyUnstored = true
        }
        applyHotKey()
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
            // Written once bound, under this controller's home: a controller
            // built without one (every test) has no key and refuses `/signal`.
            signalKey: Self.signalKeyWriter(home: home, written: signalKeyWritten),
            // Binding is asynchronous, so the outcome cannot be returned from
            // here. It is not swallowed either: `Evlat --list` reads the port
            // back over `/health` and says who holds it.
            onStatus: { status in
                if case .unavailable = status { NSLog("Evlat: hook endpoint %@", status.text) }
            },
            // A chat turn's held permission request that went away unanswered.
            onAbandoned: { [weak self] id in
                MainActor.assumeIsolated { self?.chats?.permissionAbandoned(id) }
            },
            onDelivery: { [weak self] delivery in
                MainActor.assumeIsolated { self?.handleDelivery(delivery) }
            })
        listener.start()
        hookListener = listener
        chats?.permissions = listener
    }

    // MARK: - Remote machines

    /// The machines to open tunnels to: `RemoteMachine.configuration` over
    /// this controller's defaults. Without defaults (every test) there are
    /// none, whatever the environment says — a test never runs `ssh`.
    nonisolated static func remoteConfiguration(
        defaults: UserDefaults?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RemoteMachine.Configuration {
        guard let defaults else {
            return RemoteMachine.Configuration(machines: [], fromEnvironment: true, rejected: [])
        }
        return RemoteMachine.configuration(environment: environment,
                                           stored: defaults.data(forKey: RemoteMachine.storageKey))
    }

    /// `EVLAT_SSH` replaces the `ssh` binary — the fake one, for looking at a
    /// tunnel without a server.
    nonisolated static func sshPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let raw = environment["EVLAT_SSH"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? "/usr/bin/ssh" : raw
    }

    /// Internal so a test hands its own machines and the fake `ssh`; the
    /// launch reads both from the environment and the stored list. A test
    /// also shortens `confirmAfter`: the default outwaits a slow login.
    func startRemoteTunnels(configuration: RemoteMachine.Configuration? = nil,
                            sshPath: String = AppController.sshPath(),
                            confirmAfter: TimeInterval = RemoteTunnel.defaultConfirmAfter) {
        let configuration = configuration ?? Self.remoteConfiguration(defaults: defaults)
        for target in configuration.rejected {
            NSLog("Evlat: EVLAT_MACHINES entry %@ ignored, not a usable ssh target", target)
        }
        remoteFromEnvironment = configuration.fromEnvironment
        // A machine kept from before `013` has no key yet: it gets one now,
        // and a key whose machine is gone goes. The environment's machines'
        // keys are made fresh and live in memory only.
        let storedKeys = configuration.fromEnvironment
            ? nil : defaults?.dictionary(forKey: RemoteMachine.signalKeysStorageKey)
        remoteSignalKeys = RemoteMachine.signalKeys(for: configuration.machines, stored: storedKeys,
                                                    generate: SignalKey.generate)
        if NSDictionary(dictionary: storedKeys ?? [:]) != NSDictionary(dictionary: remoteSignalKeys) {
            storeSignalKeys()
        }
        let tunnels = RemoteTunnels(
            registry: registry, sshPath: sshPath, platform: Self.darwinPlatform,
            now: { [unowned self] in MainActor.assumeIsolated { self.now() } },
            confirmAfter: confirmAfter,
            onChange: { [weak self] in MainActor.assumeIsolated { self?.scheduleRefresh() } })
        for machine in configuration.machines {
            tunnels.add(machine, key: remoteSignalKeys[machine.id] ?? SignalKey.generate())
        }
        remote = tunnels
        remoteSSHPath = sshPath
    }

    /// The window's view of the machines (`RemoteMachinesModel.Host`).
    var remoteMachinesHost: RemoteMachinesModel.Host {
        RemoteMachinesModel.Host(
            machines: { [weak self] in self?.remote?.machines ?? [] },
            state: { [weak self] id in self?.remote?.state(of: id) },
            sessionCounts: { [weak self] in
                guard let self else { return [:] }
                let ids = self.remote?.machines.map(\.id) ?? []
                var counts: [String: Int] = [:]
                // By each machine's own prefix, as `HooksProvider` builds it:
                // an id may hold a colon (an `EVLAT_MACHINES` target).
                for signal in self.registry.snapshot().ordered where signal.entity.hasPrefix("remote:") {
                    // The longest: `a` must not take `a:b`'s rows.
                    guard let id = ids.filter({ signal.entity.hasPrefix("remote:\($0):") })
                        .max(by: { $0.count < $1.count }) else { continue }
                    counts[id, default: 0] += 1
                }
                return counts
            },
            add: { [weak self] target in self?.addMachine(target: target) ?? .failure(.empty) },
            remove: { [weak self] id in self?.removeMachine(id: id) },
            isStored: { [weak self] in self.map { !$0.remoteFromEnvironment } ?? false },
            signalKey: { [weak self] id in self?.remote?.signalKey(of: id) })
    }

    /// The setup rows' way to the app (`014`): each closure is one of the
    /// writers above or the state they keep.
    var setupHost: SetupModel.Host {
        SetupModel.Host(
            home: { [weak self] in self?.home },
            binary: { [weak self] in self?.executable },
            loginStatus: { [weak self] in self?.loginItem?.status },
            loginPath: { [weak self] in self?.claudeLocator.lastLoginPath },
            hotKeyRefused: { [weak self] in self?.hotKeyStatus.map { $0 != noErr } ?? false },
            unreachableMachines: { [weak self] in
                guard let remote = self?.remote else { return [] }
                return remote.machines.compactMap { machine in
                    guard case .waiting? = remote.state(of: machine.id) else { return nil }
                    return machine.name
                }
            },
            setHooks: { [weak self] source, installed in self?.setHooks(source, installed: installed) },
            setUsageRelay: { [weak self] in self?.setUsageRelay(installed: $0) },
            setCommandLink: { [weak self] in self?.setCommandLink(installed: $0, replacing: $1) },
            setLoginItem: { [weak self] in self?.setLoginItem(on: $0) },
            hookFailure: { [weak self] in self?.hookFailure($0) },
            usageFailure: { [weak self] in self?.usageRelayFailure },
            commandLinkFailure: { [weak self] in self?.commandLinkFailure },
            loginItemFailed: { [weak self] in self?.loginItemFailed ?? false })
    }

    /// The settings window's view of the rest of the app (`SettingsModel`).
    var settingsHost: SettingsModel.Host {
        SettingsModel.Host(
            edge: { [weak self] in self?.barState.edge ?? .right },
            setEdge: { [weak self] in self?.setEdge($0) },
            isHotKeyOn: { [weak self] in self?.isHotKeyOn ?? false },
            setHotKey: { [weak self] in self?.setHotKey(on: $0) },
            hotKey: { [weak self] in self?.hotKeyCombination ?? .standard },
            defaultMode: { [weak self] in self?.defaultMode ?? .standard },
            setDefaultMode: { [weak self] in self?.setDefaultMode($0) },
            locateClaude: { [weak self] completion in
                guard let self else { return completion(nil) }
                self.claudeLocator.locate { completion($0.executable) }
            },
            memoryCount: { [weak self] in
                guard let chats = self?.chats else { return nil }
                return chats.memoryContents()?.count ?? 0
            },
            showMemory: { [weak self] in
                guard let folder = self?.chats?.memoryDirectory else { return }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            },
            clearMemory: { [weak self] in self?.chats?.clearMemory() })
    }

    /// The window's focus call on open; a test holds it still so the runner
    /// is never activated.
    var settingsActivation: () -> Void = { NSApp.activate() }

    /// The settings window at `section`, built on first use. Like the menus'
    /// entries the open list closes first; unlike them, Evlat comes forward —
    /// the user asked for a window to type into.
    func openSettings(section: SettingsModel.Section? = nil) {
        hover.closeNow()
        if barState.isOpen { closeBar() }
        let window = settingsWindow ?? makeSettingsWindow()
        if let section { settings?.section = section }
        window.show()
    }

    private func makeSettingsWindow() -> AppWindow {
        let model = SettingsModel(
            host: settingsHost,
            setup: SetupModel(host: setupHost),
            remote: RemoteMachinesModel(host: remoteMachinesHost, installer: RemoteInstaller(sshPath: remoteSSHPath)),
            recorder: hotKeyRecorder)
        let window = AppWindow(make: {
            let window = AppKeyWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
            window.title = model.t("settings.window.title")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentMinSize = SettingsView.minimumSize
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.setContentSize(SettingsView.size)
            return window
        }, activate: { [weak self] in self?.settingsActivation() })
        window.onOpen = { model.reload() }
        window.onCancel = { model.cancelInside() }
        window.keyInterceptor = { [weak model] event in model?.recorder.handle(event) ?? false }
        window.onResignKey = { [weak model] in model?.recorder.cancel() }
        window.onClose = { [weak model] in model?.windowClosed() }
        settings = model
        settingsWindow = window
        return window
    }

    /// The menus' "Settings…".
    @objc func openSettingsFromMenu(_ sender: Any?) { openSettings() }

    /// The menus' "Remote Machines…" (until `phase-4` takes it out): the
    /// settings at their remote section.
    @objc func openRemoteMachines(_ sender: Any?) {
        openSettings(section: .remote)
    }

    /// `EVLAT_SETTINGS=<section>` opens the settings at launch at that
    /// section (`general`, `sessions`, `chat`, `command`, `remote`) — for
    /// looking at one, the same pattern as `EVLAT_SELECT`. It only reads:
    /// nothing is pressed. An unknown value opens nothing.
    nonisolated static func forcedSettings(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SettingsModel.Section? {
        guard let raw = environment["EVLAT_SETTINGS"]?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return nil }
        return SettingsModel.Section(rawValue: raw)
            ?? SettingsModel.Section.allCases.first { "\($0)".lowercased() == raw }
    }

    /// Adds a machine by its `ssh` target, stores it and opens its tunnel.
    /// A target already present answers with that machine. The window
    /// (`phase-5`) is the caller.
    @discardableResult
    func addMachine(target: String) -> Result<RemoteMachine, RemoteMachine.TargetProblem> {
        if let problem = RemoteMachine.validate(target: target) { return .failure(problem) }
        guard let remote else { return .failure(.empty) }
        if let existing = remote.machines.first(where: { $0.target == target }) { return .success(existing) }
        guard let machine = RemoteMachine(id: UUID().uuidString, target: target) else { return .failure(.empty) }
        let key = SignalKey.generate()
        remoteSignalKeys[machine.id] = key
        remote.add(machine, key: key)
        storeMachines()
        storeSignalKeys()
        return .success(machine)
    }

    /// Closes the machine's tunnel, drops its rows and forgets it.
    func removeMachine(id: String) {
        remote?.remove(id: id)
        storeMachines()
        // The server's copy answers nothing from here on: no listener has
        // it, and a machine added again gets a new one.
        remoteSignalKeys.removeValue(forKey: id)
        storeSignalKeys()
    }

    /// Only a stored list is written back; one from the environment is read,
    /// never written (`EVLAT_EDGE`'s rule).
    private func storeMachines() {
        guard !remoteFromEnvironment, let remote,
              let data = RemoteMachine.encode(remote.machines) else { return }
        defaults?.set(data, forKey: RemoteMachine.storageKey)
    }

    /// The keys, under the same rule as the list they belong to.
    private func storeSignalKeys() {
        guard !remoteFromEnvironment else { return }
        defaults?.set(remoteSignalKeys, forKey: RemoteMachine.signalKeysStorageKey)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        hookListener?.stop()
        signalKeyWritten.remove()
        remote?.stopAll()
        chats?.stopAll()
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
            let environment = ProcessInfo.processInfo.environment
            let controller = AppController(
                defaults: .standard, home: resolvedHome(),
                loginItem: LoginItem(service: LoginItem.service(environment: environment)))
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
        case .permission(let request):
            // The store matches it to a turn, or refuses it.
            if let chats { chats.permissionAsked(request) } else {
                hookListener?.answer(request.id, with: LocalAPI.unknownToken)
            }
        case .signal(let report):
            // The cap is known here, after the listener answered `{}`; a
            // dropped row is said on stderr, where the rows' trace is read.
            if case .dropped(let limit) = signals.apply(report) {
                FileHandle.standardError.write(Data(Self.droppedSignalLine(id: report.id, limit: limit).utf8))
            }
            scheduleRefresh()
        }
    }

    /// `machine` names a remote machine's row (`RemoteTunnels`); its cap
    /// is its own.
    nonisolated static func droppedSignalLine(id: String, limit: Int, machine: String? = nil) -> String {
        "Evlat: signal \(id)\(machine.map { " from \($0)" } ?? "") dropped: \(limit) rows\n"
    }

    /// What a local listener is given to make its `/signal` key once bound:
    /// the key file for the bound port under `home` (`SignalKey`). No home,
    /// or an isolated process, and it makes none.
    ///
    /// `written`, when given, keeps what was written so the process can take
    /// it away when it ends (`SignalKey.remove`).
    nonisolated static func signalKeyWriter(
        home: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        written: SignalKey.Written? = nil
    ) -> (UInt16) -> String? {
        { port in
            guard let url = SignalKey.location(port: port, home: home, environment: environment),
                  let key = SignalKey.write(to: url) else { return nil }
            written?.set(url, key)
            return key
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
                // A row nobody can hear is marked: its phase alone reads like a live one.
                let rows = sessionRows.rows.map {
                    "\($0.phase.rawValue):\($0.entity.prefix(8))\($0.isLive ? "" : "(dim)")"
                }
                NSLog("Evlat: rows [%@] closed +%ld", rows.joined(separator: ", "), sessionRows.overflow)
                // The mark and a pending switch are keyed by session, and only a
                // move re-reads them. A column that reorders under a still cursor
                // would otherwise leave the mark on a row the cursor has left and
                // bring up the card of a session it no longer points at.
                if barState.isOpen { pointerMoved(mouseLocation()) }
            }
        }
        syncSelection(snapshot.ordered)
        if isChatOpen { syncChat() }
        // The window's lines follow the tunnels only while it is on screen;
        // it writes nothing unless one reads differently.
        if let settingsWindow, settingsWindow.isVisible { settings?.follow() }
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

    /// The bar takes two clicks: `[Go to session]`'s, and the mascot's,
    /// which opens or closes the balloon (`011`). Rows and rings take none:
    /// the card comes by hover (`005`, user's decision), and a click on a
    /// row it already speaks for has nothing left to do.
    private func click(at point: CGPoint) -> Bool {
        if barState.selected != nil, let button = goButtonRect, button.contains(point) {
            goToSession()
            return true
        }
        guard let panel, let bounds = panel.contentView?.bounds,
              Self.isOverMascot(fromEdge: panel.edge.inset(of: point.x, in: bounds),
                                fromTop: point.y - bounds.minY) else { return false }
        toggleChat()
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
        // Evlat's own chat has no terminal: its button is `[Back to chat]`,
        // and the balloon opens with it — the bar closes on the way.
        if detail.detail?.kind == .job, let entity = detail.detail?.entity,
           let id = ChatSession.chatID(fromEntity: entity) {
            openChat(chat: id)
            return
        }
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
        item.button?.image = TrayIcon.image()
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
                           "menu.hotkey", "menu.hotkey.change", "menu.hotkey.off", "menu.hotkey.on",
                           "menu.hotkey.failure",
                           "menu.quit", "menu.force", "menu.force.follow",
                           "menu.hooks.install", "menu.hooks.update", "menu.hooks.remove",
                           "menu.hooks.hint.claude", "menu.hooks.hint.codex", "menu.hooks.hint.remove",
                           "menu.hooks.error.unreadable", "menu.hooks.error.malformed",
                           "menu.hooks.error.noDirectory", "menu.hooks.error.changedUnderneath",
                           "menu.hooks.error.unwritable",
                           "menu.usage.install", "menu.usage.remove", "menu.usage.modified", "menu.usage.hint",
                           "menu.remote", "menu.remote.failure", "menu.settings",
                           "menu.memory", "menu.memory.show", "menu.memory.clear", "menu.memory.empty",
                           "menu.memory.confirm", "menu.memory.confirm.detail", "menu.memory.cancel",
                           "menu.memory.do"]

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

    /// The same for the status line relay's entry.
    struct UsageEntry {
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
        addHotKeyEntry(to: menu, in: lang)

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
        addRemoteEntry(to: menu, in: lang)
        addMemoryEntry(to: menu, in: lang)

        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: L10n.t("menu.settings", in: lang),
                                    action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
        settings.target = self
        let quit = menu.addItem(withTitle: L10n.t("menu.quit", in: lang),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

    }

    /// "Shortcut: ⇧⌘Space ▸ Change… / Turn Off", marked while on; under it
    /// a refused registration's dim line (`008`'s pattern) with Carbon's
    /// number. The line does not name another app: Carbon does not say who
    /// holds a key (measured).
    private func addHotKeyEntry(to menu: NSMenu, in lang: String) {
        let actions = NSMenu()
        let change = actions.addItem(withTitle: L10n.t("menu.hotkey.change", in: lang),
                                     action: #selector(recordHotKey(_:)), keyEquivalent: "")
        change.target = self
        let toggle = actions.addItem(withTitle: L10n.t(isHotKeyOn ? "menu.hotkey.off" : "menu.hotkey.on", in: lang),
                                     action: #selector(toggleHotKey(_:)), keyEquivalent: "")
        toggle.target = self
        let entry = menu.addItem(withTitle: L10n.t("menu.hotkey", ["shortcut": hotKeyCombination.title], in: lang),
                                 action: nil, keyEquivalent: "")
        entry.submenu = actions
        entry.state = isHotKeyOn ? .on : .off
        if let status = hotKeyStatus, status != noErr {
            let line = menu.addItem(withTitle: L10n.t("menu.hotkey.failure", ["status": "\(status)"], in: lang),
                                    action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.indentationLevel = 1
        }
    }

    /// One entry per agent whose directory exists, titled by what the file
    /// holds now: install, update or remove. The file is read each time a
    /// menu is built, never cached and never written here. A directory that
    /// is not there means the agent is not installed; no entry offers to
    /// create it.
    private func addHookEntries(to menu: NSMenu, in lang: String) {
        guard let home else { return }
        let sources = Self.presentSources(home: home)
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
            if let failure = hookFailures[source] { addFailureLine(failure, to: menu, in: lang) }
            if source == .claude { addUsageEntry(to: menu, in: lang, home: home) }
        }
    }

    /// "Remote Machines…", and under it one dim line per machine whose
    /// tunnel failed — `008`'s failure line, with the machine's name. The
    /// line does nothing: the window says what to do about it.
    private func addRemoteEntry(to menu: NSMenu, in lang: String) {
        menu.addItem(.separator())
        let entry = menu.addItem(withTitle: L10n.t("menu.remote", in: lang),
                                 action: #selector(openRemoteMachines(_:)), keyEquivalent: "")
        entry.target = self
        for machine in remote?.machines ?? [] {
            guard case .waiting(_, let failure)? = remote?.state(of: machine.id) else { continue }
            let text = L10n.t("menu.remote.failure",
                              ["machine": machine.name,
                               "failure": L10n.t(RemoteMachinesModel.failureKey(failure), in: lang)], in: lang)
            let line = menu.addItem(withTitle: text, action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.indentationLevel = 1
        }
    }

    /// "Evlat's Memory ▸ Show in Finder / Clear…": the folder workspace
    /// chats remember in (`ChatStore.memoryDirectory`). Read each time the
    /// menu is built; with nothing in it both entries are dim under an
    /// "empty" line.
    private func addMemoryEntry(to menu: NSMenu, in lang: String) {
        guard let chats else { return }
        let hasNotes = !(chats.memoryContents() ?? []).isEmpty
        let actions = NSMenu()
        actions.autoenablesItems = false
        if !hasNotes {
            let line = actions.addItem(withTitle: L10n.t("menu.memory.empty", in: lang), action: nil,
                                       keyEquivalent: "")
            line.isEnabled = false
        }
        let show = actions.addItem(withTitle: L10n.t("menu.memory.show", in: lang),
                                   action: #selector(showMemory(_:)), keyEquivalent: "")
        show.target = self
        show.isEnabled = hasNotes
        let clear = actions.addItem(withTitle: L10n.t("menu.memory.clear", in: lang),
                                    action: #selector(clearMemory(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = hasNotes
        let entry = menu.addItem(withTitle: L10n.t("menu.memory", in: lang), action: nil, keyEquivalent: "")
        entry.submenu = actions
    }

    @objc private func showMemory(_ sender: NSMenuItem) {
        guard let folder = chats?.memoryDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Asks first — the notes cannot be brought back — then empties the
    /// folder. The alert needs Evlat in front, like the save panel, and
    /// hands the front back after. Cancel is the default button.
    @objc private func clearMemory(_ sender: NSMenuItem) {
        guard chats != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("menu.memory.confirm")
        alert.informativeText = L10n.t("menu.memory.confirm.detail")
        alert.addButton(withTitle: L10n.t("menu.memory.cancel"))
        let clear = alert.addButton(withTitle: L10n.t("menu.memory.do"))
        clear.hasDestructiveAction = true
        let previous = NSWorkspace.shared.frontmostApplication
        choosingInPanel = true
        chatPanel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { chats?.clearMemory() }
        handBack(to: previous)
    }

    private func addFailureLine(_ failure: SettingsFile.Failure, to menu: NSMenu, in lang: String) {
        let line = menu.addItem(withTitle: L10n.t(Self.failureKey(failure), in: lang),
                                action: nil, keyEquivalent: "")
        line.isEnabled = false
        line.indentationLevel = 1
    }

    /// Under Claude's hook entry: the status line relay (`StatusLineRelay`),
    /// titled by what the file holds now. A wrapper edited by hand is a dim
    /// line with no action — it is neither installed over nor taken apart.
    private func addUsageEntry(to menu: NSMenu, in lang: String, home: URL) {
        let state = (try? StatusLineRelay.state(at: AgentSource.claude.settingsFile(home: home))) ?? .missing
        let key: String
        switch state {
        case .missing: key = "menu.usage.install"
        case .current: key = "menu.usage.remove"
        case .modified: key = "menu.usage.modified"
        }
        let entry = menu.addItem(withTitle: L10n.t(key, in: lang),
                                 action: state == .modified ? nil : #selector(changeUsageRelay(_:)),
                                 keyEquivalent: "")
        if state == .modified {
            entry.isEnabled = false
        } else {
            entry.representedObject = UsageEntry(remove: state == .current)
            entry.target = self
            entry.toolTip = L10n.t("menu.usage.hint", in: lang)
        }
        if let usageFailure { addFailureLine(usageFailure, to: menu, in: lang) }
    }

    /// A hook entry: the writer, then the outcome kept for the next menu —
    /// no dialog, no success message; the title changing is the answer.
    /// Like the edge, the open list closes and nothing is activated.
    @objc func changeHooks(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HookEntry else { return }
        setHooks(entry.source, installed: !entry.remove)
    }

    /// The status line relay's entry, as `changeHooks` does it.
    @objc func changeUsageRelay(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? UsageEntry else { return }
        setUsageRelay(installed: !entry.remove)
    }

    // MARK: - The writers (`014`, R1)
    //
    // The one place each setting is written. The menus, the settings window
    // and the setup only call these; the failure each leaves is kept here
    // and read by all three. Without a home (every test) none writes.

    /// A source's hooks installed or removed; the outcome is kept for the
    /// next reader — no dialog, no success message; the state changing is
    /// the answer. Like the edge, the open list closes and nothing is
    /// activated.
    func setHooks(_ source: AgentSource, installed: Bool) {
        guard let home else { return }
        let file = source.settingsFile(home: home)
        do {
            if installed {
                try HookSettings.install(at: file, for: source)
            } else {
                try HookSettings.remove(at: file, for: source)
            }
            hookFailures[source] = nil
        } catch {
            hookFailures[source] = error as? HookSettings.Failure ?? .unwritable
        }
        closeListAfterWrite()
    }

    /// The status line relay, as `setHooks` does it.
    func setUsageRelay(installed: Bool) {
        guard let home else { return }
        let file = AgentSource.claude.settingsFile(home: home)
        do {
            if installed {
                try StatusLineRelay.install(at: file)
            } else {
                try StatusLineRelay.remove(at: file)
            }
            usageFailure = nil
        } catch {
            usageFailure = error as? SettingsFile.Failure ?? .unwritable
        }
        closeListAfterWrite()
    }

    /// `~/.local/bin/evlat` to this binary, or taken away. `replacing` is
    /// the consent line's word for another copy's or a broken link.
    func setCommandLink(installed: Bool, replacing: Bool = false) {
        guard let home, let binary = executable else { return }
        let link = CommandLink.link(home: home)
        do {
            if installed {
                try CommandLinkWriter.install(at: link, binary: binary, replacing: replacing)
            } else {
                try CommandLinkWriter.remove(at: link, binary: binary)
            }
            commandLinkFailure = nil
        } catch {
            commandLinkFailure = error as? CommandLinkWriter.Failure ?? .unwritable
        }
    }

    /// "Open at login" on or off. Without a login item (every test that
    /// hands none) nothing is called.
    func setLoginItem(on: Bool) {
        guard let loginItem else { return }
        do {
            try loginItem.set(on)
            loginItemFailed = false
        } catch {
            NSLog("Evlat: the login item was not changed: %@", "\(error)")
            loginItemFailed = true
        }
    }

    func hookFailure(_ source: AgentSource) -> SettingsFile.Failure? { hookFailures[source] }
    var usageRelayFailure: SettingsFile.Failure? { usageFailure }

    /// The intent may already have believed the bar closed.
    private func closeListAfterWrite() {
        hover.closeNow()
        if barState.isOpen { closeBar() }
    }

    /// A right click (or ctrl-click) on the bar, in the content view's
    /// (flipped) coordinates: the menu over the mascot, nothing anywhere
    /// else. A left click on the mascot is the balloon's (`click(at:)`).
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
        setEdge(raw == "left" ? .left : .right)
    }

    /// The edge (`014`, R1), for every surface.
    func setEdge(_ edge: BarPanel.Edge) {
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
