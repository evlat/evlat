import XCTest
@testable import EvlatCore

/// The switch's rule (`EnabledAgents`) and where the registry applies it.
final class EnabledAgentsTests: XCTestCase {
    // MARK: - The set

    /// Three stand-ins, in the catalogue's order.
    private let catalog: [AgentID] = [.test, .other, .third]

    func testNothingStoredIsTheAgentsFoundAskedEachTime() {
        var found: Set<AgentID> = [.test]
        let present = { (source: AgentID) in found.contains(source) }
        XCTAssertEqual(EnabledAgents.resolve(stored: nil, catalog: catalog, isPresent: present), [.test])
        // Installed later: on without anything written.
        found.insert(.other)
        XCTAssertEqual(EnabledAgents.resolve(stored: nil, catalog: catalog, isPresent: present), [.test, .other])
    }

    func testAStoredSetIsTheAnswerWhateverIsFound() {
        XCTAssertEqual(EnabledAgents.resolve(stored: ["other"], catalog: catalog, isPresent: { _ in true }), [.other])
        XCTAssertEqual(EnabledAgents.resolve(stored: [], catalog: catalog, isPresent: { _ in true }), [])
        XCTAssertEqual(EnabledAgents.resolve(stored: ["third"], catalog: catalog, isPresent: { _ in false }), [.third])
    }

    func testAnUnknownNameIsSkipped() {
        XCTAssertEqual(EnabledAgents.resolve(stored: ["test", "someday"], catalog: catalog, isPresent: { _ in false }),
                       [.test])
    }

    func testTheStoredValueIsInTheCataloguesOrder() {
        XCTAssertEqual(EnabledAgents.stored([.third, .test], catalog: catalog), ["test", "third"])
    }

    func testAChangeIsWrittenAndRepeatingTheDefaultIsNot() {
        let present = { (source: AgentID) in source != .third }
        XCTAssertNil(EnabledAgents.changing(.test, to: true, stored: nil, catalog: catalog, isPresent: present),
                     "on is what it already is: the default stays live")
        XCTAssertEqual(EnabledAgents.changing(.test, to: false, stored: nil, catalog: catalog, isPresent: present),
                       ["other"])
        XCTAssertEqual(EnabledAgents.changing(.third, to: true, stored: ["other"], catalog: catalog, isPresent: present),
                       ["other", "third"])
        XCTAssertNil(EnabledAgents.changing(.test, to: false, stored: ["other"], catalog: catalog, isPresent: present))
    }

    func testANameThisBuildDoesNotKnowIsCarried() {
        XCTAssertEqual(EnabledAgents.changing(.other, to: true, stored: ["test", "someday"], catalog: catalog,
                                              isPresent: { _ in true }),
                       ["test", "other", "someday"])
    }

    func testTheSnapshotNamesTheRowsSwitchedOff() {
        let registry = registry([row("c1", .review, .official, source: .other),
                                 row("a1", .working, .official, source: .test)])
        registry.enabledSources = { [.test] }
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

    private func row(_ entity: String, _ phase: Phase, _ fidelity: Signal.Fidelity, source: AgentID?,
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
        let registry = registry([row("c1", .working, .official, source: .other),
                                 row("a1", .working, .official, source: .test)])
        registry.enabledSources = { [.test] }
        XCTAssertEqual(registry.snapshot().ordered.map(\.entity), ["a1"])
        registry.enabledSources = { [.test, .other] }
        XCTAssertEqual(Set(registry.snapshot().ordered.map(\.entity)), ["a1", "c1"], "on again, it is back")
    }

    func testTheFileRowAndTheHookRowGoTogetherAndComeBackMerged() {
        let file = row("s1", .idle, .derived, source: .test, label: "the file's name")
        let hook = row("s1", .review, .official, source: .test)
        let registry = registry([file], [hook])
        registry.enabledSources = { [] }
        XCTAssertEqual(registry.snapshot().ordered, [])
        registry.enabledSources = { [.test] }
        let rows = registry.snapshot().ordered
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.phase, .review, "the merge is the same with the filter on")
        XCTAssertEqual(rows.first?.label, "the file's name")
    }

    func testOnlySessionsAreFiltered() {
        let usage = Signal(provider: "u", entity: "usage:Claude:300", kind: .usage, phase: .idle, label: "5h",
                           source: .test, fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
                           usage: Signal.Usage(group: "Claude", windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 0)))
        let job = row("evlat:1", .working, .official, source: .test, kind: .job)
        let registry = registry([usage, job])
        registry.enabledSources = { [] }
        let snapshot = registry.snapshot()
        XCTAssertEqual(snapshot.usage.map(\.entity), ["usage:Claude:300"], "usage leaves with its provider")
        XCTAssertEqual(snapshot.ordered.map(\.entity), ["evlat:1"])
    }

    func testARowWithNoAgentAndARemoteMachinesRowPass() {
        let registry = registry([row("x", .working, .official, source: nil),
                                 row("remote:m:s", .working, .official, source: .test,
                                     machine: Signal.Machine(name: "devbox"))])
        registry.enabledSources = { [] }
        XCTAssertEqual(Set(registry.snapshot().ordered.map(\.entity)), ["x", "remote:m:s"])
    }

    /// A machine's row answers to that machine's set, by its id; the same
    /// rule, never this Mac's set, and a switched-off row is held back,
    /// not lost.
    func testAMachinesRowAnswersToTheMachinesSet() {
        let remote = row("remote:m:s", .working, .official, source: .test,
                         machine: Signal.Machine(name: "devbox", id: "m"))
        let other = row("remote:n:s", .working, .official, source: .test,
                        machine: Signal.Machine(name: "box", id: "n"))
        let registry = registry([remote, other, row("c1", .working, .official, source: .test)])
        registry.machineSources = { $0 == "m" ? [.other] : nil }
        XCTAssertEqual(Set(registry.snapshot().ordered.map(\.entity)), ["remote:n:s", "c1"])
        XCTAssertEqual(registry.snapshot().switchedOff, ["remote:m:s"])
        XCTAssertEqual(Set(registry.signals().map(\.entity)), ["remote:n:s", "c1"])
        registry.machineSources = { _ in [.test] }
        registry.enabledSources = { [] }
        XCTAssertEqual(Set(registry.snapshot().ordered.map(\.entity)), ["remote:m:s", "remote:n:s"],
                       "this Mac's set is this Mac's alone")
    }

    func testNoSetDrawsEveryAgent() {
        let registry = registry([row("c1", .working, .official, source: .other)])
        XCTAssertEqual(registry.snapshot().ordered.map(\.entity), ["c1"])
    }
}
