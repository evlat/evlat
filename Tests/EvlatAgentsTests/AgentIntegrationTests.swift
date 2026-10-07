import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// An agent as one unit: its parts' states make one, the parts in one file
/// are one write, a usage line changed by hand is never written over. Every
/// file is under a temporary home.
final class AgentIntegrationTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.integration.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func directory(_ path: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testThePartsMakeOneState() {
        typealias State = AgentIntegration.State
        XCTAssertEqual(State(hooks: .current, relay: .current).status, .current)
        XCTAssertEqual(State(hooks: .missing, relay: .missing).status, .missing)
        XCTAssertEqual(State(hooks: .current, relay: .missing).status, .outdated, "hooks alone: needs update")
        XCTAssertEqual(State(hooks: .missing, relay: .current).status, .outdated)
        XCTAssertEqual(State(hooks: .outdated, relay: .current).status, .outdated)
        XCTAssertEqual(State(hooks: .current, relay: nil).status, .current, "no status line: hooks are the unit")
        XCTAssertEqual(State(hooks: .missing, relay: nil).status, .missing)
        XCTAssertEqual(State(hooks: .current, relay: .modified).status, .current, "changed by hand: not a part")
        XCTAssertEqual(State(hooks: .missing, relay: .modified).status, .missing)
        XCTAssertFalse(State(hooks: .missing, relay: .modified).installsRelay)
        XCTAssertTrue(State(hooks: .current, relay: .missing).installsRelay)
    }

    /// Claude's hooks, approval hook and usage line live in one file and go
    /// in with one write: the first backup holds the file as it was, the
    /// relay's backup the `statusLine` it wrapped.
    func testClaudeIsOneFileAndOneWrite() throws {
        try directory(".claude")
        let file = Claude().hooksFile(home: home)
        let original = Data(#"{"model":"opus","statusLine":{"type":"command","command":"bash ~/s.sh"}}"#.utf8)
        try original.write(to: file)
        XCTAssertEqual(AgentIntegration.files(home: home, for: .claude), [file])

        try AgentIntegration.install(home: home, for: .claude)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .current, "hooks and the approval hook")
        XCTAssertEqual(try ApprovalHook.state(of: json(file), for: Claude().approvals!), .current)
        XCTAssertEqual(try StatusLineRelay.state(at: file, source: .claude), .current)
        XCTAssertEqual(try json(file)["model"] as? String, "opus")
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("evlat.bak")), original)
        let kept = file.appendingPathExtension(StatusLineRelay.backupExtension)
        let line = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: kept)) as? [String: Any])
        XCTAssertEqual(line["command"] as? String, "bash ~/s.sh")
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .claude).status, .current)

        // Updating old hooks alone does not take the wrapper for the original.
        var settings = try json(file)
        settings["hooks"] = HookSettings.installing(into: [:], for: .codex)["hooks"]
        try JSONSerialization.data(withJSONObject: settings).write(to: file)
        try AgentIntegration.install(home: home, for: .claude)
        let still = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: kept)) as? [String: Any])
        XCTAssertEqual(still["command"] as? String, "bash ~/s.sh", "the kept original stays")

        try AgentIntegration.remove(home: home, for: .claude)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .claude).status, .missing)
        XCTAssertEqual((try json(file)["statusLine"] as? [String: Any])?["command"] as? String, "bash ~/s.sh")
    }

    /// A usage line edited by hand stays byte for byte; the hooks go in.
    func testAHandEditedRelayIsNotWrittenOver() throws {
        try directory(".claude")
        let file = Claude().hooksFile(home: home)
        let edited = StatusLineRelay.command(wrapping: "cat", source: .claude).replacingOccurrences(of: "-m 2", with: "-m 9")
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": edited]]).write(to: file)
        try AgentIntegration.install(home: home, for: .claude)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .claude), .current)
        XCTAssertEqual((try json(file)["statusLine"] as? [String: Any])?["command"] as? String, edited)
        let state = try AgentIntegration.state(home: home, for: .claude)
        XCTAssertEqual(state.relay, .modified)
        XCTAssertEqual(state.status, .current)
        try AgentIntegration.remove(home: home, for: .claude)
        XCTAssertEqual((try json(file)["statusLine"] as? [String: Any])?["command"] as? String, edited,
                       "nor taken out")
    }

    /// A `statusLine` the relay will not wrap is the user's own, like a
    /// wrapper changed by hand: the hooks complete the unit, and a second
    /// press is not refused.
    func testAStatusLineInAShapeNotOursIsNotAPart() throws {
        try directory(".claude")
        let file = Claude().hooksFile(home: home)
        for value: Any in ["bash s.sh", ["type": "static", "command": "cat"]] {
            try JSONSerialization.data(withJSONObject: ["statusLine": value]).write(to: file)
            XCTAssertEqual(try AgentIntegration.state(home: home, for: .claude).relay, .modified, "\(value)")
            try AgentIntegration.install(home: home, for: .claude)
            XCTAssertEqual(try AgentIntegration.state(home: home, for: .claude).status, .current, "\(value)")
            try AgentIntegration.install(home: home, for: .claude)
            XCTAssertTrue(NSDictionary(dictionary: ["v": try json(file)["statusLine"] as Any]).isEqual(to: ["v": value]),
                          "left as it is: \(value)")
        }
    }

    /// The Antigravity app alone: no status line, so the hooks are the
    /// unit, and its missing hooks folder is made by the install.
    func testAntigravityWithoutItsCLIIsItsHooks() throws {
        try directory(".gemini/antigravity")
        let before = try AgentIntegration.state(home: home, for: .antigravity)
        XCTAssertNil(before.relay)
        XCTAssertEqual(before.hooks, .missing, "a folder the install makes reads missing, not unreadable")
        try AgentIntegration.install(home: home, for: .antigravity)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .antigravity).status, .current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli").path),
                       "no status line was made")
    }

    /// With its CLI the usage line is a part in another file; it can go out
    /// alone, which leaves the unit outdated.
    func testAntigravitysRelayIsItsOwnFile() throws {
        try directory(".gemini/antigravity-cli")
        let relay = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        XCTAssertEqual(AgentIntegration.files(home: home, for: .antigravity),
                       [Antigravity().hooksFile(home: home), relay])
        try AgentIntegration.install(home: home, for: .antigravity)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .antigravity),
                       AgentIntegration.State(hooks: .current, relay: .current))
        try AgentIntegration.removeRelay(home: home, for: .antigravity)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .antigravity),
                       AgentIntegration.State(hooks: .current, relay: .missing))
        try AgentIntegration.install(home: home, for: .antigravity)
        try AgentIntegration.remove(home: home, for: .antigravity)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .antigravity).status, .missing)
    }

    /// A refused part is named: the relay's shape is not ours, the hooks of
    /// the same write still went in.
    /// A relay installed with no hooks (an earlier version's own row):
    /// the missing hooks folder does not keep the relay from going.
    func testRemovingWithoutTheHooksFolderStillTakesTheRelay() throws {
        try directory(".gemini/antigravity-cli")
        try AgentIntegration.install(home: home, for: .antigravity)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".gemini/config"))
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .antigravity),
                       AgentIntegration.State(hooks: .missing, relay: .current))
        try AgentIntegration.remove(home: home, for: .antigravity)
        XCTAssertEqual(try AgentIntegration.state(home: home, for: .antigravity).status, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/config").path),
                       "nothing made to take nothing out")
    }

    func testARefusedPartIsNamed() throws {
        try directory(".gemini/antigravity-cli")
        let relay = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        try Data("{ not json".utf8).write(to: relay)
        XCTAssertThrowsError(try AgentIntegration.install(home: home, for: .antigravity)) { error in
            XCTAssertEqual(error as? AgentIntegration.Failure, AgentIntegration.Failure(part: .usage, reason: .malformed))
        }
        XCTAssertEqual(try LocalHooks.state(at: Antigravity().hooksFile(home: home), for: .antigravity),
                       .current, "the hooks' own file is written before")
        try directory(".claude")
        let file = Claude().hooksFile(home: home)
        try Data("{ not json".utf8).write(to: file)
        XCTAssertThrowsError(try AgentIntegration.install(home: home, for: .claude)) { error in
            XCTAssertEqual(error as? AgentIntegration.Failure, AgentIntegration.Failure(part: .hooks, reason: .malformed))
        }
    }
}
