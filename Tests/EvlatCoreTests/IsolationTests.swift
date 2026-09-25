import XCTest
@testable import EvlatCore

/// `014`'s one isolation predicate and the setup's opening condition.
final class IsolationTests: XCTestCase {
    func testAnyEvlatKeyIsolatesButTheTaskMarker() {
        XCTAssertFalse(Isolation.isIsolated([:]))
        XCTAssertFalse(Isolation.isIsolated(["HOME": "/x", "PATH": "/bin"]))
        XCTAssertFalse(Isolation.isIsolated(["EVLAT_TASK": "abc"]), "Evlat's own chats carry it")
        XCTAssertTrue(Isolation.isIsolated(["EVLAT_FOO": "1"]), "a variable no list knows yet")
        XCTAssertTrue(Isolation.isIsolated(["EVLAT_PORT": "48999"]))
        XCTAssertTrue(Isolation.isIsolated(["EVLAT_HOME": "/tmp/x", "EVLAT_TASK": "t"]))
        XCTAssertTrue(Isolation.isIsolated(["EVLAT_EDGE": ""]), "set, even blank, is asked for")
        XCTAssertFalse(Isolation.isIsolated(["XEVLAT_PORT": "1", "evlat_port": "1"]))
    }
}

final class SetupTriggerTests: XCTestCase {
    private func opens(storage: Bool = true, seen: Bool = false, edge: Bool = false,
                       hooks: [HookSettings.State] = [.missing, .missing],
                       environment: [String: String] = [:]) -> Bool {
        SetupTrigger.shouldOpen(hasStorage: storage, seen: seen, hasStoredEdge: edge,
                                hookStates: hooks, environment: environment)
    }

    func testANewUserSeesItOnce() {
        XCTAssertTrue(opens())
        XCTAssertTrue(opens(hooks: []), "no agent at all is nothing set up")
        XCTAssertFalse(opens(seen: true), "shown before")
    }

    func testEachArmKeepsItShut() {
        XCTAssertFalse(opens(storage: false), "nothing would remember it was shown")
        XCTAssertFalse(opens(edge: true), "an edge was chosen: a v1 user")
        XCTAssertFalse(opens(hooks: [.missing, .current]))
        XCTAssertFalse(opens(hooks: [.outdated]), "an old command is installed")
        XCTAssertFalse(opens(environment: ["EVLAT_PORT": "48999"]))
        XCTAssertFalse(opens(environment: ["EVLAT_FOO": "1"]))
        XCTAssertTrue(opens(environment: ["EVLAT_TASK": "t"]))
    }
}
