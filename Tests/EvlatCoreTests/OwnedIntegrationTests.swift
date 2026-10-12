import XCTest
@testable import EvlatCore

/// An agent whose unit is a file of Evlat's own, through the same card and
/// the same press as one that merges hooks into a settings file: one state,
/// one install, one removal, the automatic update — and none of the settings
/// form's assumptions (a hook command, a file shape, a status line, a
/// server's JSON). Every file is under a temporary home.
final class OwnedIntegrationTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.owned-integration.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func present(_ agent: TestAgent) throws {
        for path in agent.presence {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
    }

    private func bytes(_ agent: TestAgent) throws -> String {
        try String(contentsOf: agent.unitFile(home: home), encoding: .utf8)
    }

    func testTheFormIsReachedThroughItsCase() {
        let owned = TestAgent.ownedFile()
        XCTAssertNil(owned.integration.settings)
        XCTAssertNotNil(owned.integration.ownedFile)
        XCTAssertEqual(owned.integration.file, ".test/plugins/evlat.js")
        XCTAssertNil(owned.hooksFile(home: home), "no settings file to parse")
        XCTAssertNil(owned.statusLineFile(home: home))
        XCTAssertFalse(owned.hasStatusLine(home: home))
        XCTAssertEqual(owned.unitFile(home: home), home.appendingPathComponent(".test/plugins/evlat.js"))
        XCTAssertEqual(AgentIntegration.files(home: home, for: owned), [owned.unitFile(home: home)])

        let settings = TestAgent()
        XCTAssertNotNil(settings.integration.settings)
        XCTAssertNil(settings.integration.ownedFile)
        XCTAssertEqual(settings.hooksFile(home: home), home.appendingPathComponent(".test/hooks.json"))
        XCTAssertEqual(settings.unitFile(home: home), settings.hooksFile(home: home))
    }

