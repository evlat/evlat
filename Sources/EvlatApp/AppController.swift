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
    private var statusItem: NSStatusItem?
    private var gaze: GazeTracker?
    private var poller: Timer?

    /// The collapsed bar's size. It leaves here once `003` brings the geometry
    /// abstraction; for now one constant in one place is enough.
    public static let collapsedSize = CGSize(width: 54, height: 260)

    /// The mascot sits at the head of the bar.
    public static let mascotSize: CGFloat = 34

    /// No directory watching, just polling.
    /// `DispatchSource.makeFileSystemObjectSource` needs an `open()` file
    /// descriptor and that is **Darwin** — it could live on this side, but
    /// polling is enough at this size and stays portable. The interval is
    /// measured and recorded in the phase notes.
    private static let pollInterval: TimeInterval = 1.5

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

    /// `Evlat --liste`: print the signals and exit, opening no window.
    /// This set's stand-in for v1's `GET /status`; the full local API lands in
    /// `002`.
    nonisolated public static func printSignalsAndExit() -> Never {
        let provider = makeSessionsProvider()
        let registry = Registry()
        registry.register(provider)
        // One scan, three numbers. The first version called `ordered()`,
        // `aggregate()` and `hasLive` separately; each re-read the directory, so
        // a file changing in between could print a self-contradicting summary.
        let signals = registry.ordered()
        let aggregate = signals.map(\.phase).max(by: { $0.priority < $1.priority }) ?? .idle
        print("provider: \(SessionsProvider.id)  ·  directory: \(sessionsDirectory().path)")
        print("live sessions: \(signals.count)  ·  aggregate: \(aggregate.rawValue)  ·  hasLive: \(!signals.isEmpty)")
        for signal in signals {
            let raw = signal.rawStatus.map { " (raw: \($0))" } ?? ""
            let phase = signal.phase.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            print("  \(phase) \(signal.label)\(raw)  ← \(signal.detail ?? "")")
        }
        if !provider.unrecognizedStatuses.isEmpty {
            print("unrecognised status: \(provider.unrecognizedStatuses.sorted().joined(separator: ", "))")
        }
        if provider.recordsMissingUpdatedAt > 0 {
            print("records with unreadable updatedAt: \(provider.recordsMissingUpdatedAt) (format may have drifted)")
        }
        exit(0)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: no Dock icon, no Cmd-Tab entry. The bar should behave
        // like part of the system rather than like an app.
        NSApp.setActivationPolicy(.accessory)
        registry.register(Self.makeSessionsProvider())
        installStatusItem()

        let panel = BarPanel(edge: .right,
                             size: Self.collapsedSize,
                             content: BarBody(edge: .right, mascot: mascot))
        panel.show()
        self.panel = panel

        // The seam runs here: provider → Registry → MascotModel → view.
        refresh()
        poller = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }  // Timer callback is nonisolated
        }

        let tracker = GazeTracker(model: mascot) { [weak panel] in
            guard let frame = panel?.frame else { return .zero }
            // The mascot is the head of the bar, so the anchor is near the top.
            return CGPoint(x: frame.midX, y: frame.maxY - Self.mascotSize)
        }
        tracker.start()
        gaze = tracker
    }

    public func applicationWillTerminate(_ notification: Notification) {
        poller?.invalidate()
        gaze?.stop()
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

    /// One scan, two values. The registry is not asked twice: a file changing in
    /// between could leave `phase` and `hasLive` contradicting each other.
    private func refresh() {
        let signals = registry.signals()
        mascot.phase = signals.map(\.phase).max(by: { $0.priority < $1.priority }) ?? .idle
        mascot.hasLive = !signals.isEmpty
    }

    /// Menu-bar entry. The bar's own right-click menu and the settings window
    /// belong to `003`/`004`.
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

/// The bar's body. Session indicators arrive in `003`; today it carries the
/// shape and the mascot.
struct BarBody: View {
    var edge: BarPanel.Edge = .right
    @ObservedObject var mascot: MascotModel

    var body: some View {
        ZStack(alignment: .top) {
            shapeLayer
            // The mascot is the head of the bar: in the collapsed strip it is
            // the only thing visible. Session indicators line up beneath it.
            MascotView(model: mascot, size: AppController.mascotSize)
                .padding(.top, 26)
        }
    }

    private var shapeLayer: some View {
        let shape = BarShape(corner: 18, flare: 20, edge: edge)
        return shape
            .fill(Color.black.opacity(0.88))
            // A thin inner edge separates the body from a dark wall behind it
            // and makes the flare's curve readable. There must be no line on the
            // screen edge itself — that side is off-screen.
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
            // The shadow deepens the curve; it is what sells "growing out of the
            // bezel".
            .shadow(color: .black.opacity(0.35), radius: 10, x: -3, y: 0)
    }
}
