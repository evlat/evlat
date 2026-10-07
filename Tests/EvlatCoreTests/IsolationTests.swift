import XCTest
@testable import EvlatCore

/// The one isolation predicate and the setup's opening condition.
final class IsolationTests: XCTestCase {
    func testAnyEvlatKeyIsolatesButTheTaskMarker() {
        XCTAssertFalse(Isolation.isIsolated([:]))
        XCTAssertFalse(Isolation.isIsolated(["HOME": "/x", "PATH": "/bin"]))
        XCTAssertFalse(Isolation.isIsolated(["EVLAT_TASK": "abc"]), "Evlat's own chats carry it")
        XCTAssertTrue(Isolation.isIsolated(["EVLAT_FOO": "1"]), "a variable no list knows yet")
        XCTAssertTrue(Isolation.isIsolated(["EVLAT_SOCKET": "/tmp/e.sock"]))
        XCTAssertTrue(Isolation.isIsolated(["EVLAT_HOME": "/tmp/x", "EVLAT_TASK": "t"]))
        XCTAssertTrue(Isolation.isIsolated(["EVLAT_EDGE": ""]), "set, even blank, is asked for")
        XCTAssertFalse(Isolation.isIsolated(["XEVLAT_SOCKET": "1", "evlat_socket": "1"]))
    }

    /// A second Evlat is one predicate: its own socket, set and not blank.
    /// A moved home or sessions folder moves files, not whose Evlat it is.
    func testASecondEvlatIsOneWithItsOwnSocket() {
        XCTAssertTrue(Isolation.hasOwnSocket(["EVLAT_SOCKET": "/tmp/e.sock"]))
        XCTAssertTrue(Isolation.hasOwnSocket(["EVLAT_SOCKET": "relative.sock"]), "set, even unusable")
        XCTAssertFalse(Isolation.hasOwnSocket(["EVLAT_SOCKET": " "]))
        XCTAssertFalse(Isolation.hasOwnSocket([:]))
        XCTAssertFalse(Isolation.hasOwnSocket(["EVLAT_HOME": "/tmp/h", "EVLAT_SESSIONS": "/tmp/s",
                                               "EVLAT_CHATS": "/tmp/c"]))
    }

    /// The old variable is refused wherever it is set, blank included, and
    /// named in the one line said instead.
    func testTheRetiredPortIsRefused() {
        let old = Isolation.retiredPortKey
        XCTAssertEqual(Isolation.retiredPortLine, "\(old) is gone; use EVLAT_SOCKET")
        XCTAssertTrue(Isolation.setsRetiredPort([old: "48999"]))
        XCTAssertTrue(Isolation.setsRetiredPort([old: ""]))
        XCTAssertFalse(Isolation.setsRetiredPort(["EVLAT_SOCKET": "/tmp/e.sock"]))
        for argv in [["Evlat"], ["Evlat", "--list"], ["Evlat", "watch", "true"], ["Evlat", "signal", "x", "--done"],
                     ["Evlat", "--help"], ["/x/evlat"]] {
            XCTAssertEqual(LaunchMode.of(argv, environment: [old: "48999"]), .refused(Isolation.retiredPortLine),
                           "\(argv)")
        }
        let mark = [Askpass.environmentKey: String(repeating: "a", count: 64) + ":/tmp/e.sock", old: "1"]
        XCTAssertEqual(LaunchMode.of(["Evlat", "Password:"], environment: mark), .refused(Isolation.retiredPortLine))
    }

    /// The built binary says the one line on stderr, nothing on stdout, and
    /// exits non-zero — before a command runs or the usage is printed.
    func testTheBuiltBinaryRefusesTheRetiredPort() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Evlat")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "no built binary")
        for arguments in [["--help"], ["signal", "probe", "--done"], ["watch", "true"]] {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            // Anything that ran anyway would find no socket of the user's.
            process.environment = [Isolation.retiredPortKey: "48999", "EVLAT_SOCKET": "relative.sock",
                                   "PATH": "/usr/bin:/bin"]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 2, "\(arguments)")
            XCTAssertEqual(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                           "Evlat: \(Isolation.retiredPortLine)\n", "\(arguments)")
            XCTAssertTrue(out.fileHandleForReading.readDataToEndOfFile().isEmpty, "\(arguments)")
        }
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
        XCTAssertFalse(opens(environment: ["EVLAT_SOCKET": "/tmp/e.sock"]))
        XCTAssertFalse(opens(environment: ["EVLAT_FOO": "1"]))
        XCTAssertTrue(opens(environment: ["EVLAT_TASK": "t"]))
    }
}

/// Settings → Agents opens once by itself after the cut to the socket, for
/// someone whose agents still hold the bytes from before it.
final class AgentsAfterTheSocketTests: XCTestCase {
    private func opens(storage: Bool = true, shown: Bool = false, old: Bool = true, setup: Bool = false,
                       environment: [String: String] = [:]) -> Bool {
        SetupTrigger.opensAgents(hasStorage: storage, shown: shown, predatesSocket: old,
                                 opensSetup: setup, environment: environment)
    }

    func testOldBytesOpenItOnce() {
        XCTAssertTrue(opens())
        XCTAssertFalse(opens(shown: true), "shown before")
        XCTAssertFalse(opens(old: false), "nothing from before the socket")
    }

    func testEachArmKeepsItShut() {
        XCTAssertFalse(opens(storage: false), "nothing would remember it was shown")
        XCTAssertFalse(opens(setup: true), "the setup opens instead")
        XCTAssertFalse(opens(environment: ["EVLAT_SOCKET": "/tmp/e.sock"]), "a second Evlat")
        XCTAssertFalse(opens(environment: ["EVLAT_HOME": "/tmp/h"]))
        XCTAssertTrue(opens(environment: ["EVLAT_TASK": "t"]))
    }
}
