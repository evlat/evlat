import XCTest
import Combine
import EvlatCore
@testable import EvlatApp

/// The seam's last metre: provider → `Registry` → `MascotModel`.
///
/// Two things are pinned here and neither is visible from `EvlatCore`: that a
/// burst of events produces **one** scan, and that an unchanged snapshot never
/// reaches `@Published`. Both are traps this repo names outright
/// (`AGENTS.md` → Pitfalls), and both fail silently — the app keeps
/// working, it just burns the bar's whole CPU budget re-evaluating itself.
@MainActor
final class RefreshTests: XCTestCase {
    /// Counts how often the registry actually asked it for signals.
    private final class CountingProvider: Provider {
        let id = "counting"
        var scans = 0
        var signals: [Signal] = []
        func currentSignals() -> [Signal] {
            scans += 1
            return signals
        }
    }

    private func signal(_ phase: Phase) -> Signal {
        Signal(provider: "counting", entity: "s-1", phase: phase, label: "s-1",
               fidelity: .official, updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func event(_ name: String) -> HookEvent {
        HookEvent(json: ["hook_event_name": name, "session_id": "s-1", "cwd": "/tmp/p"])
    }

    // MARK: - Nothing changed, nothing written

    func testAnUnchangedSnapshotIsNotWrittenToTheModel() {
        let controller = AppController()
        let provider = CountingProvider()
        provider.signals = [signal(.waiting)]
        controller.registry.register(provider)

        var writes = 0
        let token = controller.mascot.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }

        controller.refresh()
        XCTAssertEqual(controller.mascot.phase, .waiting)
        let afterFirst = writes
        XCTAssertGreaterThan(afterFirst, 0, "the first scan really did change something")

        controller.refresh()
        controller.refresh()
        XCTAssertEqual(writes, afterFirst, "an unchanged snapshot must not touch @Published")
    }

    /// The deadband compares **what is written**, not the snapshot: a hook row's
    /// stamp moves on every `PostToolUse`, so a whole-snapshot comparison would
    /// report "changed" for exactly the burst it exists to absorb.
    func testAMovingStampAloneDoesNotWakeTheModel() {
        let controller = AppController()
        let provider = CountingProvider()
        provider.signals = [signal(.working)]
        controller.registry.register(provider)
        controller.refresh()

        var writes = 0
        let token = controller.mascot.objectWillChange.sink { _ in writes += 1 }
        defer { token.cancel() }

        provider.signals = [Signal(provider: "counting", entity: "s-1", phase: .working,
                                   label: "s-1", fidelity: .official,
                                   updatedAt: Date(timeIntervalSince1970: 1_790_000_600))]
        controller.refresh()
        XCTAssertEqual(writes, 0, "same face, same liveness: nothing to write")
    }

    // MARK: - One refresh per burst

    /// `PostToolUse` arrives in bursts. Scanning per event would re-read the
    /// session directory once per tool call.
    func testABurstOfEventsProducesOneScan() {
        let controller = AppController()
        let provider = CountingProvider()
        controller.registry.register(provider)

        for _ in 0..<20 { controller.handleHookEvent(event("PostToolUse")) }
        XCTAssertEqual(provider.scans, 0, "the scan is scheduled, not run per event")

        let settled = expectation(description: "coalescing window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + AppController.refreshCoalescing * 3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(provider.scans, 1, "twenty events, one scan")
    }

    /// And the event does reach the face: the coalescing window is what the
    /// user waits, instead of up to a full poll interval.
    func testAnEventReachesTheModelWithoutWaitingForThePoller() {
        let controller = AppController()
        controller.registry.register(controller.hooks)

        controller.handleHookEvent(event("PermissionRequest"))
        let settled = expectation(description: "coalescing window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + AppController.refreshCoalescing * 3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(controller.mascot.phase, .waiting)
        XCTAssertLessThan(AppController.refreshCoalescing, 1.5,
                          "a window as long as the poll interval would buy nothing")
    }

    /// A status line's report goes to the usage provider, stamped with the
    /// controller's clock, and never into the hooks' diagnostics bucket.
    func testAUsageDeliveryReachesTheUsageProviderAndNotTheHookBucket() {
        let controller = AppController()
        let seen = Date(timeIntervalSince1970: 1_790_200_000)
        controller.now = { seen }
        controller.registry.register(controller.claudeUsage)
        let report = UsageReport(windows: [UsageReport.Window(minutes: 300, usedPercent: 40,
                                                              resetsAt: seen + 3600)],
                                 unrecognizedWindows: [])

        controller.handleDelivery(.usage(report))
        XCTAssertEqual(controller.claudeUsage.currentSignals().map(\.updatedAt), [seen])
        XCTAssertEqual(controller.hookDiagnostics.summary, HookDiagnostics().summary,
                       "the hooks' bucket saw nothing")
        let snapshot = controller.registry.snapshot()
        XCTAssertEqual(snapshot.usage.count, 1)
        XCTAssertTrue(snapshot.ordered.isEmpty, "a usage window is not a session")
    }

    // MARK: - Opening reads

    /// A provider whose reading only moves when it is told to.
    private final class ReloadingProvider: Provider, Reloadable {
        let id = "reloading"
        var reloads = 0
        var pending: [Signal] = []
        private var held: [Signal] = []
        func reload() {
            reloads += 1
            held = pending
        }
        func currentSignals() -> [Signal] { held }
    }

    /// The bar opening is the moment a `Reloadable` reads, and what it read
    /// is on the body being opened — not a poll later.
    func testOpeningTheBarReloadsAndScans() {
        let controller = AppController()
        let provider = ReloadingProvider()
        controller.registry.register(provider)
        provider.pending = [signal(.waiting)]
        controller.refresh()
        XCTAssertEqual(provider.reloads, 0, "a poll never reloads")
        XCTAssertEqual(controller.mascot.phase, .idle, "nothing read yet")

        controller.openBar()
        XCTAssertEqual(provider.reloads, 1)
        XCTAssertEqual(controller.mascot.phase, .waiting, "the new reading was scanned at once")

        controller.closeBar()
        controller.refresh()
        XCTAssertEqual(provider.reloads, 1, "closing and polling read nothing")
    }
}
