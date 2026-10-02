import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp
@testable import EvlatAgents

/// A Codex chat turn end to end against a **fake `codex app-server`**
/// (`Tests/Fixtures/fake-codex-app-server`): the store starts the server,
/// drives it over stdin as it answers, holds its requests as cards and
/// writes the answers back. The real `codex` is never run from a test.
final class CodexRunnerTests: XCTestCase {
    private var directory: URL!
    private var store: ChatStore?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store?.stopAll()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var log: URL { directory.appendingPathComponent("codex.log") }

    /// The fixture, copied with its exec bit.
    private func fakeServer() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-codex-app-server")
        let copy = directory.appendingPathComponent("fake-codex-app-server")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.copyItem(at: source, to: copy)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            FreshExecutable.warm(copy.path)
        }
        return copy.path
    }

    private let codex = CodexChat()

    /// Both backends, Codex selected; no listener — a duplex turn asks on its
    /// own channel. The scenario is handed to the store, not set on this
    /// process (`ClaudeRunnerTests`).
    private func make(scenario: String = "ok", version: String? = nil, root: URL? = nil,
                      registry: Registry? = nil) throws -> ChatStore {
        let path = try fakeServer()
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_CODEX_SCENARIO"] = scenario
        environment["FAKE_CODEX_LOG"] = log.path
        environment["FAKE_CODEX_VERSION"] = version
        let lanes = [
            ChatStore.Lane(backend: ClaudeChat(),
                           locator: AgentLocator(name: "claude", environment: ["EVLAT_CLAUDE": "/nonexistent"])),
            ChatStore.Lane(backend: codex, locator: AgentLocator(name: "codex", environment: ["EVLAT_CODEX": path])),
        ]
        let made = ChatStore(root: root, platform: AppController.darwinPlatform, lanes: lanes,
                             selected: { .codex }, environment: environment)
        registry?.register(made.provider)
        store = made
        return made
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) {
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

    /// The lines the server read, by their method (or `answer` for one with none).
    private func written(_ run: [String]) -> [String] {
        run.filter { $0.hasPrefix("stdin=") }.map { line in
            let json = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))) as? [String: Any]
            return json?["method"] as? String ?? "answer"
        }
    }

    private func openCard(_ store: ChatStore, _ id: String) -> ChatSession.PermissionCard? {
        for case .permission(let card) in store.chat(id)?.messages ?? [] where card.isOpen { return card }
        return nil
    }

    // MARK: - A turn

    func testATurnStreamsAndTheThreadIsTheChatsSession() throws {
        let registry = Registry()
        let store = try make(registry: registry)
        let id = store.newChat(folder: directory.path)
        XCTAssertEqual(store.backend(of: id)?.id, .codex)
        XCTAssertEqual(store.chat(id)?.mode, codex.standardMode)
        store.perform(.send(chat: id, text: "say ok", attachments: []))
        XCTAssertEqual(registry.snapshot().ordered.first?.phase, .working)
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(registry.snapshot().ordered.map(\.phase), [.review])
        XCTAssertEqual(store.chat(id)?.messages.last, .reply("ok"))
        XCTAssertNil(store.chat(id)?.failure)
        XCTAssertEqual(store.chat(id)?.sessionID, "thr-new", "the server's thread names the session")

        let run = try XCTUnwrap(runs().first)
        XCTAssertEqual(run.first, "app-server")
        XCTAssertTrue(run.contains("EVLAT_TASK=\(id)"), "the errand's id reaches the user's hooks")
        XCTAssertEqual(written(run), ["initialize", "initialized", "thread/start", "turn/start"])
        XCTAssertTrue(run.contains { $0.contains(#""sandbox":"workspace-write""#) })
        XCTAssertTrue(run.contains { $0.contains(#""sandbox":"workspace-write""#) })
        XCTAssertEqual(store.versions[.codex], "0.156.1")
        XCTAssertEqual(store.provider.diagnostics, [], "the measured version says nothing")
    }

    /// The second turn resumes the thread the first one started, in a new
    /// process, in the chat's mode now.
    func testTheSecondTurnResumesTheThread() throws {
        let store = try make()
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "one", attachments: []))
        waitUntil("the first turn ends") { store.chat(id)?.isRunning == false }
        store.setMode(id, CodexMode.readOnly.chatMode)
        store.perform(.send(chat: id, text: "two", attachments: []))
        waitUntil("the second turn ends") { store.chat(id)?.isRunning == false && self.runs().count == 2 }
        let second = runs()[1]
        XCTAssertEqual(written(second), ["initialize", "initialized", "thread/resume", "turn/start"])
        XCTAssertTrue(second.contains { $0.contains(#""threadId":"thr-new""#) && $0.contains("thread/resume") })
        XCTAssertTrue(second.contains { $0.contains(#""sandbox":"read-only""#) })
        XCTAssertEqual(store.chat(id)?.messages.last, .reply("ok"))
    }

    func testAFailedTurnFails() throws {
        let store = try make(scenario: "failed")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.failure, .result(subtype: "failed", text: "boom"))
    }

    func testACrashFailsWithTheLastStderrLine() throws {
        let store = try make(scenario: "crash")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the process ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.failure, .exited(status: 3, detail: "fatal: the fake fell over"))
    }

    // MARK: - Permission

    /// The server's request is a card with its reason and its whole command;
    /// each answer goes back on stdin as its decision word.
    func testACommandsCardAndItsThreeAnswers() throws {
        for (decision, word, reply) in [(Action.Decision.allow, "accept", "Written."),
                                        (.allowAlways, "acceptForSession", "Written."),
                                        (.deny, "decline", "Not allowed.")] {
            try? FileManager.default.removeItem(at: log)
            let registry = Registry()
            let store = try make(scenario: "permission", registry: registry)
            let id = store.newChat(folder: directory.path)
            store.perform(.send(chat: id, text: "write", attachments: []))
            waitUntil("the card opens") { self.openCard(store, id) != nil }
            let card = try XCTUnwrap(openCard(store, id))
            XCTAssertEqual(card.tool, "Bash")
            XCTAssertEqual(card.subject, "echo one > a.txt")
            XCTAssertEqual(card.command, "/bin/zsh -lc 'echo one > a.txt'")
            XCTAssertEqual(card.reason, "May I write the requested a.txt file in the current directory?")
            XCTAssertEqual(card.always, .thisCommand)
            XCTAssertTrue(card.offersAlways, "a command can be allowed again")
            XCTAssertEqual(registry.snapshot().ordered.first?.phase, .waiting)

            store.perform(.answer(request: card.id, decision: decision))
            waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
            XCTAssertEqual(store.chat(id)?.messages.last, .reply(reply), word)
            let answer = try XCTUnwrap(runs().first?.first { $0.hasPrefix("stdin=") && $0.contains("decision") })
            XCTAssertEqual(answer, #"stdin={"id":0,"jsonrpc":"2.0","result":{"decision":""# + word + #""}}"#)
            store.stopAll()
        }
    }

    /// Stop with a card open: the card is cancelled — which ends the turn on
    /// the server's side — and the turn is interrupted on its channel.
    func testStopWithACardOpenCancelsIt() throws {
        let store = try make(scenario: "permission")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "write", attachments: []))
        waitUntil("the card opens") { self.openCard(store, id) != nil }
        store.perform(.stop(chat: id))
        waitUntil("the turn ends", timeout: 5) { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.phase, .review)
        XCTAssertNil(store.chat(id)?.failure)
        let run = try XCTUnwrap(runs().first)
        XCTAssertTrue(run.contains { $0.contains(#""decision":"cancel""#) })
        XCTAssertTrue(written(run).contains("turn/interrupt"))
    }

    /// Stop is a line, never SIGINT: the server says the turn ended.
    func testStopInterruptsTheTurnOnItsChannel() throws {
        let store = try make(scenario: "stop")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the turn streams") { store.chat(id)?.messages.last == .reply("Working") }
        let pid = try XCTUnwrap(store.processIdentifier(of: id))
        store.perform(.stop(chat: id))
        waitUntil("the turn ends", timeout: 5) { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.chat(id)?.phase, .review)
        XCTAssertEqual(store.chat(id)?.word, ChatSession.stoppedWord)
        XCTAssertNil(store.chat(id)?.failure)
        XCTAssertTrue(written(try XCTUnwrap(runs().first)).contains("turn/interrupt"))
        waitUntil("the process is gone") { !AppController.isProcessAlive(pid) }
    }

    // MARK: - What the bubble cannot answer, and drift

    /// A request the bubble does not know is refused at once, said in the
    /// chat, and the turn goes on to its end.
    func testAnUnknownRequestIsRefusedAndTheTurnEnds() throws {
        let store = try make(scenario: "unknown")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "ask me", attachments: []))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(Array(store.chat(id)?.messages.dropFirst() ?? []),
                       [.unsupported("item/tool/requestUserInput"), .reply("Went on.")])
        XCTAssertEqual(store.chat(id)?.phase, .review)
        let refusal = try XCTUnwrap(runs().first?.first { $0.contains(#""error""#) })
        XCTAssertTrue(refusal.contains(#""id":"q-7""#), refusal)
        XCTAssertTrue(refusal.contains("\(AppServerStream.methodNotFound)"), refusal)
    }

    /// A server that reports another version than the one measured is said
    /// in the diagnostics; the turn runs all the same.
    func testAnotherVersionIsSaid() throws {
        let store = try make(version: "0.158.0")
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        XCTAssertEqual(store.versions[.codex], "0.158.0")
        XCTAssertEqual(store.provider.diagnostics, ["chat codex: version 0.158.0 answered, checked against 0.156.1"])
        XCTAssertEqual(store.chat(id)?.messages.last, .reply("ok"))
    }

    // MARK: - Keeping

    /// A Codex chat is kept in its own file, and read back on its backend by
    /// the next launch; Claude's file is not written.
    func testItsChatsAreKeptInTheirOwnFile() throws {
        let store = try make(root: directory)
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "say ok", attachments: []))
        waitUntil("the turn ends") { store.chat(id)?.isRunning == false }
        store.markSeen(id)
        let file = directory.appendingPathComponent("chats-codex.json")
        let entry = try XCTUnwrap(ChatIndex.decode(Data(contentsOf: file)).entries.first { $0.id == id })
        XCTAssertEqual(entry.sessionID, "thr-new", "the thread's id is kept to resume it")
        XCTAssertTrue(entry.started)
        XCTAssertEqual(entry.permissionMode, "workspace")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("chats.json").path))
        store.stopAll()

        let again = try make(root: directory)
        XCTAssertEqual(again.history.map(\.id), [id])
        XCTAssertTrue(again.open(id))
        XCTAssertEqual(again.backend(of: id)?.id, .codex)
        again.perform(.send(chat: id, text: "more", attachments: []))
        waitUntil("the resumed turn ends") { again.chat(id)?.isRunning == false && self.runs().count == 2 }
        XCTAssertTrue(runs()[1].contains { $0.contains(#""threadId":"thr-new""#) && $0.contains("thread/resume") })
    }

    /// The thread's id is kept as soon as the server names it: a turn cut
    /// off after that resumes it rather than opening another.
    func testTheThreadIsKeptBeforeTheTurnEnds() throws {
        let store = try make(scenario: "stop", root: directory)
        let id = store.newChat(folder: directory.path)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        waitUntil("the turn streams") { store.chat(id)?.messages.last == .reply("Working") }
        let entry = try XCTUnwrap(ChatIndex.decode(Data(contentsOf: directory.appendingPathComponent("chats-codex.json")))
            .entries.first { $0.id == id })
        XCTAssertEqual(entry.sessionID, "thr-new")
        XCTAssertTrue(entry.started)
        store.perform(.stop(chat: id))
        waitUntil("the turn ends", timeout: 5) { store.chat(id)?.isRunning == false }
    }

    /// A chat runs on the backend it was made on: choosing another after its
    /// first turn changes the next chats, not it.
    func testAChatsBackendIsFixed() throws {
        var chosen = AgentID.codex
        let path = try fakeServer()
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_CODEX_LOG"] = log.path
        let made = ChatStore(root: nil, platform: AppController.darwinPlatform, lanes: [
            ChatStore.Lane(backend: ClaudeChat(),
                           locator: AgentLocator(name: "claude", environment: ["EVLAT_CLAUDE": "/nonexistent"])),
            ChatStore.Lane(backend: codex, locator: AgentLocator(name: "codex", environment: ["EVLAT_CODEX": path])),
        ], selected: { chosen }, environment: environment)
        store = made
        let id = made.newChat(folder: directory.path, mode: .acceptEdits)
        XCTAssertEqual(made.chat(id)?.mode, codex.standardMode, "a mode the backend does not have is not taken")
        made.perform(.send(chat: id, text: "one", attachments: []))
        waitUntil("the turn ends") { made.chat(id)?.isRunning == false }
        chosen = .claude
        XCTAssertEqual(made.backend(of: id)?.id, .codex)
        made.perform(.send(chat: id, text: "two", attachments: []))
        waitUntil("the second turn ends") { made.chat(id)?.isRunning == false && self.runs().count == 2 }
        XCTAssertNil(made.chat(id)?.failure, "still Codex's: Claude's program is not there")
        let next = made.newChat()
        XCTAssertEqual(made.backend(of: next)?.id, .claude)
        var found: Bool?
        made.locateBackend(for: next) { found = $0 }
        waitUntil("looked for") { found != nil }
        XCTAssertEqual(found, false, "the new chat's program is Claude's, which is not there")
    }
}

/// The controller's side of the choice: the new chats' backend, stored by
/// its id; its own default mode; the balloon's corner naming it; the card's
/// "this command" words.
@MainActor
final class ChatBackendChoiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "evlat.tests.backend.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheNewChatsBackendIsStoredByItsID() {
        XCTAssertEqual(AppController.storedBackend(defaults).id, .claude, "none stored is the catalogue's first")
        defaults.set("codex", forKey: AppController.backendKey)
        XCTAssertEqual(AppController.storedBackend(defaults).id, .codex)
        defaults.set("nobody", forKey: AppController.backendKey)
        XCTAssertEqual(AppController.storedBackend(defaults).id, .claude, "an id this build has no backend for")
        XCTAssertEqual(AppController.backendKey, "chat.backend")
    }

    /// Without storage the choice is kept in the controller: the corner and
    /// the default follow it, each backend keeping its own default mode.
    func testChoosingABackendMovesTheBalloonAndTheDefault() {
        let controller = AppController()
        XCTAssertEqual(controller.chatBackend.id, .claude)
        controller.setChatBackend(.codex)
        XCTAssertEqual(controller.chatBackend.id, .codex)
        XCTAssertEqual(controller.chatModel.agent, .codex)
        XCTAssertEqual(controller.chatModel.agentName, "Codex")
        XCTAssertEqual(controller.defaultMode.id, "workspace")
        controller.setDefaultMode(CodexMode.readOnly.chatMode)
        XCTAssertEqual(controller.defaultMode.id, "readOnly")
        controller.setDefaultMode(CodexMode.fullAccess.chatMode)
        XCTAssertEqual(controller.defaultMode.id, "readOnly", "full access is never a default")
        controller.setDefaultMode(.acceptEdits)
        XCTAssertEqual(controller.defaultMode.id, "readOnly", "another backend's mode is not this one's")
        controller.setChatBackend(.claude)
        XCTAssertEqual(controller.defaultMode, .standard, "Claude's default is its own")
        XCTAssertEqual(controller.chatModel.agent, .claude)
    }

    func testTheCardSaysThisCommand() {
        var chat = ChatSession(id: "C", sessionID: "S", folder: "/tmp", isWorkspace: false, mode: .standard)
        _ = chat.begin(prompt: "go", attachments: [], at: Date())
        chat.ask(ChatRequest(id: "R", token: nil, tool: "Bash", subject: "ls", command: "ls", replyTarget: .runner),
                 always: .thisCommand, at: Date())
        guard case .permission(var card)? = chat.messages.last else { return XCTFail() }
        XCTAssertEqual(ChatModel.alwaysKey(card), "chat.permission.always.command")
        XCTAssertEqual(ChatModel.outcomeKey(.allowedAlways, always: .thisCommand), "chat.permission.allowedCommand")
        card.always = .rules
        XCTAssertEqual(ChatModel.alwaysKey(card), "chat.permission.always")
        XCTAssertEqual(ChatModel.outcomeKey(.allowedAlways), "chat.permission.allowedAlways")
    }
}
