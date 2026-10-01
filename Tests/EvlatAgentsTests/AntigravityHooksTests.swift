import XCTest
@testable import EvlatCore

/// Antigravity: the installed entry, the route that takes the event from a
/// header, and the adapter over bodies measured from the app (2.18.1) and
/// the CLI (1.2.14). Paths in the fixtures are anonymised; the shapes are
/// the wire's.
final class AntigravityHooksTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evlat-antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: AgentSource.antigravity.configDirectory(home: home),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var file: URL { AgentSource.antigravity.settingsFile(home: home) }

    // MARK: - Fixtures (measured)

    private static let conversation = "f202ad9c-e93b-4abc-a293-ac9623e69fcc"

    private static func body(_ extra: [String: Any]) -> [String: Any] {
        var json: [String: Any] = [
            "artifactDirectoryPath": "/Users/someone/.gemini/antigravity/brain/\(conversation)",
            "conversationId": conversation,
            "modelName": "gemini-3.8-flash-high",
            "transcriptPath": "/Users/someone/.gemini/antigravity/brain/\(conversation)/.system_generated/logs/transcript_full.jsonl",
            "workspacePaths": ["/Users/someone/Desktop/project"],
        ]
        json.merge(extra) { $1 }
        return json
    }

    private static let toolCall: [String: Any] = [
        "name": "run_command",
        "args": ["CommandLine": "ls -a", "Cwd": "/Users/someone/Desktop/project", "WaitMsBeforeAsync": 5000,
                 "toolAction": "Listing files", "toolSummary": "File listing"],
    ]

    private static let turn: [(String, [String: Any])] = [
        ("PreInvocation", body(["initialNumSteps": 1, "invocationNum": 0])),
        ("PreToolUse", body(["stepIdx": 2, "toolCall": toolCall])),
        ("PostToolUse", body(["stepIdx": 2, "toolCall": toolCall, "error": ""])),
        ("PostInvocation", body(["initialNumSteps": 1, "invocationNum": 0])),
        ("PreInvocation", body(["initialNumSteps": 3, "invocationNum": 1])),
        ("PostInvocation", body(["initialNumSteps": 3, "invocationNum": 1])),
        ("Stop", body(["executionNum": 0, "fullyIdle": true, "terminationReason": "NO_TOOL_CALL", "error": ""])),
    ]

    /// What the server hands on: the body, with the header's event name and
    /// the pid written in (`LocalAPI.handle`).
    private func delivered(_ event: String, _ body: [String: Any], pid: Int32 = 4242) -> HookEvent? {
        let data = try! JSONSerialization.data(withJSONObject: body)
        let outcome = LocalAPI.handle(HTTPRequest(method: "POST", target: "/hook/antigravity", body: data,
                                                  pid: String(pid), host: "127.0.0.1:48151", event: event))
        guard case .hook(let hook)? = outcome.delivery else { return nil }
        return hook
    }

    // MARK: - The installed entry

    /// Byte for byte, one command per event: the event rides in a header,
    /// because the body does not name it.
    func testTheInstalledCommandNamesItsEvent() {
        XCTAssertEqual(LocalAPI.installedHookCommand(for: .antigravity, event: "Stop"),
                       "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H 'X-Evlat-Event: Stop'"
                           + " -H \"X-Evlat-Task: ${EVLAT_TASK:-}\" -H \"X-Evlat-Pid: $PPID\""
                           + " --data-binary @- http://127.0.0.1:48151/hook/antigravity >/dev/null 2>&1 || true")
        XCTAssertEqual(LocalAPI.installedHookCommand(for: .claude, event: "Stop"),
                       LocalAPI.installedHookCommand(for: .claude), "Claude's bytes do not change")
    }

    func testTheEntryHasEveryEventInItsShape() throws {
        let entry = AntigravityHooks.installed
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        for event in AgentSource.antigravity.hookEvents {
            let list = try XCTUnwrap(entry[event] as? [[String: Any]], event)
            let hook: [String: Any]
            if event == "PreToolUse" || event == "PostToolUse" {
                XCTAssertEqual(list.first?["matcher"] as? String, "*")
                hook = try XCTUnwrap((list.first?["hooks"] as? [[String: Any]])?.first)
            } else {
                hook = try XCTUnwrap(list.first)
            }
            XCTAssertEqual(hook["type"] as? String, "command")
            XCTAssertEqual(hook["command"] as? String, LocalAPI.installedHookCommand(for: .antigravity, event: event))
        }
    }

    func testInstallAddsOnlyOurNameAndRemoveTakesOnlyIt() throws {
        try Data(#"{"their-hook":{"enabled":true,"Stop":[{"type":"command","command":"/usr/local/bin/other"}]}}"#.utf8).write(to: file)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .antigravity), .missing)
        try LocalHooks.install(at: file, for: .antigravity)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .antigravity), .current)
        let installed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotNil(installed["their-hook"], "another tool's entry stays")
        XCTAssertEqual(try LocalHooks.install(at: file, for: .antigravity), .unchanged)
        try LocalHooks.remove(at: file, for: .antigravity)
        let removed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(removed["evlat"])
        XCTAssertNotNil(removed["their-hook"])
    }

    /// Present by the app's or the CLI's folder, the hooks folder may not be
    /// there yet: the install makes it.
    func testInstallMakesTheHooksFolder() throws {
        let fresh = home.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: fresh.appendingPathComponent(".gemini/antigravity-cli"),
                                                withIntermediateDirectories: true)
        let file = AgentSource.antigravity.settingsFile(home: fresh)
        XCTAssertEqual(try LocalHooks.install(at: file, for: .antigravity), .written)
        XCTAssertEqual(try LocalHooks.state(at: file, for: .antigravity), .current)
    }

    func testAChangedEntryReadsOutdated() {
        var entry = AntigravityHooks.installed
        entry["enabled"] = false
        XCTAssertEqual(AntigravityHooks.state(of: ["evlat": entry]), .outdated)
        XCTAssertEqual(AntigravityHooks.state(of: ["evlat": "x"]), .outdated)
    }

    /// A server gets it too, in its own shape and with its command alone.
    func testAServerGetsItInItsOwnShape() throws {
        let original = Data(#"{"their-hook":{"enabled":true}}"#.utf8)
        let write = try XCTUnwrap(try RemoteSettings.plan(.hooks(.antigravity), .install, original: original))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: write.contents) as? [String: Any])
        XCTAssertNotNil(written["their-hook"])
        XCTAssertEqual(AntigravityHooks.state(of: written), .current)
        XCTAssertNil(try RemoteSettings.plan(.hooks(.antigravity), .install, original: write.contents),
                     "installed: nothing to write")
        let removed = try XCTUnwrap(try RemoteSettings.plan(.hooks(.antigravity), .remove, original: write.contents))
        let left = try XCTUnwrap(JSONSerialization.jsonObject(with: removed.contents) as? [String: Any])
        XCTAssertNil(left["evlat"])
        XCTAssertTrue(RemoteSettings.manual.hooks(for: .antigravity).contains("/hook/antigravity"))
    }

    func testItIsPresentWithTheAppsOrTheCLIsDirectory() throws {
        let bare = home.appendingPathComponent("bare")
        try FileManager.default.createDirectory(at: bare.appendingPathComponent(".gemini/config"),
                                                withIntermediateDirectories: true)
        XCTAssertFalse(AgentSource.antigravity.isPresent(home: bare), "Gemini CLI alone is not Antigravity")
        try FileManager.default.createDirectory(at: bare.appendingPathComponent(".gemini/antigravity-cli"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(AgentSource.antigravity.isPresent(home: bare))
    }

    // MARK: - The route and the adapter

    func testTheHeaderNamesTheEventOnlyWhenTheBodyDoesNot() throws {
        let event = try XCTUnwrap(delivered("Stop", Self.turn.last!.1))
        XCTAssertEqual(event.name, "Stop")
        XCTAssertEqual(event.source, .antigravity)
        let named = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s"])
        let claude = LocalAPI.handle(HTTPRequest(method: "POST", target: "/hook", body: named,
                                                 host: "127.0.0.1:48151", event: "PreToolUse"))
        guard case .hook(let hook)? = claude.delivery else { return XCTFail("no event") }
        XCTAssertEqual(hook.name, "Stop", "a body that names its event keeps it")
    }

    func testTheBodyIsReadInClaudesWords() throws {
        let start = try XCTUnwrap(delivered("PreInvocation", Self.turn[0].1))
        XCTAssertEqual(start.name, "UserPromptSubmit", "a turn's first model call is its start")
        XCTAssertEqual(start.sessionID, Self.conversation)
        XCTAssertEqual(start.cwd, "/Users/someone/Desktop/project")
        XCTAssertEqual(start.pid, 4242, "the pid the server wrote is carried through")
        let tool = try XCTUnwrap(delivered("PreToolUse", Self.turn[1].1))
        XCTAssertEqual(tool.toolName, "Bash")
        XCTAssertEqual(tool.toolSubject, "ls -a")
        let later = try XCTUnwrap(delivered("PreInvocation", Self.turn[4].1))
        XCTAssertEqual(later.name, "PreInvocation", "a later model call of the turn changes nothing")
    }

    func testAMeasuredTurnWorksThenFinishes() throws {
        let hooks = HooksProvider(platform: Platform(isAlive: { _ in true }, processStartedAt: { _ in nil }))
        var phases: [Phase] = []
        for (name, body) in Self.turn {
            hooks.handle(try XCTUnwrap(delivered(name, body)))
            if let phase = hooks.currentSignals().first?.phase, phases.last != phase { phases.append(phase) }
        }
        XCTAssertEqual(phases, [.working, .review])
        let row = try XCTUnwrap(hooks.currentSignals().first)
        XCTAssertEqual(row.label, "project")
        XCTAssertEqual(row.source, .antigravity)
        XCTAssertEqual(row.activity?.lastTool?.name, "Bash")
    }

    // MARK: - The last reply

    private static let steps = """
    {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nsecret words\\n</USER_REQUEST>"}
    {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":""}
    {"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","content":"tool output"}
    {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"All done.\\n\\nThe folder has two files."}

    """

    private func transcript(_ text: String = steps, under folder: String = ".gemini/antigravity-cli/brain/c-1") throws -> URL {
        let directory = home.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("transcript_full.jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testTheLastReplyIsTheLastModelTextAndNothingElse() {
        XCTAssertEqual(AntigravityTranscript.lastReply(in: Data(Self.steps.utf8), cut: false),
                       "All done.\n\nThe folder has two files.")
        let onlyUser = #"{"source":"USER_EXPLICIT","type":"USER_INPUT","content":"hi"}"#
        XCTAssertNil(AntigravityTranscript.lastReply(in: Data(onlyUser.utf8), cut: false), "never the user's words")
        let cut = #"PONSE","content":"half"}"# + "\n" + #"{"source":"MODEL","type":"PLANNER_RESPONSE","content":"whole"}"#
        XCTAssertEqual(AntigravityTranscript.lastReply(in: Data(cut.utf8), cut: true), "whole")
    }

    func testOnlyATranscriptInsideTheRootsIsRead() throws {
        let roots = AntigravityTranscript.roots(home: home)
        let inside = try transcript()
        XCTAssertNotNil(AntigravityTranscript.lastReply(at: inside.path, roots: roots))
        let outside = try transcript(under: "elsewhere")
        XCTAssertNil(AntigravityTranscript.lastReply(at: outside.path, roots: roots))
        let escape = home.path + "/.gemini/antigravity-cli/brain/../../../elsewhere/transcript_full.jsonl"
        XCTAssertNil(AntigravityTranscript.lastReply(at: escape, roots: roots), "no way out through ..")
        let link = home.appendingPathComponent(".gemini/antigravity-cli/brain/c-2")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertNil(AntigravityTranscript.lastReply(at: link.appendingPathComponent("transcript_full.jsonl").path,
                                                     roots: roots), "nor through a link")
        XCTAssertNil(AntigravityTranscript.lastReply(at: inside.path, roots: []), "no roots, nothing read")
    }

    private func stop(transcript path: String, origin: LocalAPI.Origin = .local,
                      extra: [String: Any] = [:]) throws -> HookEvent? {
        var body = Self.turn.last!.1
        body["transcriptPath"] = path
        body.merge(extra) { $1 }
        let data = try JSONSerialization.data(withJSONObject: body)
        let outcome = LocalAPI.handle(HTTPRequest(method: "POST", target: "/hook/antigravity", body: data,
                                                  host: "127.0.0.1:48151", event: "Stop"),
                                      listener: LocalAPI.Listener(origin: origin,
                                                                  transcriptRoots: AntigravityTranscript.roots(home: home)))
        guard case .hook(let event)? = outcome.delivery else { return nil }
        return event
    }

    func testThisMacsFinishCarriesItsReply() throws {
        let path = try transcript().path
        XCTAssertEqual(try stop(transcript: path)?.lastReply, "All done. The folder has two files.",
                       "the paragraphs on one line, as Claude's")
        XCTAssertNil(try stop(transcript: path, origin: .tunneled)?.lastReply,
                     "a tunneled path names a file on another computer")
        XCTAssertEqual(try stop(transcript: "/nowhere.jsonl", extra: ["last_assistant_message": "forged"])?.lastReply,
                       nil, "the body never supplies it")
    }

    func testClaudesOwnReplyIsUntouched() throws {
        let body = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s",
                                                               "last_assistant_message": "Claude's reply."])
        let outcome = LocalAPI.handle(HTTPRequest(method: "POST", target: "/hook", body: body, host: "127.0.0.1:48151"),
                                      listener: LocalAPI.Listener(transcriptRoots: AntigravityTranscript.roots(home: home)))
        guard case .hook(let event)? = outcome.delivery else { return XCTFail("no event") }
        XCTAssertEqual(event.lastReply, "Claude's reply.")
    }
}

extension AntigravityHooksTests {
    /// The card's preview: every paragraph, on one line, cut with "…".
    func testAReplyPreviewKeepsWhatFollowsTheGreeting() {
        XCTAssertEqual(HookEvent.replyPreview("Still fine, thanks! 😊\n\nAre you testing the connection?\n- yes"),
                       "Still fine, thanks! 😊 Are you testing the connection? - yes")
        let long = String(repeating: "word ", count: 100)
        let preview = HookEvent.replyPreview(long)
        XCTAssertEqual(preview?.hasSuffix("…"), true)
        XCTAssertLessThanOrEqual(preview?.count ?? 0, HookEvent.replyLimit + 1)
        XCTAssertNil(HookEvent.replyPreview(" \n\n "))
    }
}
