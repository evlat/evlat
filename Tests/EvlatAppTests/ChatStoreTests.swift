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
        XCTAssertEqual(entry.title, "hi", "the prompt until a reply names it: never the workspace's UUID")
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
                              locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/nonexistent"]),
                              now: { t0 + 60 })
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

    // MARK: - Seen, history, pruning (`phase-5`)

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let ids = ["0C9E7D1A-8E57-4B9B-8D0F-7F2B4E6A1C33", "5A8F2E10-3C4D-4E5F-8A9B-0C1D2E3F4A5B",
                       "9D2C4B6A-1E3F-4A5B-8C7D-6E5F4A3B2C1D", "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"]

    private func entry(_ id: String, days: Double, workspace: Bool = true, folder: String? = nil,
                       pinned: Bool = false, unseen: Phase? = nil) -> ChatIndex.Entry {
        ChatIndex.Entry(id: id, sessionID: "S-\(id)", title: "T", folder: folder ?? directory.appendingPathComponent("chats/\(id)").path,
                        isWorkspace: workspace, createdAt: now - days * 86_400,
                        lastActivity: now - days * 86_400, pinned: pinned, lastReply: "Done.",
                        started: true, unseen: unseen)
    }

    private func store(trashed: @escaping (URL) -> Void = { _ in }, at time: Date? = nil) -> ChatStore {
        ChatStore(root: directory, platform: .unknown,
                  locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/nonexistent"]),
                  now: { [now] in time ?? now }, trash: { trashed($0) })
    }

    private func makeWorkspace(_ id: String) throws -> URL {
        let folder = directory.appendingPathComponent("chats/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("out.txt"))
        return folder
    }

    /// An isolated store (`EVLAT_CHATS`, `EVLAT_PORT`) sets a pruned
    /// workspace aside under its own root, never in the user's Trash; the
    /// store's default does the same, so a test that forgets cannot either.
    func testAnIsolatedStoreNeverReachesTheRealTrash() throws {
        let first = try makeWorkspace(ids[0])
        try ChatStore.trash(environment: ["EVLAT_CHATS": directory.path])(first)
        let second = try makeWorkspace(ids[0])
        try ChatStore.trash(environment: ["EVLAT_PORT": "48999"])(second)
        let bin = directory.appendingPathComponent("trash")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path).sorted(),
                       [ids[0], "\(ids[0])-1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("\(ids[0])/out.txt").path))

        _ = try makeWorkspace(ids[1])
        try writeIndex(ChatIndex(entries: [entry(ids[1], days: 8)]))
        _ = ChatStore(root: directory, platform: .unknown,
                      locator: ClaudeLocator(environment: ["EVLAT_CLAUDE": "/nonexistent"]), now: { [now] in now })
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent(ids[1]).path))
    }

    /// A week after its last activity a chat goes, and only its own
    /// `chats/<UUID>` goes to the Trash — a chat in the user's folder
    /// leaves that folder alone; pinned and recent chats stay.
    func testPruningTrashesOnlyAnOldChatsOwnWorkspace() throws {
        let old = try makeWorkspace(ids[0])
        let user = directory.appendingPathComponent("user-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        _ = try makeWorkspace(ids[2])
        try writeIndex(ChatIndex(entries: [
            entry(ids[0], days: 8),
            entry(ids[1], days: 8, workspace: false, folder: user.path),
            entry(ids[2], days: 30, pinned: true),
            entry(ids[3], days: 6),
        ]))
        var trashed: [URL] = []
        _ = store(trashed: { trashed.append($0) })
        XCTAssertEqual(trashed.map(\.standardizedFileURL.path), [old.standardizedFileURL.path])
        XCTAssertEqual(try readIndex().entries.map(\.id), [ids[2], ids[3]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.path), "the user's folder is never touched")
    }

    /// The path comes from the id, never the entry's `folder`: a workspace
    /// entry naming the user's folder still only ever trashes `chats/<id>`.
    func testTheTrashedPathIsNeverTheEntrysFolder() throws {
        let user = directory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try writeIndex(ChatIndex(entries: [entry(ids[0], days: 9, folder: user.path)]))
        var trashed: [URL] = []
        _ = store(trashed: { trashed.append($0) })
        XCTAssertEqual(trashed, [], "no `chats/<id>` on disk, so nothing; never the folder named")
        XCTAssertEqual(try readIndex().entries, [])
        let store = store()
        XCTAssertNil(store.removableWorkspace(".."))
        XCTAssertNil(store.removableWorkspace(""))
        XCTAssertNil(store.removableWorkspace("../\(ids[0])"))
    }

    /// An index it cannot read — a bad id among them — prunes nothing and
    /// is not written over.
    func testAnUnreadableIndexPrunesNothing() throws {
        _ = try makeWorkspace(ids[0])
        var bad = entry(ids[0], days: 30)
        bad.id = "../../Documents"
        let data = ChatIndex(entries: [bad, entry(ids[0], days: 30)]).encoded()
        try data.write(to: directory.appendingPathComponent(ChatStore.indexName))
        var trashed: [URL] = []
        let store = store(trashed: { trashed.append($0) })
        XCTAssertEqual(store.indexError, .badID("../../Documents"))
        store.prune()
        store.clearHistory()
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(ChatStore.indexName)), data)
    }

    /// An end nobody saw comes back as a row after a relaunch; seeing it
    /// takes the row away and is written down.
    func testAnUnseenEndSurvivesARelaunchUntilSeen() throws {
        try writeIndex(ChatIndex(entries: [entry(ids[0], days: 0.1, unseen: .review), entry(ids[1], days: 1)]))
        let store = store()
        XCTAssertEqual(store.provider.currentSignals().map(\.entity), ["evlat:\(ids[0])"])
        XCTAssertEqual(store.history.map(\.id), [ids[1]], "a chat with a row is not in the history")
        store.markSeen(ids[0])
        XCTAssertEqual(store.provider.currentSignals(), [])
        XCTAssertNil(try readIndex().entries.first { $0.id == ids[0] }?.unseen)
        XCTAssertEqual(store.history.map(\.id), [ids[0], ids[1]])
        XCTAssertEqual(try readIndex().entries.first { $0.id == ids[0] }?.lastActivity, now - 0.1 * 86_400,
                       "looking is not activity: the week still counts from the turn")
    }

    /// Twelve hours unseen: no row, and it is in the history.
    func testAnOldUnseenEndIsInTheHistory() throws {
        try writeIndex(ChatIndex(entries: [entry(ids[0], days: 0.6, unseen: .failed)]))
        let store = store()
        XCTAssertEqual(store.provider.currentSignals(), [])
        XCTAssertEqual(store.history.map(\.id), [ids[0]])
    }

    /// The history's controls: pin, ×, clear — pinned chats survive a clear.
    func testPinRemoveAndClear() throws {
        let removed = try makeWorkspace(ids[0])
        try writeIndex(ChatIndex(entries: [entry(ids[0], days: 1), entry(ids[1], days: 2),
                                           entry(ids[2], days: 3)]))
        var trashed: [URL] = []
        let store = store(trashed: { trashed.append($0) })
        store.setPinned(ids[2], true)
        XCTAssertEqual(store.history.map(\.id), [ids[2], ids[0], ids[1]], "pinned first")
        store.remove(ids[0])
        XCTAssertEqual(trashed.map(\.standardizedFileURL.path), [removed.standardizedFileURL.path])
        store.clearHistory()
        XCTAssertEqual(store.history.map(\.id), [ids[2]])
        XCTAssertEqual(try readIndex().entries.map { ($0.id, $0.pinned) }.map(\.0), [ids[2]])
    }

    /// A chat opened from the history shows its last reply and resumes.
    func testAChatOpenedFromTheHistory() throws {
        try writeIndex(ChatIndex(entries: [entry(ids[0], days: 1)]))
        let store = store()
        XCTAssertNil(store.chat(ids[0]), "not in memory until opened")
        XCTAssertTrue(store.open(ids[0]))
        XCTAssertEqual(store.chat(ids[0])?.messages, [.reply("Done.")])
        XCTAssertEqual(store.chat(ids[0])?.hasStarted, true)
        XCTAssertFalse(store.open(ids[1]))
    }

    /// Files a workspace chat made, hidden ones aside; none for a chat in
    /// the user's folder.
    func testWorkspaceFiles() throws {
        let folder = try makeWorkspace(ids[0])
        try Data().write(to: folder.appendingPathComponent(".hidden"))
        try writeIndex(ChatIndex(entries: [entry(ids[0], days: 1),
                                           entry(ids[1], days: 1, workspace: false, folder: folder.path)]))
        let store = store()
        store.open(ids[0])
        store.open(ids[1])
        XCTAssertEqual(store.workspaceFiles(ids[0]).map(\.lastPathComponent), ["out.txt"])
        XCTAssertEqual(store.workspaceFiles(ids[1]), [])
    }

    // MARK: - Memory

    private var memory: URL { directory.appendingPathComponent("memory", isDirectory: true) }

    private func writeNote(_ name: String, in folder: URL? = nil) throws {
        let folder = folder ?? memory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("green".utf8).write(to: folder.appendingPathComponent(name))
    }

    func testTheMemoryFolderIsBesideTheWorkspaces() {
        XCTAssertEqual(store().memoryDirectory.path, memory.path)
    }

    /// The week's pruning takes an old chat's workspace and never the
    /// memory: what Claude remembered outlives every chat.
    func testPruningNeverReachesTheMemory() throws {
        try writeNote("MEMORY.md")
        _ = try makeWorkspace(ids[0])
        try writeIndex(ChatIndex(entries: [entry(ids[0], days: 30)]))
        var trashed: [URL] = []
        let store = store(trashed: { trashed.append($0) })
        store.clearHistory()
        XCTAssertEqual(trashed.map(\.lastPathComponent), [ids[0]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: memory.appendingPathComponent("MEMORY.md").path))
    }

    /// Clearing empties the folder and keeps it; a link inside goes as a
    /// link, and what it points at stays.
    func testClearingEmptiesOnlyTheMemoryFolder() throws {
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try writeNote("kept.md", in: outside)
        try writeNote("MEMORY.md")
        try writeNote("favorite-color.md", in: memory.appendingPathComponent("topic", isDirectory: true))
        try FileManager.default.createSymbolicLink(at: memory.appendingPathComponent("link"),
                                                   withDestinationURL: outside)
        let store = store()
        XCTAssertEqual(store.memoryContents()?.count, 3)
        XCTAssertTrue(store.clearMemory())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: memory.path), [])
        XCTAssertEqual(store.memoryContents()?.count, 0, "the folder stays, empty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("kept.md").path),
                      "a link is removed, not followed")
    }

    /// A memory folder that is a link to somewhere else is not Evlat's to
    /// empty: nothing is read through it, nothing removed.
    func testAMemoryFolderThatIsALinkIsNeverCleared() throws {
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try writeNote("kept.md", in: outside)
        try FileManager.default.createSymbolicLink(at: memory, withDestinationURL: outside)
        let store = store()
        XCTAssertNil(store.memoryContents())
        XCTAssertFalse(store.clearMemory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("kept.md").path))
    }

    func testNoMemoryFolderIsNothingToClear() {
        let store = store()
        XCTAssertNil(store.memoryContents())
        XCTAssertFalse(store.clearMemory())
        XCTAssertFalse(FileManager.default.fileExists(atPath: memory.path), "clearing never makes the folder")
    }
}
