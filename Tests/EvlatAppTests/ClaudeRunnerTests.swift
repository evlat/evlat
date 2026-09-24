import XCTest
import EvlatCore
@testable import EvlatApp

/// A chat turn end to end against a **fake `claude`** (`Tests/Fixtures/fake-claude`):
/// the store starts the process, the stream becomes a `kind: .job` row in the
/// registry, the result ends it. The real `claude -p` is never run from a test.
final class ClaudeRunnerTests: XCTestCase {
    private var directory: URL!
    private var store: ChatStore?
    private var extraProcesses: [Process] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Every process started here ends here, even when an assertion failed.
        store?.stopAll()
        store = nil
        extraProcesses.filter(\.isRunning).forEach { $0.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The fixture, copied with its exec bit: a checkout need not keep it.
    private func fakeClaude() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-claude")
        let copy = directory.appendingPathComponent("fake-claude")
        try FileManager.default.copyItem(at: source, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        return copy.path
    }

    private var log: URL { directory.appendingPathComponent("claude.log") }

    /// The fake's scenario and log, handed to the store rather than set on
    /// this process: `setenv` did not reliably reach a later
    /// `ProcessInfo.processInfo.environment`, and a fake that read an earlier
    /// test's scenario hung the next one.
    private func fakeEnvironment(_ scenario: String = "ok") -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_CLAUDE_SCENARIO"] = scenario
        environment["FAKE_CLAUDE_LOG"] = log.path
        return environment
    }

