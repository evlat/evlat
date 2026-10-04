import XCTest
@testable import EvlatApp

/// Asking a terminal whether the user is at a session's tab (`TabFocus`),
/// against a **fake `bateri`** (`Tests/Fixtures/fake-bateri`): the real one
/// is never run from a test.
final class TabFocusTests: XCTestCase {
    static let tab = "bateri://tab/85353B2C-0564-41A3-9E4A-52DC53B00316"
    var bateri: SessionHost.App {
        SessionHost.App(bundleID: "dev.bateri.bateri", name: "Bateri", pid: 580, tab: URL(string: Self.tab))
    }

    // MARK: The answer

    /// Read as Bateri's own parser reads it.
    func testTheLineIsReadAsTheProgramReadsIt() {
        XCTAssertEqual(TabFocus.parse("pane=live focused=1 idle=4"), .init(focused: true, idle: 4))
        XCTAssertEqual(TabFocus.parse("pane=live idle=7 future=x focused=0"), .init(focused: false, idle: 7),
                       "a token it does not know is skipped")
        for line in ["pane=none", "pane=unknown", "", "pane=live", "pane=live focused=1", "pane=live idle=3",
                     "pane=live focused=2 idle=3", "pane=live focused=1 idle=-1", "pane=live focused=1 idle=+3",
                     "pane=live focused=1 idle=", "pane=live focused=1 idle=3x", "focused=1 pane=live idle=3",
                     "pane=live focused=1 idle=3\t", "pane=live focused=1 idle=٣"] {
            XCTAssertNil(TabFocus.parse(Substring(line)), line)
        }
    }

    func testAtThePaneIsFocusedRecentAndUnlocked() {
        XCTAssertTrue(TabFocus.isAtPane(.init(focused: true, idle: 0), locked: false))
        XCTAssertTrue(TabFocus.isAtPane(.init(focused: true, idle: TabFocus.idleLimit), locked: false))
        XCTAssertFalse(TabFocus.isAtPane(.init(focused: true, idle: TabFocus.idleLimit + 1), locked: false))
        XCTAssertFalse(TabFocus.isAtPane(.init(focused: false, idle: 0), locked: false))
        XCTAssertFalse(TabFocus.isAtPane(.init(focused: true, idle: 0), locked: true),
                       "a locked screen leaves the pane focused")
        XCTAssertFalse(TabFocus.isAtPane(nil, locked: false))
    }

    func testAMissingLockKeyIsUnlockedAndAnUnreadableDictionaryIsLocked() {
        XCTAssertFalse(ScreenLock.isLocked(["kCGSSessionOnConsoleKey": 1]), "measured: no key while unlocked")
        XCTAssertFalse(ScreenLock.isLocked([ScreenLock.key: 0]))
        XCTAssertTrue(ScreenLock.isLocked([ScreenLock.key: 1]))
        XCTAssertTrue(ScreenLock.isLocked([ScreenLock.key: true]))
        XCTAssertTrue(ScreenLock.isLocked([ScreenLock.key: "yes"]), "a value it cannot read")
        XCTAssertTrue(ScreenLock.isLocked(nil))
    }

    // MARK: The gate

    func testVersionsCompareByTheirNumbers() {
        XCTAssertFalse(TabFocus.isAtLeast("0.3.0", "0.4.0"))
        XCTAssertTrue(TabFocus.isAtLeast("0.4.0", "0.4.0"))
        XCTAssertTrue(TabFocus.isAtLeast("0.4", "0.4.0"))
        XCTAssertTrue(TabFocus.isAtLeast("0.5.0", "0.4.0"))
        XCTAssertTrue(TabFocus.isAtLeast("0.10.0", "0.4.0"), "not by its letters")
        XCTAssertTrue(TabFocus.isAtLeast("1.0", "0.4.0"))
        for version in ["", "x", "0.4.0-beta", "0..4", "0.4.", ".4", "v0.4.0", "0.4.0 "] {
            XCTAssertFalse(TabFocus.isAtLeast(version, "0.4.0"), version)
        }
    }

