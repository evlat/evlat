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
public final class AppController: NSObject, NSApplicationDelegate {
    public private(set) var panel: BarPanel?
    public let registry = Registry()
    public let mascot = MascotModel()
    /// The indicators under the mascot. Fed from the same snapshot as the
    /// mascot in `refresh()`, observed by its own column.
    public let sessionRows = SessionRowsModel()
    /// The card's facts for the selected session. Written only while one is
    /// selected (`syncSelection`), observed by the card alone.
    public let detail = DetailModel()
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
    private var hookListener: HookListener?
    private var statusItem: NSStatusItem?
    private var gaze: GazeTracker?
    /// When a cursor over the bar opens it, and when leaving closes it.
    private let hover = HoverIntent()
    /// When a cursor staying on a row brings its card up, or takes the card
    /// there. A `var` so a test can hand it a scheduler before `installPanel`.
    var rowSwitch = RowSwitch()
    /// Whether the body is drawn open. Apart from the window's size on purpose:
    /// the window is resized when nothing on screen moves, and this is what the
    /// eye sees move (`openBar`, `closeBar`).
    let barState = BarState()
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
    /// The body opens only as far as the names it holds need
    /// (`BarState.openWidth`); the window keeps room for this and the card
    /// beside it (`envelopeSize`). Opening does not change the length — the
    /// rows are the same rows, only named.
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
    /// with its row, so the lowest slot is where the tallest card hangs from.
    public static func slotTop(_ index: Int) -> CGFloat {
        mascotTopInset + mascotSize + indicatorTopGap
            + CGFloat(index) * (indicatorSize + indicatorSpacing)
    }