    private func make(scenario: String = "ok", claude: String? = nil, root: URL? = nil,
                      registry: Registry? = nil,
                      platform: Platform = AppController.darwinPlatform) throws -> ChatStore {
        let path = try claude ?? fakeClaude()
        let made = ChatStore(root: root, platform: platform,
                             locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": path]),
                             environment: fakeEnvironment(scenario))
        registry?.register(made.provider)
        store = made
        return made
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10,
                           _ condition: @escaping () -> Bool) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        done.expectationDescription = description
        wait(for: [done], timeout: timeout)
    }

    private func runs() -> [[String]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "--- run\n").dropFirst().map {
            $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    // MARK: - A turn

    func testATurnIsAJobRowFromWorkingToReview() throws {
        let registry = Registry()
        let store = try make(registry: registry)
        let folder = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = store.newChat(folder: folder.path)
        store.perform(.send(chat: id, text: "say ok", attachments: []))

        let row = registry.snapshot().ordered.first
        XCTAssertEqual(row?.kind, .job)
        XCTAssertEqual(row?.entity, "evlat:\(id)")
        XCTAssertEqual(row?.phase, .working, "the row is working from the prompt on")
        XCTAssertTrue(registry.snapshot().hasLive)

        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(registry.snapshot().ordered.map(\.phase), [.review])
        XCTAssertEqual(store.chat(id)?.messages.last, .reply("ok"))
        XCTAssertEqual(registry.snapshot().ordered.first?.activity?.lastReply, "ok")

        let run = try XCTUnwrap(runs().first)
        XCTAssertEqual(Array(run.prefix(7)), Array(ClaudeInvocation.base))
        XCTAssertEqual(Array(run[7...8]), ["--session-id", store.chat(id)!.sessionID])
        XCTAssertTrue(run.contains("EVLAT_TASK=\(id)"), "the errand's id reaches the user's hooks")
        XCTAssertTrue(run.contains { $0.hasPrefix("PWD=") && $0.hasSuffix("/project") })
        XCTAssertTrue(run.contains { $0.hasPrefix("stdin=") && $0.contains(#""content":"say ok""#) })
    }

    func testTheSecondTurnResumesTheSession() throws {
        let store = try make()
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "one", attachments: []))
        waitUntil("the first turn ends") { store.chat(id)?.isRunning == false }
        store.perform(.send(chat: id, text: "two", attachments: []))
        waitUntil("the second turn ends") { store.chat(id)?.isRunning == false && self.runs().count == 2 }
        XCTAssertEqual(Array(runs()[1][7...8]), ["--resume", store.chat(id)!.sessionID])
    }

    func testToolsReachTheChat() throws {
        let store = try make(scenario: "tool")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "list", attachments: []))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.messages.dropFirst().map { $0 }, [
            .tool(id: "toolu_1", name: "Bash", subject: "ls -la", failed: false),
            .reply("Done."),
        ])
        XCTAssertEqual(store.chat(id)?.phase, .review)
    }

    func testAnErrorResultFails() throws {
        let registry = Registry()
        let store = try make(scenario: "error", registry: registry)
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(registry.snapshot().ordered.map(\.phase), [.failed])
        XCTAssertEqual(store.chat(id)?.failure, .result(subtype: "error_during_execution", text: "boom"))
    }

    func testACrashFailsWithTheLastStderrLine() throws {
        let store = try make(scenario: "crash")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the process ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.failure, .exited(status: 3, detail: "fatal: the fake fell over"))
    }

    /// `stop` sends SIGINT; the turn ends as a finished one, not a failure.
    func testStopEndsTheTurn() throws {
        let store = try make(scenario: "slow")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the turn streams") { store.chat(id)?.messages.last == .reply("Working") }
        let pid = try XCTUnwrap(store.processIdentifier(of: id))
        store.perform(.stop(chat: id))
        waitUntil("the turn ends", timeout: 5) { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.phase, .review)
        XCTAssertNil(store.chat(id)?.failure)
        XCTAssertFalse(AppController.isProcessAlive(pid), "the process is gone")
    }

    /// No binary: the chat carries the failure and no process starts.
    func testNoBinaryFailsWithoutAProcess() throws {
        let registry = Registry()
        let store = try make(claude: directory.appendingPathComponent("absent").path, registry: registry)
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        XCTAssertEqual(store.chat(id)?.failure, .noBinary)
        XCTAssertEqual(registry.snapshot().ordered.map(\.phase), [.failed])
        XCTAssertNil(store.processIdentifier(of: id))
        XCTAssertTrue(runs().isEmpty)
    }

    /// The login shell's `PATH` is where a Finder-launched app finds
    /// `claude`; nothing there is the same failure.
    func testTheLoginPathIsSearched() {
        let bin = directory.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let found = ClaudeLocator.find("claude", in: "/nonexistent:\(bin.path)")
        XCTAssertNil(found)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path,
                                       contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(ClaudeLocator.find("claude", in: "/nonexistent:\(bin.path)"),
                       bin.appendingPathComponent("claude").path)
        XCTAssertEqual(ClaudeLocator.markedPath(in: "motd\n\(ClaudeLocator.marker)/a:/b\(ClaudeLocator.marker)\n"),
                       "/a:/b")
        XCTAssertNil(ClaudeLocator.markedPath(in: "no marker"))
    }

    /// Stopped while `claude` is still being looked for: nothing starts.
    func testAStopWhileLocatingStartsNothing() throws {
        let path = try fakeClaude()
        let locator = ClaudeLocator(environment: [:], loginPath: {
            Thread.sleep(forTimeInterval: 0.3)
            return (path as NSString).deletingLastPathComponent
        })
        let store = ChatStore(root: nil, platform: .unknown, locator: locator,
                              environment: fakeEnvironment())
        self.store = store
        let id = store.newChat(folder: directory.path)
        let fake = directory.appendingPathComponent("claude")
        try FileManager.default.copyItem(atPath: path, toPath: fake.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        store.perform(.stop(chat: id))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.phase, .review)
        XCTAssertTrue(runs().isEmpty, "no process was started")
    }

    /// A miss is not remembered: `claude` installed later is found.
    func testAMissIsLookedUpAgain() throws {
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let locator = ClaudeLocator(environment: [:], loginPath: { bin.path })
        var first: ClaudeLocator.Location?
        locator.locate { first = $0 }
        waitUntil("the first lookup") { first != nil }
        XCTAssertNil(first?.executable)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path,
                                       contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        var second: ClaudeLocator.Location?
        locator.locate { second = $0 }
        waitUntil("the second lookup") { second != nil }
        XCTAssertEqual(second?.executable, bin.appendingPathComponent("claude").path)
    }

    /// A process started from the rc file that keeps stdout open must not
    /// hold the answer back: reading stops at the closing marker.
    func testTheLoginPathIsReadWhileAChildHoldsThePipe() throws {
        let shell = directory.appendingPathComponent("fake-shell")
        try """
            #!/bin/sh
            printf '\(ClaudeLocator.marker)/x:/y\(ClaudeLocator.marker)'
            sleep 3 &

            """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let started = Date()
        XCTAssertEqual(ClaudeLocator.readLoginPath(shell: shell.path, timeout: 5), "/x:/y")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// The store's own row is the chat's; the session record the same turn
    /// writes is left out by id (measured, `011/phase-1`).
    func testTheStoreNamesItsSessionsForTheRecordProvider() throws {
        let store = try make()
        let id = store.newChat(folder: directory.path)
        XCTAssertEqual(store.sessionIDs, [store.chat(id)!.sessionID])
    }
}