    func testTheCardWalksMissingCurrentOutdatedAndBackToCurrent() throws {
        let agent = TestAgent.ownedFile()
        try present(agent)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: agent).status, .missing)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: agent).hooks, .missing)

        try AgentIntegration.install(home: home, for: agent)
        let state = try AgentIntegration.state(home: home, for: agent)
        XCTAssertEqual(state.status, .current)
        XCTAssertNil(state.relay, "no usage line to wrap")
        XCTAssertFalse(state.installsRelay)

        let newer = TestAgent.ownedFile(version: 2, body: "export default { v: 2 }\n")
        XCTAssertEqual(try AgentIntegration.state(home: home, for: newer).status, .outdated)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: newer).hooks, .outdated)
        try AgentIntegration.install(home: home, for: newer)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: newer).status, .current)
        XCTAssertEqual(try bytes(newer), newer.integration.ownedFile?.file.contents)

        try AgentIntegration.remove(home: home, for: newer)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: newer).status, .missing)
    }

    func testTheAutomaticUpdateWritesWhatAnOlderCopyWroteAndNothingElse() throws {
        let agent = TestAgent.ownedFile()
        try present(agent)
        XCTAssertFalse(try AgentIntegration.keepCurrent(home: home, for: agent, enabled: true), "not installed: not its to install")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent.unitFile(home: home).path))

        try AgentIntegration.install(home: home, for: agent)
        XCTAssertFalse(try AgentIntegration.keepCurrent(home: home, for: agent, enabled: true), "current: nothing to write")

        let newer = TestAgent.ownedFile(version: 2, body: "export default { v: 2 }\n")
        XCTAssertEqual(AgentIntegration.automaticScope(try AgentIntegration.state(home: home, for: newer), enabled: true), .unit)
        XCTAssertFalse(try AgentIntegration.keepCurrent(home: home, for: newer, enabled: false), "switched off: left alone")
        XCTAssertEqual(try bytes(agent), agent.integration.ownedFile?.file.contents)
        XCTAssertTrue(try AgentIntegration.keepCurrent(home: home, for: newer, enabled: true))
        XCTAssertEqual(try AgentIntegration.state(home: home, for: newer).status, .current)
    }

    func testAFileOfTheUsersIsForeignAndNothingWritesOrRemovesIt() throws {
        let agent = TestAgent.ownedFile()
        try present(agent)
        let url = agent.unitFile(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default { mine: true }\n".write(to: url, atomically: true, encoding: .utf8)

        let state = try AgentIntegration.state(home: home, for: agent)
        XCTAssertEqual(state.status, .foreign)
        XCTAssertTrue(state.foreign)
        XCTAssertEqual(state.hooks, .missing)
        XCTAssertNil(AgentIntegration.automaticScope(state, enabled: true))
        XCTAssertEqual(try AgentIntegration.hooksState(home: home, for: agent), .missing)

        XCTAssertThrowsError(try AgentIntegration.install(home: home, for: agent)) {
            XCTAssertEqual($0 as? AgentIntegration.Failure, AgentIntegration.Failure(part: .hooks, reason: .malformed))
        }
        XCTAssertFalse(try AgentIntegration.keepCurrent(home: home, for: agent, enabled: true))
        try AgentIntegration.remove(home: home, for: agent)
        XCTAssertEqual(try bytes(agent), "export default { mine: true }\n")
    }

    func testTheFolderIsMadeOnlyForAnAgentThatIsHere() throws {
        let agent = TestAgent.ownedFile()
        XCTAssertThrowsError(try AgentIntegration.install(home: home, for: agent)) {
            XCTAssertEqual(($0 as? AgentIntegration.Failure)?.reason, .noDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".test").path),
                       "an agent that is not here gets no folder")
        try present(agent)
        try AgentIntegration.install(home: home, for: agent)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: agent).status, .current)

        let closed = TestAgent.ownedFile("closed", opensDirectory: false)
        try present(closed)
        XCTAssertThrowsError(try AgentIntegration.install(home: home, for: closed)) {
            XCTAssertEqual(($0 as? AgentIntegration.Failure)?.reason, .noDirectory)
        }
    }

    func testNothingFromBeforeTheSocketIsThere() throws {
        let agent = TestAgent.ownedFile(body: "// 127.0.0.1:48151\n")
        try present(agent)
        try AgentIntegration.install(home: home, for: agent)
        XCTAssertFalse(AgentIntegration.predatesSocket(home: home, for: agent))
        XCTAssertFalse(AgentIntegration.hooksPredateSocket(home: home, for: agent))
    }

    func testTheManualBlockIsTheWholeFile() {
        let agent = TestAgent.ownedFile()
        XCTAssertEqual(LocalHooks.manual(for: agent), agent.integration.ownedFile?.file.contents)
    }

    func testTheSettingsWritersChangeNothingForIt() {
        let agent = TestAgent.ownedFile()
        let settings: [String: Any] = ["theme": "dark"]
        XCTAssertEqual(NSDictionary(dictionary: LocalHooks.installing(into: settings, for: agent, target: .mac)),
                       NSDictionary(dictionary: settings))
        XCTAssertEqual(NSDictionary(dictionary: LocalHooks.removing(from: settings, for: agent)),
                       NSDictionary(dictionary: settings))
        XCTAssertEqual(LocalHooks.state(of: settings, for: agent, target: .mac), .missing)
    }

    /// A server's unit covers it too, as one file written whole: the
    /// reading takes its section, the manual carries its bytes, the plan
    /// reads its state from the bytes (never as JSON), and the parts of the
    /// settings form — the hooks alone, the status line — are refused for it.
    func testAServerWritesItWhole() throws {
        let owned = TestAgent.ownedFile()
        let other = TestAgent("other")
        XCTAssertTrue(RemoteSettings.serves(owned))
        XCTAssertTrue(RemoteSettings.serves(other))

        let reading = RemoteSettings.readingScript(nonce: "n", agents: [owned, other])
        XCTAssertTrue(reading.contains(" begin test "), "its section is read")
        XCTAssertTrue(reading.contains(" begin other "))

        let manual = RemoteSettings.manual(agents: [owned, other])
        XCTAssertEqual(manual.hooks(for: owned), owned.integration.ownedFile?.file.contents)
        XCTAssertFalse(manual.hooks(for: other).isEmpty)

        for change in [RemoteSettings.Change.hooks(owned), .statusLine(owned)] {
            for action in [RemoteSettings.Action.install, .remove] {
                XCTAssertThrowsError(try RemoteSettings.plan(change, action, original: nil), "\(change) \(action)") {
                    XCTAssertEqual($0 as? RemoteSettings.Failure, .file(.malformed))
                }
            }
        }
        XCTAssertFalse(RemoteSettings.relays(owned))
        XCTAssertEqual(RemoteSettings.Change.agent(owned).opening, owned.presence,
                       "the folder is opened for an agent that is there, as on this Mac")
        XCTAssertTrue(RemoteSettings.Change.agent(TestAgent.ownedFile(opensDirectory: false)).opening.isEmpty)
        XCTAssertEqual(RemoteSettings.Change.agent(owned).path, ".test/plugins/evlat.js")
    }

    /// The plan, state by state: written whole and without a backup when
    /// missing or older, nothing when current (a later copy's too), refused
    /// when the file is not Evlat's, and a removal that takes only a marked
    /// file.
    func testThePlanReadsTheStateFromTheBytes() throws {
        let owned = TestAgent.ownedFile(version: 2)
        let file = try XCTUnwrap(owned.integration.ownedFile?.file)
        let current = Data(file.contents.utf8)
        let older = Data(TestAgent.ownedFile(version: 1).integration.ownedFile!.file.contents.utf8)
        let later = Data(TestAgent.ownedFile(version: 3).integration.ownedFile!.file.contents.utf8)
        let theirs = Data("export default { mine: true }\n".utf8)

        for original in [nil, older] as [Data?] {
            let write = try XCTUnwrap(try RemoteSettings.plan(.agent(owned), .install, original: original))
            XCTAssertEqual(write, RemoteSettings.Write(contents: current, backup: nil, form: .whole))
        }
        XCTAssertNil(try RemoteSettings.plan(.agent(owned), .install, original: current), "current: nothing")
        XCTAssertNil(try RemoteSettings.plan(.agent(owned), .install, original: later), "a later copy's is current")
        XCTAssertThrowsError(try RemoteSettings.plan(.agent(owned), .install, original: theirs)) {
            XCTAssertEqual($0 as? RemoteSettings.Failure, .file(.malformed), "the user's file is refused")
        }

        for original in [current, older, later] {
            XCTAssertEqual(try RemoteSettings.plan(.agent(owned), .remove, original: original),
                           RemoteSettings.Write(contents: Data(), backup: nil, form: .removal))
        }
        XCTAssertNil(try RemoteSettings.plan(.agent(owned), .remove, original: nil), "nothing to remove")
        XCTAssertNil(try RemoteSettings.plan(.agent(owned), .remove, original: theirs), "the user's file stays")
    }

    /// The reading takes the state from the bytes by the local card's rule
    /// (`AgentIntegration.state`), and a section the server could not give
    /// is the same words as for a settings file.
    func testTheReadingOfAServerIsTheLocalCardsRule() {
        let owned = TestAgent.ownedFile()
        let file = owned.integration.ownedFile!.file
        func reading(_ files: [AgentID: Result<RemoteSettings.Snapshot, SettingsFile.Failure>]) -> RemoteSettings.Reading {
            RemoteSettings.Reading(files: files, command: .missing)
        }
        func snapshot(_ text: String?) -> Result<RemoteSettings.Snapshot, SettingsFile.Failure> {
            .success(RemoteSettings.Snapshot(bytes: text.map { Data($0.utf8) }, checksum: "1 2"))
        }
        let states: [(String?, AgentIntegration.State)] = [
            (nil, .init(hooks: .missing, relay: nil)),
            (file.contents, .init(hooks: .current, relay: nil)),
            (file.contents + "// edited\n", .init(hooks: .outdated, relay: nil)),
            ("export default {}\n", .init(hooks: .missing, relay: nil, foreign: true)),
        ]
        for (text, expected) in states {
            let read = reading([owned.id: snapshot(text)])
            XCTAssertEqual(read.unit(owned), .state(expected), text ?? "no file")
            XCTAssertEqual(read.hooks(owned), .state(expected.hooks), text ?? "no file")
        }
        XCTAssertEqual(reading([owned.id: .failure(.noDirectory)]).unit(owned), .noDirectory)
        XCTAssertEqual(reading([owned.id: .failure(.unreadable)]).unit(owned), .unreadable)
        XCTAssertEqual(reading([:]).unit(owned), .unreadable)
    }

    /// The pasted block puts each part on a quoted heredoc, ended by a line
    /// that is its delimiter alone: a file whose text holds such a line would
    /// end a part early. Held here for a stand-in; the plugin's own is held in
    /// the agents' tests.
    func testNoLineOfAnOwnedFileEndsAPart() throws {
        let owned = TestAgent.ownedFile()
        let write = try XCTUnwrap(try RemoteSettings.plan(.agent(owned), .install, original: nil))
        let block = try XCTUnwrap(RemoteSettings.combinedScript(
            RemoteSettings.Reading(files: [owned.id: .success(RemoteSettings.Snapshot(bytes: nil, checksum: "absent"))],
                                   command: .foreign),
            agents: [owned]))
        XCTAssertTrue(block.contains(String(decoding: write.contents, as: UTF8.self).split(separator: "\n").first!))
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.filter { $0 == Substring(RemoteSettings.combinedDelimiter) }.count, 1,
                       "the one part ends once")
    }
}