    /// The version is the running copy's file's, read again at each question:
    /// an app put back to an older version is never asked.
    func testTheGateReadsTheVersionFromDiskEachTime() throws {
        let app = try fakeApp(version: "0.3.0")
        XCTAssertNil(query(app))
        try writeVersion("0.4.0", in: app.bundle)
        XCTAssertEqual(query(app), TabFocus.Query(executable: app.executable,
                                                  arguments: ["focus", "--pid", "580", Self.tab],
                                                  environment: ["HOME": app.home.path]))
        try writeVersion("0.3.9", in: app.bundle)
        XCTAssertNil(query(app))
        try writeVersion("soon", in: app.bundle)
        XCTAssertNil(query(app))
        try FileManager.default.removeItem(at: app.bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(query(app))
    }

    /// Only an app the table can ask, about its own tab link.
    func testOnlyAnAppThatCanBeAskedIsAsked() throws {
        let app = try fakeApp(version: "0.5.0")
        var metalterm = SessionHost.App(bundleID: "dev.metalterm.Metalterm", name: "Metalterm", pid: 500)
        metalterm.tab = URL(string: "metalterm://tab/0123456789abcdef")
        XCTAssertNil(TabFocus.query(for: metalterm, executable: app.executable, bundle: app.bundle, home: "/h"))
        var untabbed = bateri
        untabbed.tab = nil
        XCTAssertNil(TabFocus.query(for: untabbed, executable: app.executable, bundle: app.bundle, home: "/h"))
        for link in ["bateri://tab/restart", "bateri://tab/85353B2C?x=1", "metalterm://tab/0123456789abcdef"] {
            var other = bateri
            other.tab = URL(string: link)
            XCTAssertNil(TabFocus.query(for: other, executable: app.executable, bundle: app.bundle, home: "/h"), link)
        }
        XCTAssertNil(TabFocus.query(for: bateri, executable: nil, bundle: app.bundle, home: "/h"))
        XCTAssertNil(TabFocus.query(for: bateri, executable: app.executable, bundle: nil, home: "/h"))
        XCTAssertNotNil(TabFocus.query(for: bateri, executable: app.executable, bundle: app.bundle, home: "/h"))
    }

    // MARK: Asking

    /// Its fixed arguments, and of Evlat's environment `HOME` alone.
    func testTheProgramIsAskedWithItsArgumentsAndHomeAlone() throws {
        let app = try fakeApp(version: "0.4.0")
        try answer("pane=live focused=1 idle=4", in: app.home)
        let query = try XCTUnwrap(query(app))
        XCTAssertEqual(TabFocus.run(query), .init(focused: true, idle: 4))
        let log = try String(contentsOf: app.home.appendingPathComponent("fake-bateri/log"), encoding: .utf8)
        let lines = log.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(6)), ["--- run", "focus", "--pid", "580", Self.tab, "--- env"])
        // What `sh` sets for itself is the shell's, not Evlat's.
        let names = Set(lines.dropFirst(6)).subtracting(["PWD", "OLDPWD", "SHLVL", "_"])
        XCTAssertEqual(names, ["HOME"])
    }

    /// No answer, an unknown one, a failed exit: no reading. The answer is
    /// the first line.
    func testAnythingButAnAnswerIsNoReading() throws {
        let app = try fakeApp(version: "0.4.0")
        let query = try XCTUnwrap(query(app))
        let cases: [(String, Int, TabFocus.Reading?)] = [
            ("pane=none", 0, nil), ("pane=unknown", 3, nil), ("pane=live focused=1 idle=4", 2, nil), ("", 0, nil),
            ("pane=live focused=1 idle=4\npane=none", 0, .init(focused: true, idle: 4)),
            ("pane=none\npane=live focused=1 idle=4", 0, nil),
        ]
        for (line, code, expected) in cases {
            try answer(line, code: code, in: app.home)
            XCTAssertEqual(TabFocus.run(query), expected, "\(line) → \(code)")
        }
    }

    /// A program that does not answer is killed at the deadline, and the
    /// question still ends.
    func testAStuckProgramIsKilledAtItsDeadline() throws {
        let app = try fakeApp(version: "0.4.0")
        let dir = app.home.appendingPathComponent("fake-bateri")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("hang").path, contents: Data())
        let query = try XCTUnwrap(query(app))
        let start = Date()
        XCTAssertNil(TabFocus.run(query, deadline: 0.5))
        // Room for a loaded machine; the fake waits 30 s.
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        let pid = try XCTUnwrap(Int32(String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let gone = expectation(description: "the fake is gone")
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if kill(pid, 0) != 0 { gone.fulfill(); return }
                usleep(50_000)
            }
        }
        wait(for: [gone], timeout: 10)
    }

    /// Answered on the main queue, once; the lock read only for a reading.
    func testAQuestionIsAnsweredOnceOnTheMainQueue() throws {
        let query = TabFocus.Query(executable: URL(fileURLWithPath: "/nonexistent"), arguments: [], environment: [:])
        let cases: [(TabFocus.Reading?, Bool, Bool)] = [(.init(focused: true, idle: 3), false, true),
                                                        (.init(focused: true, idle: 3), true, false),
                                                        (.init(focused: false, idle: 3), false, false),
                                                        (nil, false, false)]
        for (reading, locked, expected) in cases {
            let answered = expectation(description: "\(String(describing: reading)) \(locked)")
            var lockRead = false
            TabFocus.ask(query, run: { _ in reading }, locked: { lockRead = true; return locked }) { at in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(at, expected)
                answered.fulfill()
            }
            wait(for: [answered], timeout: 5)
            if reading == nil { XCTAssertFalse(lockRead, "no reading, no lock to read") }
        }
        // The real program behind a missing path: no reading, and an answer.
        let missing = expectation(description: "missing program")
        TabFocus.ask(query) { at in
            XCTAssertFalse(at)
            missing.fulfill()
        }
        wait(for: [missing], timeout: 5)
    }

    // MARK: - The fake

    struct FakeApp {
        let bundle: URL
        let executable: URL
        let home: URL
    }

    /// A `Bateri.app` in a temporary folder whose program is the fake,
    /// copied and warmed, and a home of its own for the fake's knobs.
    func fakeApp(version: String) throws -> FakeApp {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evlat-tabfocus-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Bateri.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-bateri")
        let executable = macOS.appendingPathComponent("bateri")
        try FileManager.default.copyItem(at: fixture, to: executable)
        FreshExecutable.warm(executable.path)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("fake-bateri"),
                                                withIntermediateDirectories: true)
        try writeVersion(version, in: bundle)
        return FakeApp(bundle: bundle, executable: executable, home: home)
    }

    func writeVersion(_ version: String, in bundle: URL) throws {
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.bateri.bateri", "CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    func answer(_ line: String, code: Int = 0, in home: URL) throws {
        let dir = home.appendingPathComponent("fake-bateri")
        try (line.isEmpty ? "" : line + "\n").write(to: dir.appendingPathComponent("reply"), atomically: true, encoding: .utf8)
        try "\(code)\n".write(to: dir.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
    }

    func query(_ app: FakeApp) -> TabFocus.Query? {
        TabFocus.query(for: bateri, executable: app.executable, bundle: app.bundle, home: app.home.path)
    }
}
