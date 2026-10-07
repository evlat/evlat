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
    /// named in the one line said instead — but for `watch` and `signal`,
    /// which run and only post nothing (`WatchTests`): a wrapped command
    /// must run whatever the environment says.
    func testTheRetiredPortIsRefused() {
        let old = Isolation.retiredPortKey
        XCTAssertEqual(Isolation.retiredPortLine, "\(old) is gone; use EVLAT_SOCKET")
        XCTAssertTrue(Isolation.setsRetiredPort([old: "48999"]))
        XCTAssertTrue(Isolation.setsRetiredPort([old: ""]))
        XCTAssertFalse(Isolation.setsRetiredPort(["EVLAT_SOCKET": "/tmp/e.sock"]))
        for argv in [["Evlat"], ["Evlat", "--list"], ["Evlat", "--capture", "5"], ["Evlat", "--help"],
                     ["Evlat", "nonsense"], ["/x/evlat"]] {
            XCTAssertEqual(LaunchMode.of(argv, environment: [old: "48999"]), .refused(Isolation.retiredPortLine),
                           "\(argv)")
        }
        for argv in [["Evlat", "watch", "true"], ["Evlat", "signal", "x", "--done"], ["/x/evlat", "watch", "--list"]] {
            XCTAssertEqual(LaunchMode.of(argv, environment: [old: ""]), .command, "\(argv)")
        }
        let mark = [Askpass.environmentKey: String(repeating: "a", count: 64) + ":/tmp/e.sock", old: "1"]
        XCTAssertEqual(LaunchMode.of(["Evlat", "Password:"], environment: mark), .refused(Isolation.retiredPortLine))
    }

    /// The built binary says the one line on stderr, nothing on stdout, and
    /// exits non-zero — before the diagnostics run or the usage is printed.
    func testTheBuiltBinaryRefusesTheRetiredPort() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Evlat")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "no built binary")
        for arguments in [["--help"], ["--list"]] {
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

/// What the update window does at launch: with automatic updates off it
/// opens while an agent switched on here holds Evlat's old parts; with them
/// on, Evlat updates them itself instead. Never beside the setup, never in
/// an isolated process.
final class UpdatesAtLaunchTests: XCTestCase {
    private func launch(storage: Bool = true, automatic: Bool = false, outdated: Bool = true, setup: Bool = false,
                        environment: [String: String] = [:]) -> SetupTrigger.UpdatesAtLaunch {
        SetupTrigger.updatesAtLaunch(hasStorage: storage, automatic: automatic, outdated: outdated,
                                     opensSetup: setup, environment: environment)
    }

    func testOldPartsOpenTheWindowAtEveryLaunchWhileAutomaticIsOff() {
        XCTAssertEqual(launch(), .window, "not once: each launch with something old")
        XCTAssertEqual(launch(outdated: false), .nothing, "nothing old")
    }

    func testAutomaticUpdatesInsteadOfOpening() {
        XCTAssertEqual(launch(automatic: true), .automatic)
        XCTAssertEqual(launch(automatic: true, outdated: false), .nothing)
    }

    func testEachArmKeepsItShut() {
        for automatic in [false, true] {
            XCTAssertEqual(launch(storage: false, automatic: automatic), .nothing, "every test's controller")
            XCTAssertEqual(launch(automatic: automatic, setup: true), .nothing, "the setup shows the same cards")
            XCTAssertEqual(launch(automatic: automatic, environment: ["EVLAT_SOCKET": "/tmp/e.sock"]), .nothing,
                           "a second Evlat writes nothing of the user's")
            XCTAssertEqual(launch(automatic: automatic, environment: ["EVLAT_HOME": "/tmp/h"]), .nothing)
        }
        XCTAssertEqual(launch(environment: ["EVLAT_TASK": "t"]), .window)
    }

    /// Automatic updates open the window only for what is left to the user.
    func testTheResultsOpenOnlyForAStepOrAFailure() {
        XCTAssertFalse(SetupTrigger.opensResults(failed: false, stepLeft: false), "silent")
        XCTAssertTrue(SetupTrigger.opensResults(failed: false, stepLeft: true), "Codex's /hooks")
        XCTAssertTrue(SetupTrigger.opensResults(failed: true, stepLeft: false), "a write refused")
    }
}