    /// The slot under a point, measured from the docked edge and the window's
    /// top; `nil` over the mascot, past the last slot or past `width` — the
    /// drawn body's. A slot is its ring and half the gap each side, so the
    /// cursor moving down the column is always over some row. Rows are
    /// fixed-height (`SessionColumn`), so this is the whole geometry.
    static func slot(fromEdge x: CGFloat, fromTop y: CGFloat, width: CGFloat) -> Int? {
        guard x >= 0, x <= width else { return nil }
        let pitch = indicatorSize + indicatorSpacing
        let offset = y - (slotTop(0) - indicatorSpacing / 2)
        guard offset >= 0 else { return nil }
        let index = Int(offset / pitch)
        return index < SessionRowsModel.slotCount ? index : nil
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
    /// a pending row switch like the card itself does.
    static func cardHoverRect(_ card: CGRect) -> CGRect {
        var rect = card
        rect.size.width += detailCardGap
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
    /// full bar or the tallest card hanging from the lowest slot (and its
    /// shadow), whichever reaches further. The head is still laid out from
    /// `anchorLength`, so everything past the full bar hangs below it,
    /// transparent: clicks fall through, hover is only the drawn part.
    ///
    /// Resizing at interaction time is what `004` could not make smooth — a
    /// window growing leftward showed its old content one frame at the old
    /// origin — and a card that lengthened the window would repeat it downward.
    public static let envelopeSize = CGSize(
        width: expandedBarWidth + detailCardGap + detailCardWidth + shadowGutter,
        height: max(anchorLength,
                    slotTop(SessionRowsModel.slotCount - 1) + detailCardMaxHeight + shadowGutter))

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
    /// the same pattern (`EVLAT_PORT`, `EVLAT_PET`).
    nonisolated public static func sessionsDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["EVLAT_SESSIONS"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return SessionsProvider.defaultDirectory()
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
        let listener = HookListener(port: choice.port) { event in
            // Streamed, not only summarised: under a `PostToolUse` burst a
            // fixed-size bucket drops exactly the rare event a measurement is
            // looking for (one `Stop` carrying an `agent_id`).
            print(diagnostics.record(event).text)
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

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: no Dock icon, no Cmd-Tab entry. The bar should behave
        // like part of the system rather than like an app.
        NSApp.setActivationPolicy(.accessory)
        registry.register(Self.makeSessionsProvider())
        // The undo switch for this whole set: with this one line gone the
        // listener still binds and the events still parse, and the bar is
        // exactly what `001` shipped.
        registry.register(hooks)
        startHookListener()
        installStatusItem()

        let panel = installPanel()
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
        switch Self.forcedSelection() {
        case .first?: sessionRows.rows.first.map { select($0.entity) }
        case .entity(let entity)?: select(entity)
        case nil: break
        }
        poller = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }  // Timer callback is nonisolated
        }

        let tracker = GazeTracker(model: mascot) { [weak panel] in
            guard let frame = panel?.frame else { return .zero }
            // The eyes' real centre, not an approximation of it: the inset and
            // half the mascot below the top, and half the bar's width in from
            // the screen edge (the window is wider than the bar by the shadow
            // gutter). Reading it off shared constants keeps the anchor from
            // drifting when the layout moves.
            return CGPoint(x: frame.maxX - Self.barWidth / 2,
                           y: frame.maxY - Self.mascotTopInset - Self.mascotSize / 2)
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
    @discardableResult
    func installPanel() -> BarPanel {
        let panel = BarPanel(edge: .right,
                             size: Self.envelopeSize,
                             anchorLength: Self.anchorLength,
                             trackingInset: Self.shadowGutter,
                             content: BarBody(edge: .right, mascot: mascot, rows: sessionRows,
                                              state: barState, detail: detail,
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
        rowSwitch.onSelect = { [weak self] entity in self?.select(entity) }
        self.panel = panel
        return panel
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
            onEvent: { [weak self] event in
                MainActor.assumeIsolated { self?.handleHookEvent(event) }
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
            let controller = AppController()
            app.delegate = controller
            app.run()
        }
        exit(0)
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
        let before = (sessionRows.rows, sessionRows.overflow)
        sessionRows.update(from: snapshot.ordered)
        if before.0 != sessionRows.rows || before.1 != sessionRows.overflow {
            // The body follows the column — drawn, not the window. The hover
            // area is AppKit's and hears nothing from SwiftUI, so it is told
            // the same length.
            let length = Self.barLength(slots: sessionRows.slotsInUse)
            if abs(barState.length - length) > 0.5 {
                barState.length = length
                panel?.setVisibleLength(length)
            }
            // The open body is as wide as the names it holds.
            let width = SessionColumn.openWidth(
                namesWidth: SessionColumn.namesWidth(sessionRows.rows))
            if abs(barState.openWidth - width) > 0.5 {
                barState.openWidth = width
                if barState.isOpen { panel?.setVisibleWidth(width) }
            }
            // The rows' trace on stderr, for the same reason as the line above.
            let rows = sessionRows.rows.map { "\($0.phase.rawValue):\($0.entity.prefix(8))" }
            NSLog("Evlat: rows [%@] +%ld", rows.joined(separator: ", "), sessionRows.overflow)
        }
        syncSelection(snapshot.ordered)
    }

    /// The card follows the selected session through the same snapshot: its
    /// slot when the column reorders, its facts when they move. Nothing is
    /// written without a selection. A session that has no drawn row any more
    /// — gone, or pushed into the "+N" count — has nothing for the card to
    /// hang from, so the card closes.
    private func syncSelection(_ signals: [Signal]) {
        guard let selected = barState.selected else { return }
        guard let slot = sessionRows.rows.firstIndex(where: { $0.entity == selected }) else {
            deselect()
            return
        }
        if barState.selectedSlot != slot { barState.selectedSlot = slot }
        detail.update(row: sessionRows.rows[slot],
                      signal: signals.first { $0.entity == selected })
    }

    /// Selects a drawn row's session: the row switch after its wait, or
    /// `EVLAT_SELECT` at launch. The list opens (at once, if it was closed),
    /// the row is marked and the card comes up level with it.
    /// Activates nothing — the app stays in the background, the panel is
    /// never key.
    func select(_ entity: String) {
        guard sessionRows.rows.contains(where: { $0.entity == entity }) else { return }
        rowSwitch.cancel()
        hover.openNow()
        if !barState.isOpen { openBar() }
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

    /// The row under a screen point, while the bar is open.
    private func row(atScreen point: CGPoint) -> String? {
        guard let frame = panel?.frame, barState.isOpen,
              let slot = Self.slot(fromEdge: frame.maxX - point.x, fromTop: frame.maxY - point.y,
                                   width: barState.openWidth),
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
        panel?.setCardRect(barState.selected == nil ? nil : rect.map(Self.cardHoverRect))
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

    /// Opening is the drawn body widening; the window is already wide. The
    /// hover area takes the open width at once, so the cursor following the
    /// body's edge as it travels is still over the bar.
    func openBar() {
        panel?.setVisibleWidth(barState.openWidth)
        barState.isOpen = true
    }

    /// Closing: the body narrows back to the edge and the hover area with it.
    func closeBar() {
        // The list and the card close together; the selection does not
        // outlive them.
        deselect()
        if barState.hovered != nil { barState.hovered = nil }
        barState.isOpen = false
        panel?.setVisibleWidth(Self.barWidth)
    }

    /// Menu-bar entry. A diagnostic, not a user surface: a real tray menu, the
    /// bar's right-click menu and the settings window are out of scope for
    /// now, so these titles stay English and outside the catalogue.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.on.square",
                                     accessibilityDescription: "Evlat")
        let menu = NSMenu()

        // Forcing a phase so it can be looked at. `waiting` and `failed` cannot
        // be produced without hooks (`002`), so those two expressions would
        // otherwise never be visible.
        let forced = NSMenu()
        let follow = forced.addItem(withTitle: "Follow sessions",
                                    action: #selector(clearOverride), keyEquivalent: "")
        follow.target = self
        forced.addItem(.separator())
        for phase in Phase.allCases {
            let entry = forced.addItem(withTitle: phase.rawValue.capitalized,
                                       action: #selector(setOverride(_:)), keyEquivalent: "")
            entry.representedObject = phase.rawValue
            entry.target = self
        }
        let forcedItem = NSMenuItem(title: "Force state", action: nil, keyEquivalent: "")
        forcedItem.submenu = forced
        menu.addItem(forcedItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Evlat",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
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
    @Published var isOpen = false
    /// How far the body opens: as wide as the names need, within
    /// `SessionColumn`'s bounds.
    @Published var openWidth = SessionColumn.openWidth(namesWidth: 0)
    /// How long the body is drawn along the edge, from the head. The window
    /// is longer; this is the part that is bar.
    @Published var length = AppController.barLength(slots: 0)
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
}

/// The bar's body: the shape, the mascot at its head, the session rings
/// beneath it, and — while the bar is open — their names.
///
/// **Everything is laid out from the screen edge.** The shape, the mascot and
/// the rings hang off the trailing side, so the window growing or shrinking
/// moves none of them; opening is the shape's inner edge travelling left and
/// the names fading in. The mascot and the column observe their own models,
/// so a gaze write re-evaluates the mascot alone and a beat the rings alone.
struct BarBody: View {
    var edge: BarPanel.Edge = .right
    let mascot: MascotModel
    let rows: SessionRowsModel
    @ObservedObject var state: BarState
    var detail = DetailModel()
    /// The card's drawn rectangle as it lays out, `nil` when it goes: the
    /// panel's second hover area is held to it.
    var onCardFrame: (CGRect?) -> Void = { _ in }
    /// `[Go to session]`'s drawn rectangle, for the click.
    var onGoButtonFrame: (CGRect?) -> Void = { _ in }
    /// The card's top above its row's ring: its header lines up with the
    /// row's name.
    static let cardLead: CGFloat = 16

    static func cardTop(slot: Int) -> CGFloat {
        max(0, AppController.slotTop(slot) - cardLead)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Top-aligned in the envelope: the far end moves, the head stays.
            // The shadow and the inner edge are the shape's, so they shorten
            // with it.
            shapeLayer
                .frame(width: state.isOpen ? state.openWidth : AppController.barWidth,
                       height: state.length)
                .animation(BarMotion.body, value: state.isOpen)
                .animation(BarMotion.body, value: state.openWidth)
                .animation(BarMotion.length, value: state.length)
            card
            VStack(alignment: .trailing, spacing: AppController.indicatorTopGap) {
                // The mascot is the head of the bar; the rings line up beneath.
                MascotView(model: mascot, size: AppController.mascotSize)
                    .frame(width: AppController.barWidth)
                SessionColumn(model: rows, showsNames: state.isOpen,
                              selected: state.selected, hovered: state.hovered,
                              openWidth: state.openWidth)
            }
            .padding(.top, AppController.mascotTopInset)
        }
        // Pinned to the screen edge and the head. What is left on the other
        // side is the shadow's room, the open body's and the card's; what is
        // left below is the card's.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// Beside the open body, `detailCardGap` from its inner edge, level with
    /// the selected row. The window already has room for it at every slot
    /// (`AppController.envelopeSize`), so it is never pushed around.
    @ViewBuilder private var card: some View {
        if state.isOpen, state.selected != nil, let slot = state.selectedSlot {
            DetailCard(model: detail, onButtonFrame: onGoButtonFrame)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    onCardFrame(rect)
                }
                .onDisappear { onCardFrame(nil) }
                .padding(.top, Self.cardTop(slot: slot))
                .padding(.trailing, state.openWidth + AppController.detailCardGap)
                .animation(BarMotion.length, value: slot)
                .transition(.opacity.animation(BarMotion.namesOut))
        }
    }

    private var shapeLayer: some View {
        let shape = BarShape(corner: AppController.barCorner,
                             flare: AppController.barFlare, edge: edge)
        return shape
            .fill(BarPalette.body)
            // A thin inner edge separates the body from a dark wall behind it
            // and makes the flare's curve readable. `outline` drops the segment
            // that lies on the screen edge: stroking the closed path put a
            // hairline on the screen's outermost pixel column.
            .overlay(shape.outline.stroke(Color.white.opacity(0.10), lineWidth: 1))
            // The shadow deepens the curve; it is what sells "growing out of the
            // bezel". It needs the gutter above to render at all.
            .shadow(color: .black.opacity(0.35), radius: 10, x: -3, y: 0)
    }
}
