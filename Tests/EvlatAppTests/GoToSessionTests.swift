import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// `[Go to session]`: when the terminal is looked up, what the button says,
/// and what a click on it does. The lookup and the activation are injected —
/// no test here walks this machine's processes or brings an app forward.
@MainActor
final class GoToSessionTests: XCTestCase {
    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    private let term = SessionHost.App(bundleID: "dev.metalterm.Metalterm", name: "Metalterm", pid: 500)
    private var resolved: [Int32?] = []
    private var activated: [SessionHost.App] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        resolved = []
        activated = []
    }

    private func signal(_ entity: String, pid: Int32? = 900) -> Signal {
        Signal(provider: "stub", entity: entity, phase: .waiting, label: entity,
               fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
               activity: Signal.Activity(pid: pid))
    }

    private func controller(_ signals: [Signal], host: @escaping () -> SessionHost) -> (AppController, Stub) {
        let controller = AppController()
        let provider = Stub()
        provider.signals = signals
        controller.registry.register(provider)
        controller.detail.resolveHost = { [unowned self] pid in self.resolved.append(pid); return host() }
        controller.detail.activate = { [unowned self] app in self.activated.append(app); return true }
        controller.installPanel()
        controller.refresh()
        return (controller, provider)
    }

    // MARK: - When the lookup runs

    func testTheTerminalIsLookedUpWhenTheCardComesUpNotOnEverySnapshot() {
        let (controller, provider) = controller([signal("a")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        XCTAssertEqual(resolved, [900])
        XCTAssertEqual(controller.detail.detail?.host, .app(term))
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(resolved, [900], "the poll does not walk the processes again")

        provider.signals = [signal("a", pid: 901)]   // `claude --resume`: a new pid
        controller.refresh()
        XCTAssertEqual(resolved, [900, 901])

        controller.closeBar()
        controller.select("a")
        XCTAssertEqual(resolved, [900, 901, 901], "a card that comes up again looks again")
    }

    // MARK: - The click

    func testGoBringsTheAppForwardAndClosesTheListAndCard() {
        let (controller, _) = controller([signal("a")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        controller.goToSession()
        XCTAssertEqual(activated, [term])
        XCTAssertEqual(resolved.count, 2, "looked up again at the click")
        XCTAssertFalse(controller.barState.isOpen)
        XCTAssertNil(controller.barState.selected)
    }

    /// The app quit after the card came up: the click opens nothing, and the
    /// card now says the app is closed.
    func testAnAppThatQuitSinceIsSaidNotOpened() {
        var host = SessionHost.app(term)
        let (controller, _) = controller([signal("a")]) { host }
        defer { controller.panel?.close() }
        controller.select("a")
        host = .closed(name: "Metalterm")
        controller.goToSession()
        XCTAssertEqual(activated, [])
        XCTAssertEqual(controller.detail.detail?.host, .closed(name: "Metalterm"))
        XCTAssertTrue(controller.barState.isOpen, "nothing happened elsewhere: the card stays")
        XCTAssertEqual(controller.barState.selected, "a")
    }

    /// The button is hit by geometry, like the rows: its drawn rectangle is
    /// reported by the card and a click inside it goes to the session.
    func testAClickOnTheButtonsRectangleGoes() throws {
        let (controller, _) = controller([signal("a")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        let button = CGRect(x: 40, y: 300, width: 230, height: 28)
        controller.goButtonFrameChanged(button)
        let onClick = try XCTUnwrap(controller.panel?.onClick)
        XCTAssertFalse(onClick(CGPoint(x: 40 - 1, y: 310)), "beside it: not ours")
        XCTAssertEqual(activated, [])
        XCTAssertTrue(onClick(CGPoint(x: 60, y: 310)))
        XCTAssertEqual(activated, [term])

        controller.goButtonFrameChanged(nil)
        XCTAssertFalse(onClick(CGPoint(x: 60, y: 310)), "no card, no button")
    }

    // MARK: - A remote row

    private func remote(_ entity: String) -> Signal {
        Signal(provider: "stub", entity: entity, phase: .waiting, label: "api",
               fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
               activity: Signal.Activity(), machine: Signal.Machine(name: "devbox"))
    }

    /// A remote session runs in a terminal on another computer: there is
    /// nothing on this Mac to look up or bring forward, so the card has no
    /// button at all — not the "terminal not found" one.
    func testARemoteRowLooksNothingUpAndGoesNowhere() throws {
        let (controller, _) = controller([remote("remote:d:1")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("remote:d:1")
        let detail = try XCTUnwrap(controller.detail.detail)
        XCTAssertEqual(detail.machine, "devbox")
        XCTAssertFalse(DetailCard.showsButton(detail), "no button, no terminal")
        XCTAssertNil(DetailCard.terminal(detail.host))
        XCTAssertFalse(controller.detail.go())
        controller.goToSession()
        XCTAssertEqual(resolved, [], "no process walk for a remote row")
        XCTAssertEqual(activated, [])
        XCTAssertTrue(controller.barState.isOpen, "nothing happened elsewhere: the card stays")
    }

    /// From a local card to a remote one: the old button's rectangle does not
    /// linger as a place to click.
    func testTheButtonsRectangleGoesWithARemoteCard() throws {
        let (controller, _) = controller([signal("a"), remote("remote:d:1")]) { .app(self.term) }
        defer { controller.panel?.close() }
        controller.select("a")
        XCTAssertTrue(DetailCard.showsButton(try XCTUnwrap(controller.detail.detail)))
        controller.goButtonFrameChanged(CGRect(x: 40, y: 300, width: 230, height: 28))
        controller.select("remote:d:1")
        controller.goButtonFrameChanged(nil)   // the button's `onDisappear`
        let onClick = try XCTUnwrap(controller.panel?.onClick)
        XCTAssertFalse(onClick(CGPoint(x: 60, y: 310)))
        XCTAssertEqual(activated, [])
    }

    func testCloseNowClosesThroughTheIntent() {
        var changes: [Bool] = []
        var scheduled: [DispatchWorkItem] = []
        let intent = HoverIntent { _, item in scheduled.append(item) }
        intent.onChange = { changes.append($0) }
        intent.closeNow()
        XCTAssertEqual(changes, [], "already closed")
        intent.openNow()
        intent.closeNow()
        XCTAssertFalse(intent.isOpen)
        XCTAssertEqual(changes, [true, false])
        intent.pointerEntered()
        XCTAssertEqual(scheduled.count, 1, "the next enter opens again")
    }

    // MARK: - What the card says

    func testTheButtonsThreeStates() {
        XCTAssertEqual(DetailCard.button(for: .app(term), in: "tr"),
                       .init(title: "Oturuma git", enabled: true))
        XCTAssertEqual(DetailCard.button(for: .closed(name: "Orca"), in: "tr"),
                       .init(title: "Orca kapalı", enabled: false))
        XCTAssertEqual(DetailCard.button(for: .notFound, in: "tr"),
                       .init(title: "Terminal bulunamadı", enabled: false))
        XCTAssertEqual(DetailCard.button(for: .closed(name: "Orca"), in: "en"),
                       .init(title: "Orca is closed", enabled: false))
    }

    func testTheFooterEndsWithTheTerminal() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(DetailCard.footer(enteredAt: now.addingTimeInterval(-125),
                                         activity: .init(toolCount: 12), terminal: "Ghostty",
                                         now: now, in: "tr"),
                       "2 dk · 12 araç · Ghostty")
        XCTAssertEqual(DetailCard.footer(enteredAt: nil, activity: nil, terminal: "Orca",
                                         now: now, in: "en"), "Orca")
        XCTAssertEqual(DetailCard.terminal(.app(term)), "Metalterm")
        XCTAssertEqual(DetailCard.terminal(.closed(name: "Orca")), "Orca")
        XCTAssertNil(DetailCard.terminal(.notFound))
    }

    /// `--list` names the terminal and never the pid.
    func testTheListLineNamesTheTerminal() {
        let line = AppController.listLine(signal("a", pid: 4242), host: .closed(name: "Orca"))
        XCTAssertTrue(line.hasSuffix("→ Orca (closed)"), line)
        XCTAssertFalse(line.contains("4242"), line)
    }
}
