import XCTest
@testable import EvlatCore

/// A usage window is a `Signal` like any other, and the one thing it must
/// never do is reach the session line: the mascot, the rings and `hasLive`.
///
/// The providers are stubs, as in `RegistryTests`: the split has to hold for
/// sources that do not exist yet, which is what the third provider below is.
final class UsageSignalTests: XCTestCase {
    private struct StubProvider: Provider {
        let id: String
        let signals: [Signal]
        func currentSignals() -> [Signal] { signals }
    }

    private let observed = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ entity: String, _ phase: Phase,
                         _ fidelity: Signal.Fidelity = .official,
                         rawStatus: String? = "said-so",
                         usage: Signal.Usage? = nil) -> Signal {
        Signal(provider: "stub", entity: entity, phase: phase, label: entity,
               fidelity: fidelity, rawStatus: rawStatus, updatedAt: observed, usage: usage)
    }

    /// Built the way the contract on `Signal.usage` says a provider builds it.
    /// `phase` is a parameter only so a test can break the contract on purpose.
    private func window(_ provider: String, group: String, minutes: Int, used: Double,
                        phase: Phase = .idle) -> Signal {
        Signal(provider: provider, entity: "usage:\(provider):\(minutes)", kind: .usage,
               phase: phase, progress: used / 100, label: group, fidelity: .derived,
               updatedAt: observed,
               usage: Signal.Usage(group: group, windowMinutes: minutes,
                                   resetsAt: observed.addingTimeInterval(3_600)))
    }

    private func snapshot(_ groups: [Signal]...) -> Registry.Snapshot {
        let registry = Registry()
        for (index, signals) in groups.enumerated() {
            registry.register(StubProvider(id: "stub-\(index)", signals: signals))
        }
        return registry.snapshot()
    }

    func testAUsageOnlySnapshotHasNoSessionLine() {
        let result = snapshot([window("codex-usage", group: "Codex", minutes: 300, used: 42),
                               window("codex-usage", group: "Codex", minutes: 10_080, used: 7)])
        XCTAssertTrue(result.ordered.isEmpty)
        XCTAssertEqual(result.aggregate, .idle)
        XCTAssertFalse(result.hasLive)
        XCTAssertEqual(result.usage.count, 2)
    }

    /// The split is by `kind`. A usage row that breaks its own contract with a
    /// `failed` phase still moves nothing: a split that only worked because
    /// usage rows happen to be `idle` would let this one take the mascot.
    func testUsageStaysOutOfAMixedSessionLine() {
        let result = snapshot([session("s-1", .working), session("s-2", .idle)],
                              [window("claude-usage", group: "Claude", minutes: 300, used: 91,
                                      phase: .failed)])
        XCTAssertEqual(result.ordered.map(\.entity), ["s-1", "s-2"])
        XCTAssertEqual(result.aggregate, .working)
        XCTAssertTrue(result.hasLive)
        XCTAssertEqual(result.usage.map(\.entity), ["usage:claude-usage:300"])
    }

    /// R8's core half: a provider nobody wrote code for gets its own group,
    /// in order, with no branch on its name anywhere.
    func testAThirdProviderTakesItsOwnGroupInOrder() {
        let result = snapshot(
            [window("gemini-test", group: "Gemini", minutes: 1_440, used: 12)],
            [window("codex-usage", group: "Codex", minutes: 10_080, used: 7),
             window("codex-usage", group: "Codex", minutes: 300, used: 42)],
            [window("claude-usage", group: "Claude", minutes: 10_080, used: 30),
             window("claude-usage", group: "Claude", minutes: 300, used: 104)])
        XCTAssertEqual(result.usage.map { "\($0.usage!.group) \($0.usage!.windowMinutes)" },
                       ["Claude 300", "Claude 10080", "Codex 300", "Codex 10080", "Gemini 1440"])
        XCTAssertTrue(result.ordered.isEmpty)
    }

    /// A `.usage` row with no `usage` field is a provider's mistake; it is
    /// kept (last, in entity order) rather than dropped or trapped on.
    func testAUsageRowWithoutItsFieldIsKept() {
        let bare = Signal(provider: "stub", entity: "usage:bare", kind: .usage, phase: .idle,
                          label: "bare", fidelity: .derived, updatedAt: observed)
        let result = snapshot([bare, window("codex-usage", group: "Codex", minutes: 300, used: 1)])
        XCTAssertEqual(result.usage.map(\.entity), ["usage:codex-usage:300", "usage:bare"])
    }

    func testWithActivityCarriesUsage() {
        let signal = window("codex-usage", group: "Codex", minutes: 300, used: 42)
        XCTAssertEqual(signal.with(activity: nil).usage, signal.usage)
        XCTAssertEqual(signal.with(activity: Signal.Activity(pid: 1)).usage, signal.usage)
    }

    /// The admitted branch of `reconcile` rebuilds the row field by field;
    /// that is where a new field gets dropped.
    func testAnAdmittedReportCarriesUsage() {
        let field = Signal.Usage(group: "Stub", windowMinutes: 60, resetsAt: observed)
        let result = snapshot([session("s-1", .working, .derived, rawStatus: "busy")],
                              [session("s-1", .waiting, .official, usage: field)])
        XCTAssertEqual(result.ordered.map(\.phase), [.waiting])
        XCTAssertEqual(result.ordered.first?.usage, field)
    }

    /// And the refused branch keeps the baseline's.
    func testARefusedReportKeepsTheBaselinesUsage() {
        let field = Signal.Usage(group: "Stub", windowMinutes: 60, resetsAt: observed)
        let result = snapshot([session("s-1", .working, .derived, rawStatus: "busy", usage: field)],
                              [session("s-1", .review, .official)])
        XCTAssertEqual(result.ordered.map(\.phase), [.working])
        XCTAssertEqual(result.ordered.first?.usage, field)
    }
}
