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

    func testAServerLeavesItOut() throws {
        let owned = TestAgent.ownedFile()
        let other = TestAgent("other")
        XCTAssertFalse(RemoteSettings.serves(owned))
        XCTAssertTrue(RemoteSettings.serves(other))

        let reading = RemoteSettings.readingScript(nonce: "n", agents: [owned, other])
        XCTAssertFalse(reading.contains(" begin test "), "no section is read for it")
        XCTAssertTrue(reading.contains(" begin other "))

        let manual = RemoteSettings.manual(agents: [owned, other])
        XCTAssertEqual(manual.hooks(for: owned), "")
        XCTAssertFalse(manual.hooks(for: other).isEmpty)

        for change in [RemoteSettings.Change.hooks(owned), .agent(owned), .statusLine(owned)] {
            for action in [RemoteSettings.Action.install, .remove] {
                XCTAssertThrowsError(try RemoteSettings.plan(change, action, original: nil), "\(change) \(action)") {
                    XCTAssertEqual($0 as? RemoteSettings.Failure, .file(.malformed))
                }
            }
        }
        XCTAssertFalse(RemoteSettings.relays(owned))
        XCTAssertTrue(RemoteSettings.Change.hooks(owned).opening.isEmpty)
    }
}
