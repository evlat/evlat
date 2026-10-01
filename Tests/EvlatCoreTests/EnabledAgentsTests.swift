import XCTest
@testable import EvlatCore

/// The switch's rule (`EnabledAgents`) and where the registry applies it.
final class EnabledAgentsTests: XCTestCase {
    // MARK: - The set

    func testNothingStoredIsTheAgentsFoundAskedEachTime() {
        var found: Set<AgentSource> = [.claude]
        let present = { (source: AgentSource) in found.contains(source) }
        XCTAssertEqual(EnabledAgents.resolve(stored: nil, isPresent: present), [.claude])
        // Installed later: on without anything written.
        found.insert(.codex)
        XCTAssertEqual(EnabledAgents.resolve(stored: nil, isPresent: present), [.claude, .codex])
    }

    func testAStoredSetIsTheAnswerWhateverIsFound() {
        XCTAssertEqual(EnabledAgents.resolve(stored: ["codex"], isPresent: { _ in true }), [.codex])
        XCTAssertEqual(EnabledAgents.resolve(stored: [], isPresent: { _ in true }), [])
        XCTAssertEqual(EnabledAgents.resolve(stored: ["antigravity"], isPresent: { _ in false }), [.antigravity])
    }

    func testAnUnknownNameIsSkipped() {
        XCTAssertEqual(EnabledAgents.resolve(stored: ["claude", "someday"], isPresent: { _ in false }), [.claude])
    }

    func testTheStoredValueIsInTheCataloguesOrder() {
        XCTAssertEqual(EnabledAgents.stored([.antigravity, .claude]), ["claude", "antigravity"])
    }

    func testAChangeIsWrittenAndRepeatingTheDefaultIsNot() {
        let present = { (source: AgentSource) in source != .antigravity }
        XCTAssertNil(EnabledAgents.changing(.claude, to: true, stored: nil, isPresent: present),
                     "on is what it already is: the default stays live")
        XCTAssertEqual(EnabledAgents.changing(.claude, to: false, stored: nil, isPresent: present), ["codex"])
        XCTAssertEqual(EnabledAgents.changing(.antigravity, to: true, stored: ["codex"], isPresent: present),
                       ["codex", "antigravity"])
        XCTAssertNil(EnabledAgents.changing(.claude, to: false, stored: ["codex"], isPresent: present))
    }

    func testANameThisBuildDoesNotKnowIsCarried() {
        XCTAssertEqual(EnabledAgents.changing(.codex, to: true, stored: ["claude", "someday"], isPresent: { _ in true }),
                       ["claude", "codex", "someday"])
    }

    func testTheSnapshotNamesTheRowsSwitchedOff() {
        let registry = registry([row("c1", .review, .official, source: .codex),
                                 row("a1", .working, .official, source: .claude)])
        registry.enabledSources = { [.claude] }
        let snapshot = registry.snapshot()
        XCTAssertEqual(snapshot.switchedOff, ["c1"])
        XCTAssertNil(snapshot.layers["c1"])
    }

    // MARK: - The registry's filter

    private struct Stub: Provider {
        let id: String
        let signals: [Signal]
        func currentSignals() -> [Signal] { signals }
    }

    private func row(_ entity: String, _ phase: Phase, _ fidelity: Signal.Fidelity, source: AgentSource?,
                     kind: Signal.Kind = .session, label: String = "hook", rawStatus: String? = "said-so",
                     machine: Signal.Machine? = nil) -> Signal {
        Signal(provider: "stub", entity: entity, kind: kind, phase: phase, label: label, source: source,
               fidelity: fidelity, rawStatus: rawStatus, updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
               machine: machine)
    }

    private func registry(_ signals: [Signal]...) -> Registry {
        let registry = Registry()
        for (index, group) in signals.enumerated() { registry.register(Stub(id: "stub-\(index)", signals: group)) }
        return registry
    }

    func testAnAgentOffOpensNoRow() {
        let registry = registry([row("c1", .working, .official, source: .codex),
                                 row("a1", .working, .official, source: .claude)])
        registry.enabledSources = { [.claude] }
        XCTAssertEqual(registry.snapshot().ordered.map(\.entity), ["a1"])
        registry.enabledSources = { [.claude, .codex] }
        XCTAssertEqual(Set(registry.snapshot().ordered.map(\.entity)), ["a1", "c1"], "on again, it is back")
    }

    func testTheFileRowAndTheHookRowGoTogetherAndComeBackMerged() {
        let file = row("s1", .idle, .derived, source: .claude, label: "the file's name")
        let hook = row("s1", .review, .official, source: .claude)
        let registry = registry([file], [hook])
        registry.enabledSources = { [] }
        XCTAssertEqual(registry.snapshot().ordered, [])
        registry.enabledSources = { [.claude] }
        let rows = registry.snapshot().ordered
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.phase, .review, "the merge is the same with the filter on")
        XCTAssertEqual(rows.first?.label, "the file's name")
    }

    func testOnlySessionsAreFiltered() {
        let usage = Signal(provider: "u", entity: "usage:Claude:300", kind: .usage, phase: .idle, label: "5h",
                           source: .claude, fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
                           usage: Signal.Usage(group: "Claude", windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 0)))
        let job = row("evlat:1", .working, .official, source: .claude, kind: .job)
        let registry = registry([usage, job])
        registry.enabledSources = { [] }
        let snapshot = registry.snapshot()
        XCTAssertEqual(snapshot.usage.map(\.entity), ["usage:Claude:300"], "usage leaves with its provider")
        XCTAssertEqual(snapshot.ordered.map(\.entity), ["evlat:1"])
    }

    func testARowWithNoAgentAndARemoteMachinesRowPass() {
        let registry = registry([row("x", .working, .official, source: nil),
                                 row("remote:m:s", .working, .official, source: .claude,
                                     machine: Signal.Machine(name: "devbox"))])
        registry.enabledSources = { [] }
        XCTAssertEqual(Set(registry.snapshot().ordered.map(\.entity)), ["x", "remote:m:s"])
    }

    /// A machine's row answers to that machine's set, by its id; the same
    /// rule, never this Mac's set, and a switched-off row is held back,
    /// not lost.
    func testAMachinesRowAnswersToTheMachinesSet() {
        let remote = row("remote:m:s", .working, .official, source: .claude,
                         machine: Signal.Machine(name: "devbox", id: "m"))
        let other = row("remote:n:s", .working, .official, source: .claude,
                        machine: Signal.Machine(name: "box", id: "n"))
        let registry = registry([remote, other, row("c1", .working, .official, source: .claude)])
        registry.machineSources = { $0 == "m" ? [.codex] : nil }
        XCTAssertEqual(Set(registry.snapshot().ordered.map(\.entity)), ["remote:n:s", "c1"])
        XCTAssertEqual(registry.snapshot().switchedOff, ["remote:m:s"])
        XCTAssertEqual(Set(registry.signals().map(\.entity)), ["remote:n:s", "c1"])
        registry.machineSources = { _ in [.claude] }
        registry.enabledSources = { [] }
        XCTAssertEqual(Set(registry.snapshot().ordered.map(\.entity)), ["remote:m:s", "remote:n:s"],
                       "this Mac's set is this Mac's alone")
    }

    func testNoSetDrawsEveryAgent() {
        let registry = registry([row("c1", .working, .official, source: .codex)])
        XCTAssertEqual(registry.snapshot().ordered.map(\.entity), ["c1"])
    }
}
