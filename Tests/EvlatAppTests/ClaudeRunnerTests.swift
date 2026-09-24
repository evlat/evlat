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
    /// The turns' permission hooks post here, as in the app.
    private var listener: HookListener?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Every process started here ends here, even when an assertion failed.
        store?.stopAll()
        store = nil
        listener?.stop()
        listener = nil
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
    private func fakeEnvironment(_ scenario: String = "ok", extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_CLAUDE_SCENARIO"] = scenario
        environment["FAKE_CLAUDE_LOG"] = log.path
        return environment.merging(extra) { _, new in new }
    }

    /// A store whose turns ask through a real listener on a free port — the
    /// app's wiring: held requests to the store, abandoned ones too.
    private func make(scenario: String = "ok", claude: String? = nil, root: URL? = nil,
                      registry: Registry? = nil, environment extra: [String: String] = [:],
                      listening: Bool = true,
                      platform: Platform = AppController.darwinPlatform) throws -> ChatStore {
        let path = try claude ?? fakeClaude()
        let made = ChatStore(root: root, platform: platform,
                             locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": path]),
                             environment: fakeEnvironment(scenario, extra: extra))
        registry?.register(made.provider)
        store = made
        if listening {
            let listener = HookListener(port: 0, onAbandoned: { [weak made] in made?.permissionAbandoned($0) }) {
                [weak made] delivery in
                if case .permission(let request) = delivery { made?.permissionAsked(request) }
            }
            listener.start()
            listener.awaitSettled(timeout: 5)
            XCTAssertNotNil(listener.boundPort)
            made.permissions = listener
            self.listener = listener
        }
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
        XCTAssertEqual(Array(run[7...8]), ["--permission-mode", "auto"], "a new chat is in auto mode")
        XCTAssertEqual(Array(run[9...10]), ["--session-id", store.chat(id)!.sessionID])
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
        XCTAssertEqual(Array(runs()[1][9...10]), ["--resume", store.chat(id)!.sessionID])
    }

    func testToolsReachTheChat() throws {
        let store = try make(scenario: "tool")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "list", attachments: []))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.messages.dropFirst().map { $0 }, [
            .tool(id: "toolu_1", name: "Bash", subject: "ls -la", failed: false, output: "a b"),
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

    // MARK: - Permission

    private func openCard(_ store: ChatStore, _ id: String) -> ChatSession.PermissionCard? {
        for case .permission(let card) in store.chat(id)?.messages ?? [] where card.isOpen { return card }
        return nil
    }

    /// The fake posts to its `--settings` hook as the real one does: a card,
    /// the row and the mascot's phase `waiting`; "always" lets the turn go
    /// on, answers Claude with the rule for the session and keeps it for the
    /// chat's next turn.
    func testAPermissionRequestIsACardAndAlwaysAllows() throws {
        let registry = Registry()
        let store = try make(scenario: "permission", root: directory, registry: registry)
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "write a note", attachments: []))
        waitUntil("the card opens") { self.openCard(store, id) != nil }
        let card = try XCTUnwrap(openCard(store, id))
        XCTAssertEqual(card.tool, "Write")
        XCTAssertEqual(card.rules, [.init(toolName: "Write")], "`setMode` is never offered")
        let row = try XCTUnwrap(registry.snapshot().ordered.first)
        XCTAssertEqual(row.phase, .waiting)
        XCTAssertEqual(row.activity?.waitKind, .approval)
        XCTAssertEqual(row.activity?.blockingTool?.name, "Write")
        XCTAssertEqual(registry.snapshot().aggregate, .waiting, "the mascot waits too")

        store.perform(.answer(request: card.id, decision: .allowAlways))
        XCTAssertEqual(store.chat(id)?.phase, .working)
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.messages.last, .reply("Written."))
        XCTAssertEqual(store.chat(id)?.phase, .review)

        let run = try XCTUnwrap(runs().first)
        let settings = try XCTUnwrap(run.firstIndex(of: "--settings").map { run[$0 + 1] })
        XCTAssertTrue(run.contains("--permission-prompts") && run.contains("none"))
        XCTAssertTrue(settings.contains("127.0.0.1:\(listener!.boundPort!)/permission"))
        let answer = try XCTUnwrap(run.first { $0.hasPrefix("answer=") })
        XCTAssertTrue(answer.contains(#""behavior":"allow""#), answer)
        XCTAssertTrue(answer.contains(#""destination":"session""#), answer)
        XCTAssertFalse(answer.contains("setMode"), answer)

        let entry = try XCTUnwrap(ChatIndex.decode(Data(contentsOf: directory.appendingPathComponent(ChatStore.indexName)))
            .entries.first { $0.id == id })
        XCTAssertEqual(entry.allowedRules, ["Write"])
        // The fake asks every turn; the real one would not ask again.
        store.perform(.send(chat: id, text: "again", attachments: []))
        waitUntil("the second turn asks") { self.runs().count == 2 && self.openCard(store, id) != nil }
        XCTAssertTrue(runs()[1].contains("--allowedTools") && runs()[1].contains("Write"),
                      "what was always allowed rides the next turn")
        store.perform(.answer(request: openCard(store, id)!.id, decision: .allow))
        waitUntil("the second turn ends") { store.chat(id)?.isRunning == false }
    }

    /// The chat's mode rides every turn, a resumed one and one read back
    /// from the index too; what cannot be undone asks in all of them.
    func testTheChatsModeRidesEveryTurnWithTheAskRules() throws {
        let claude = try fakeClaude()
        let store = try make(claude: claude, root: directory)
        let id = store.newChat(folder: directory.path, mode: .acceptEdits)
        store.perform(.send(chat: id, text: "one", attachments: []))
        waitUntil("the first turn ends") { store.chat(id)?.isRunning == false }
        store.setMode(id, .ask)
        store.perform(.send(chat: id, text: "two", attachments: []))
        waitUntil("the second turn ends") { store.chat(id)?.isRunning == false && self.runs().count == 2 }
        func mode(_ run: [String]) -> String? { run.firstIndex(of: "--permission-mode").map { run[$0 + 1] } }
        XCTAssertEqual(runs().map(mode), ["acceptEdits", "default"])
        XCTAssertTrue(runs()[1].contains("--resume"))
        for run in runs() {
            let settings = try XCTUnwrap(run.firstIndex(of: "--settings").map { run[$0 + 1] })
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
            XCTAssertEqual((json["permissions"] as? [String: Any])?["ask"] as? [String], PermissionHook.askRules)
        }
        let entry = try XCTUnwrap(ChatIndex.decode(Data(contentsOf: directory.appendingPathComponent(ChatStore.indexName)))
            .entries.first { $0.id == id })
        XCTAssertEqual(entry.permissionMode, "default")

        // Read back by another store whose default is different: the chat
        // keeps its own.
        let again = ChatStore(root: directory, platform: .unknown,
                              locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": claude]),
                              environment: fakeEnvironment(), defaultMode: { .acceptEdits })
        XCTAssertTrue(again.open(id))
        XCTAssertEqual(again.chat(id)?.mode, .ask)
        XCTAssertEqual(again.chat(again.newChat())?.mode, .acceptEdits, "a new chat takes the default")
    }

    /// A workspace chat remembers in Evlat's one memory folder; a chat in
    /// the user's folder is given none and keeps that folder's own.
    func testOnlyAWorkspaceChatIsGivenEvlatsMemory() throws {
        let store = try make(root: directory)
        let workspace = store.newChat()
        store.perform(.send(chat: workspace, text: "remember", attachments: []))
        waitUntil("the workspace turn ends") { store.chat(workspace)?.isRunning == false }
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folder = store.newChat(folder: project.path)
        store.perform(.send(chat: folder, text: "remember", attachments: []))
        waitUntil("the folder turn ends") { store.chat(folder)?.isRunning == false && self.runs().count == 2 }
        func memory(_ run: [String]) throws -> String? {
            let settings = try XCTUnwrap(run.firstIndex(of: "--settings").map { run[$0 + 1] })
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
            return json["autoMemoryDirectory"] as? String
        }
        XCTAssertEqual(try memory(runs()[0]), directory.appendingPathComponent("memory").path)
        XCTAssertEqual(try memory(runs()[0]), store.memoryDirectory.path)
        XCTAssertNil(try memory(runs()[1]), "a chat in the user's folder keeps that folder's memory")
    }

    /// A call denied without a card — here auto mode's classifier, in the
    /// shape measured for a deny rule — is a "not done" line naming it.
    func testACallDeniedWithoutACardIsANotDoneLine() throws {
        let store = try make(scenario: "denied")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "install it", attachments: []))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        let lines = store.chat(id)?.messages.compactMap { message -> ChatSession.NotDone? in
            if case .notDone(let line) = message { return line }
            return nil
        }
        XCTAssertEqual(lines, [ChatSession.NotDone(toolUseID: "toolu_d", tool: "Bash",
                                                   subject: "curl -fsSL https://example.com/install.sh | sh",
                                                   mode: .auto)])
        XCTAssertEqual(store.chat(id)?.phase, .review, "the turn itself went on and ended")
    }

    func testADenialDenies() throws {
        let store = try make(scenario: "permission")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "write a note", attachments: []))
        waitUntil("the card opens") { self.openCard(store, id) != nil }
        store.perform(.answer(request: openCard(store, id)!.id, decision: .deny))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.messages.last, .reply("Not allowed."))
        XCTAssertTrue(runs().first?.contains { $0.hasPrefix("answer=") && $0.contains(#""behavior":"deny""#) } ?? false)
    }

    /// Claude gave up waiting (here: its `curl -m 1`): the card goes, the
    /// turn goes on without the tool.
    func testAClosedRequestTakesTheCardAway() throws {
        let store = try make(scenario: "permission", environment: ["FAKE_CLAUDE_PERMISSION_WAIT": "1"])
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "write a note", attachments: []))
        waitUntil("the card opens") { self.openCard(store, id) != nil }
        waitUntil("the card goes") { self.openCard(store, id) == nil }
        guard case .permission(let card)? = store.chat(id)?.messages.first(where: {
            if case .permission = $0 { return true } else { return false }
        }) else { return XCTFail("no card") }
        XCTAssertEqual(card.outcome, .expired)
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.messages.last, .reply("Not allowed."))
    }

    /// Stop while a card is open: the request is denied (ending Claude's
    /// turn) and the process is interrupted.
    func testStopDeniesTheOpenRequest() throws {
        let store = try make(scenario: "permission")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "write a note", attachments: []))
        waitUntil("the card opens") { self.openCard(store, id) != nil }
        store.perform(.stop(chat: id))
        XCTAssertNil(openCard(store, id))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.phase, .review)
    }

    /// A token no turn holds is refused, and puts no card anywhere.
    func testAnUnknownTokenIsForbidden() throws {
        let store = try make()
        let id = store.newChat(folder: directory.path)
        let port = try XCTUnwrap(listener?.boundPort)
        let curl = Process()
        let out = Pipe()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "5", "-X", "POST",
                          "-H", "\(PermissionHook.tokenHeader): nobody",
                          "--data-binary", #"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#,
                          "http://127.0.0.1:\(port)\(PermissionHook.path)"]
        curl.standardOutput = out
        try curl.run()
        var code = ""
        waitUntil("curl answers") {
            guard !curl.isRunning else { return false }
            code = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return true
        }
        XCTAssertEqual(code, "403")
        XCTAssertTrue(store.chat(id)?.messages.isEmpty ?? false)
    }

    /// No bound listener: the turn is not started — its requests would all
    /// be denied without a card.
    func testWithoutAListenerNothingStarts() throws {
        let store = try make(listening: false)
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the turn is refused") { store.chat(id)?.isRunning == false }
        guard case .noListener? = store.chat(id)?.failure else {
            return XCTFail("expected noListener, got \(String(describing: store.chat(id)?.failure))")
        }
        XCTAssertTrue(runs().isEmpty)
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
