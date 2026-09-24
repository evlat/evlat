import XCTest
import EvlatCore
@testable import EvlatApp

/// Where the chats live, what is written, and what launch does with a turn
/// Evlat left running.
final class ChatStoreTests: XCTestCase {
    private var directory: URL!
    private var sleeper: Process?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-chats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sleeper, sleeper.isRunning { sleeper.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Root

    func testTheRoot() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertEqual(ChatStore.root(environment: [:], home: home)?.path,
                       "/Users/someone/Library/Application Support/Evlat")
        XCTAssertEqual(ChatStore.root(environment: ["EVLAT_CHATS": "/tmp/c"], home: home)?.path, "/tmp/c")
        XCTAssertEqual(ChatStore.root(environment: ["EVLAT_CHATS": "/tmp/c", "EVLAT_PORT": "48999"], home: home)?.path,
                       "/tmp/c", "an explicit root wins over the measurement rule")
        XCTAssertNil(ChatStore.root(environment: ["EVLAT_PORT": "48999"], home: home),
                     "a measured process keeps no store (`remote.machines`' rule)")
        XCTAssertNil(ChatStore.root(environment: [:], home: nil), "no home, no disk")
        XCTAssertNil(ChatStore.root(environment: ["EVLAT_CHATS": "  "], home: nil))
    }

    /// A controller built without a home — every test — never touches disk.
    func testAControllerWithoutAHomeHasNoRoot() {
        XCTAssertNil(AppController.chatRoot(home: nil, environment: ["EVLAT_CHATS": directory.path]))
    }

    // MARK: - Index

    private let entryID = "6B1F3C52-7B8B-4F4B-9C1E-2B7C1D0E9A11"

    private func writeIndex(_ index: ChatIndex) throws {
        try index.encoded().write(to: directory.appendingPathComponent(ChatStore.indexName))
    }

    private func readIndex() throws -> ChatIndex {
        try ChatIndex.decode(Data(contentsOf: directory.appendingPathComponent(ChatStore.indexName)))
    }

    func testAWorkspaceChatLivesUnderTheRoot() throws {
        let store = ChatStore(root: directory, platform: .unknown,
                              locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/nonexistent"]))
        let id = store.newChat()
        XCTAssertEqual(store.chat(id)?.folder, directory.appendingPathComponent("chats/\(id)").path)
        XCTAssertEqual(store.chat(id)?.isWorkspace, true)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        let entry = try XCTUnwrap(readIndex().entries.first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.sessionID, store.chat(id)?.sessionID)
        XCTAssertTrue(entry.isWorkspace)
        XCTAssertNil(entry.run, "no process started")
    }

    /// A file the store cannot read is left exactly as it was.
    func testAnUnreadableIndexIsNeverOverwritten() throws {
        let path = directory.appendingPathComponent(ChatStore.indexName)
        try Data("{broken".utf8).write(to: path)
        let store = ChatStore(root: directory, platform: .unknown,
                              locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/nonexistent"]))
        XCTAssertEqual(store.indexError, .unreadable)
        let id = store.newChat()
        store.perform(.send(chat: id, text: "hi", attachments: []))
        XCTAssertEqual(try Data(contentsOf: path), Data("{broken".utf8))
    }

    /// A turn recorded as running at launch: its still-running process is
    /// ended, the chat is `failed` ("cut off"), the record is cleared.
    func testAnOrphanIsEndedAtLaunch() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        self.sleeper = sleeper
        let pid = sleeper.processIdentifier
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        try writeIndex(ChatIndex(entries: [ChatIndex.Entry(
            id: entryID, sessionID: "S1", folder: directory.path, isWorkspace: false,
            createdAt: t0, lastActivity: t0,
            run: ChatIndex.Run(pid: pid, startedAt: AppController.processStartedAt(pid)),
            started: true)]))

        let registry = Registry()
        let store = ChatStore(root: directory, platform: AppController.darwinPlatform,
                              locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/nonexistent"]))
        registry.register(store.provider)
        sleeper.waitUntilExit()
        XCTAssertEqual(sleeper.terminationReason, .uncaughtSignal)
        XCTAssertEqual(sleeper.terminationStatus, SIGTERM)
        XCTAssertEqual(store.chat(entryID)?.failure, .interrupted)
        XCTAssertEqual(store.chat(entryID)?.hasStarted, true,
                       "a chat cut off after init resumes; naming its session again is refused")
        XCTAssertEqual(registry.snapshot().ordered.map(\.entity), ["evlat:\(entryID)"])
        XCTAssertEqual(registry.snapshot().ordered.map(\.phase), [.failed])
        XCTAssertNil(try readIndex().entries.first?.run)
    }

    /// Without a root nothing is read or written, and a workspace is a
    /// temporary directory.
    func testNoRootMeansNoFile() {
        let store = ChatStore(root: nil, platform: .unknown,
                              locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/nonexistent"]))
        let id = store.newChat()
        XCTAssertTrue(store.chat(id)?.folder.hasPrefix(FileManager.default.temporaryDirectory.path) ?? false)
        store.perform(.send(chat: id, text: "hi", attachments: []))
        XCTAssertNil(store.indexError)
    }
}
