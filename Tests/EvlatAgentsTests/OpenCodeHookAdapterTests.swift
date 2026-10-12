import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// What OpenCode's events mean: the plugin's bodies become the canonical
/// vocabulary here, and the canonical vocabulary moves a row there. The
/// recorded sessions are bodies the plugin really posted (1.18.34, 1.19.0
/// and 2.0.27, a fake model behind them, folders made over); a recording
/// is refreshed by running `make test-opencode` and keeping what the
/// recorder saw.
final class OpenCodeHookAdapterTests: XCTestCase {
    private func canonical(_ json: [String: Any]) -> [String: Any] {
        OpenCodeHookAdapter.canonical(json)
    }

    private func name(_ json: [String: Any]) -> String? {
        canonical(json)["hook_event_name"] as? String
    }

    // MARK: - The table

    func testEveryEventMeansWhatTheTableSays() {
        let table: [([String: Any], String)] = [
            (["event": "session.created"], "SessionStart"),
            (["event": "session.deleted"], "SessionEnd"),
            (["event": "session.status", "status": "busy"], "UserPromptSubmit"),
            (["event": "session.execution.started"], "UserPromptSubmit"),
            (["event": "session.idle"], "Stop"),
            (["event": "session.execution.succeeded"], "Stop"),
            (["event": "session.execution.interrupted"], "Stop"),
            (["event": "session.execution.failed", "error": "provider.invalid-request"], "StopFailure"),
            (["event": "session.error", "error": "APIError"], "StopFailure"),
            (["event": "session.error", "error": "MessageAbortedError"], "Stop"),
            (["event": "message.part.updated", "status": "running"], "PreToolUse"),
            (["event": "message.part.updated", "status": "completed"], "PostToolUse"),
            (["event": "message.part.updated", "status": "error"], "PostToolUseFailure"),
            (["event": "session.tool.called"], "PreToolUse"),
            (["event": "session.tool.success"], "PostToolUse"),
            (["event": "session.tool.failed"], "PostToolUseFailure"),
            (["event": "permission.asked", "ask": ["kind": "bash"]], "PermissionRequest"),
            (["event": "question.asked", "ask": ["kind": "question"]], "PermissionRequest"),
            (["event": "form.created", "ask": ["kind": "question"]], "PermissionRequest"),
            // A form that is no question carries no ask: a word nothing reads, not a wait.
            (["event": "form.created"], "form.created"),
            (["event": "permission.replied", "reply": "once"], "PostToolUse"),
            (["event": "permission.replied", "reply": "always"], "PostToolUse"),
            (["event": "permission.replied", "reply": "reject"], "PermissionDenied"),
            (["event": "question.replied", "reply": "once"], "PostToolUse"),
            (["event": "question.rejected", "reply": "reject"], "PermissionDenied"),
            (["event": "form.replied", "reply": "once"], "PostToolUse"),
        ]
        for (body, expected) in table {
            XCTAssertEqual(name(body), expected, "\(body)")
        }
    }

    /// A word this version does not know passes unchanged, and so does a
    /// status it does not know: it stays visible instead of being swallowed.
    func testAnUnknownEventPassesUnchanged() {
        XCTAssertEqual(name(["event": "todo.updated"]), "todo.updated")
        XCTAssertEqual(name(["event": "session.status", "status": "compacting"]), "session.status")
        XCTAssertEqual(name(["event": "message.part.updated", "status": "paused"]), "message.part.updated")
        XCTAssertEqual(name([:]), "")
        XCTAssertEqual(OpenCodeHookAdapter.events.count, Set(OpenCodeHookAdapter.events).count)
    }

    func testTheEnvelopeBecomesTheCanonicalFields() {
        let out = canonical(["event": "session.created", "session": "ses_1", "child": "ses_2", "directory": "/Users/demo/app",
                             "opencode_version": "1.19.0", HookEvent.pidKey: "4242", HookEvent.taskKey: "task-1",
                             HookEvent.servicePidKey: "900", "plugin_version": 1, "line": 1])
        XCTAssertEqual(out["session_id"] as? String, "ses_1")
        XCTAssertEqual(out["agent_id"] as? String, "ses_2", "a child session is a subagent's step on the root's row")
        XCTAssertEqual(out["cwd"] as? String, "/Users/demo/app")
        XCTAssertEqual(out["agent_version"] as? String, "1.19.0")
        XCTAssertEqual(out["source"] as? String, "startup")
        XCTAssertEqual(out[HookEvent.pidKey] as? String, "4242", "the server's keys pass through")
        XCTAssertEqual(out[HookEvent.servicePidKey] as? String, "900")
        XCTAssertEqual(out[HookEvent.taskKey] as? String, "task-1")
        let event = HookEvent(json: out, source: .opencode)
        XCTAssertEqual(event.name, "SessionStart")
        XCTAssertEqual(event.sessionID, "ses_1")
        XCTAssertEqual(event.agentID, "ses_2")
        XCTAssertEqual(event.agentVersion, "1.19.0")
        XCTAssertEqual(event.startSource, "startup")
        XCTAssertEqual(event.pid, 4242)
        XCTAssertEqual(event.servicePid, 900)
    }

    func testToolsAndTheirInputAreInClaudesSpelling() {
        let one = canonical(["event": "message.part.updated", "status": "running", "tool": "bash",
                             "input": ["command": "ls -la", "description": "list"]])
        XCTAssertEqual(one["tool_name"] as? String, "Bash")
        XCTAssertEqual(HookEvent(json: one, source: .opencode).toolSubject, "ls -la")

        let edit1 = canonical(["event": "message.part.updated", "status": "running", "tool": "edit", "input": ["filePath": "a.swift"]])
        let edit2 = canonical(["event": "session.tool.called", "tool": "edit", "input": ["path": "a.swift"]])
        for edit in [edit1, edit2] {
            XCTAssertEqual(edit["tool_name"] as? String, "Edit")
            XCTAssertEqual((edit["tool_input"] as? [String: Any])?["file_path"] as? String, "a.swift")
        }

        // The two lines name some tools differently.
        for (raw, expected) in [("bash", "Bash"), ("shell", "Bash"), ("task", "Agent"), ("subagent", "Agent"),
                                ("question", "AskUserQuestion"), ("webfetch", "WebFetch"), ("grep", "Grep")] {
            XCTAssertEqual(canonical(["event": "session.tool.called", "tool": raw])["tool_name"] as? String, expected, raw)
        }
        XCTAssertEqual(canonical(["event": "session.tool.called", "tool": "execute"])["tool_name"] as? String, "execute",
                       "a tool not in the table keeps its name")
        XCTAssertNil(canonical(["event": "session.tool.called"])["tool_name"], "a call whose name was not heard names none")
    }

    func testAnAskIsTheToolItIsAbout() throws {
        let bash1 = canonical(["event": "permission.asked", "ask": ["id": "p", "kind": "bash", "patterns": ["rm -rf x"], "command": "rm -rf x"]])
        let bash2 = canonical(["event": "permission.asked", "ask": ["id": "p", "kind": "shell", "patterns": ["rm -rf x"]]])
        for bash in [bash1, bash2] {
            XCTAssertEqual(bash["tool_name"] as? String, "Bash")
            XCTAssertEqual((bash["tool_input"] as? [String: Any])?["command"] as? String, "rm -rf x")
        }
        let edit = canonical(["event": "permission.asked", "ask": ["id": "p", "kind": "edit", "patterns": ["a.txt"], "file": "/r/a.txt"]])
        XCTAssertEqual(edit["tool_name"] as? String, "Edit")
        XCTAssertEqual((edit["tool_input"] as? [String: Any])?["file_path"] as? String, "/r/a.txt")
        let outside = canonical(["event": "permission.asked", "ask": ["id": "p", "kind": "external_directory", "patterns": ["/etc/*"]]])
        XCTAssertEqual(outside["tool_name"] as? String, "external_directory")
        XCTAssertEqual((outside["tool_input"] as? [String: Any])?["pattern"] as? String, "/etc/*")
        let question = canonical(["event": "question.asked", "ask": ["id": "q", "kind": "question", "questions": [
            ["question": "Which colour?", "header": "Colour", "options": [["label": "Red"]]]]]])
        XCTAssertEqual(question["tool_name"] as? String, "AskUserQuestion")
        XCTAssertEqual(HookEvent(json: question, source: .opencode).toolSubject, "Which colour?")
    }

    // MARK: - Recorded sessions

    private struct Recording: Decodable {
        let name: String
        let bodies: [[String: JSONValue]]
    }

    /// Enough of JSON to read a recording back as dictionaries.
    private enum JSONValue: Decodable {
        case value(Any)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(String.self) { self = .value(v) }
            else if let v = try? c.decode(Int.self) { self = .value(v) }
            else if let v = try? c.decode(Bool.self) { self = .value(v) }
            else if let v = try? c.decode([String: JSONValue].self) { self = .value(v.mapValues(\.any)) }
            else if let v = try? c.decode([JSONValue].self) { self = .value(v.map(\.any)) }
            else { self = .value(NSNull()) }
        }
        var any: Any { if case .value(let v) = self { return v } else { return NSNull() } }
    }

    private func recordings() throws -> [Recording] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/opencode-wire.json")
        return try JSONDecoder().decode([Recording].self, from: Data(contentsOf: url))
    }

    /// The phase after each body, the way Evlat's own provider reads it.
    private func phases(_ recording: Recording) -> [String] {
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        let provider = HooksProvider(platform: Platform(isAlive: { _ in true }, processStartedAt: { _ in nil }, now: { clock }),
                                     isQuestion: Agents.isQuestion)
        return recording.bodies.map { body in
            var json = body.mapValues(\.any)
            // The pid is sent on 1.x; the shared service on 2.x sends its own.
            if (json["line"] as? Int) == 1 { json[HookEvent.pidKey] = "4242" } else { json[HookEvent.servicePidKey] = "900" }
            provider.handle(HookEvent(json: canonical(json), source: .opencode))
            return provider.currentSignals().first.map { $0.phase.rawValue } ?? "none"
        }
    }

    private func recording(_ name: String) throws -> Recording {
        try XCTUnwrap(recordings().first { $0.name == name }, name)
    }

    func testRecordedSessionsMoveTheRowAsTheyShould() throws {
        let expected: [String: [String]] = [
            "1.19.0 bash, allowed": ["idle", "working", "working", "waiting", "working", "working", "review"],
            "1.19.0 bash, rejected": ["idle", "working", "working", "waiting", "working", "working", "review"],
            "1.18.34 bash, allowed": ["idle", "working", "working", "waiting", "working", "working", "review"],
            "2.0.27 bash, allowed": ["idle", "working", "working", "waiting", "working", "working", "review"],
            "2.0.27 bash, rejected": ["idle", "working", "working", "waiting", "working", "working", "review"],
            // The turn ends with the tool still waiting: the end is the user's, not a failure.
            "1.19.0 abort with a permission open": ["idle", "working", "working", "waiting", "review"],
            "2.0.27 interrupt with a permission open": ["idle", "working", "working", "waiting", "review"],
            "1.19.0 provider error": ["idle", "working", "failed"],
            "2.0.27 provider error": ["idle", "working", "failed"],
        ]
        for (name, phases) in expected {
            XCTAssertEqual(self.phases(try recording(name)), phases, name)
        }
    }

    /// One reply with two tool calls: the row waits until the last is answered.
    func testTwoPermissionsAtOnceWaitUntilTheLastIsAnswered() throws {
        for name in ["1.19.0 two permissions at once", "2.0.27 two permissions at once"] {
            let phases = self.phases(try recording(name))
            let firstWait = try XCTUnwrap(phases.firstIndex(of: "waiting"), name)
            let lastWait = try XCTUnwrap(phases.lastIndex(of: "waiting"), name)
            XCTAssertEqual(Set(phases[firstWait...lastWait]), ["waiting"], "\(name): \(phases)")
            XCTAssertEqual(phases.last, "review", name)
        }
    }

    func testASubagentsQuestionIsTheRootsWaitAndItsEndIsNot() throws {
        for name in ["1.19.0 subagent asks", "2.0.27 subagent asks"] {
            let phases = self.phases(try recording(name))
            XCTAssertTrue(phases.contains("waiting"), name)
            XCTAssertEqual(phases.last, "review", name)
            XCTAssertEqual(phases.filter { $0 == "review" }.count, 1, "\(name): the child's end is not a finish: \(phases)")
        }
    }

    func testAQuestionIsAnAnswerToWaitFor() throws {
        for name in ["1.19.0 question", "2.0.27 question"] {
            let recording = try self.recording(name)
            let phases = self.phases(recording)
            XCTAssertEqual(phases.last, "waiting", "\(name): the question is still open: \(phases)")
            let clock = Date(timeIntervalSince1970: 1_790_000_000)
            let provider = HooksProvider(platform: Platform(isAlive: { _ in true }, processStartedAt: { _ in nil }, now: { clock }),
                                         isQuestion: Agents.isQuestion)
            for body in recording.bodies {
                provider.handle(HookEvent(json: canonical(body.mapValues(\.any)), source: .opencode))
            }
            let activity = try XCTUnwrap(provider.currentSignals().first?.activity)
            XCTAssertEqual(activity.waitKind, .answer, name)
            XCTAssertEqual(activity.blockingTool?.name, "AskUserQuestion", name)
        }
    }

    /// Every recording is a row of one folder, named for it; and the version
    /// each line said is heard.
    func testARecordedSessionIsOneRowOfItsFolder() throws {
        for recording in try recordings() {
            let clock = Date(timeIntervalSince1970: 1_790_000_000)
            let provider = HooksProvider(platform: Platform(isAlive: { _ in true }, processStartedAt: { _ in nil }, now: { clock }),
                                         isQuestion: Agents.isQuestion)
            for body in recording.bodies { provider.handle(HookEvent(json: canonical(body.mapValues(\.any)), source: .opencode)) }
            let rows = provider.currentSignals()
            XCTAssertEqual(rows.count, 1, "\(recording.name): a subagent has no row of its own")
            XCTAssertEqual(rows.first?.label, "app", recording.name)
            let version = provider.agentVersion(of: .opencode)
            let said = recording.bodies.contains { $0["opencode_version"] != nil }
            XCTAssertEqual(version != nil, said, "\(recording.name): the version a line said is the one heard")
            XCTAssertTrue(OpenCode().hasMeasured(version: version), "\(recording.name): \(version ?? "nil")")
        }
    }

    // MARK: - The card

    private func permissionBodies(_ name: String) throws -> [[String: Any]] {
        try recording(name).bodies.map { $0.mapValues(\.any) }.filter { ($0["event"] as? String) == "permission.asked" }
    }

    /// The bodies the plugin really posted to the card, both lines: the
    /// command (1.x says `bash` and the command in its metadata, 2.x `shell`
    /// and the command as the resource), the root's session as the row, the
    /// asking subagent as the actor.
    func testRecordedPermissionsAreCardsOfTheirRootsRow() throws {
        let channel = OpenCodeApprovals()
        for name in ["1.18.34 bash, allowed", "1.19.0 bash, allowed", "2.0.27 bash, allowed"] {
            let body = try XCTUnwrap(permissionBodies(name).first, name)
            let request = try XCTUnwrap(channel.request(json: body), name)
            XCTAssertEqual(request.tool, "Bash", name)
            XCTAssertEqual(request.command, "echo evlat-probe", name)
            XCTAssertEqual(request.subject, "echo evlat-probe", name)
            XCTAssertEqual(request.sessionID, body["session"] as? String, name)
            XCTAssertEqual(request.cwd, body["directory"] as? String, name)
            XCTAssertNil(request.subagent, name)
            XCTAssertNil(request.questions, name)
            XCTAssertTrue(request.rules.isEmpty && request.directories.isEmpty, name)
        }
        for name in ["1.19.0 subagent asks", "2.0.27 subagent asks"] {
            let body = try XCTUnwrap(permissionBodies(name).first, name)
            let request = try XCTUnwrap(channel.request(json: body), name)
            XCTAssertEqual(request.sessionID, body["session"] as? String, "\(name): the root's row")
            XCTAssertEqual(request.subagent, body["child"] as? String, "\(name): the subagent is the actor")
            XCTAssertNotEqual(request.sessionID, request.subagent, name)
        }
        for name in ["1.19.0 two permissions at once", "2.0.27 two permissions at once"] {
            let commands = try permissionBodies(name).compactMap { channel.request(json: $0)?.command }
            XCTAssertEqual(commands, ["echo evlat-one", "echo evlat-two"], name)
        }
    }

    /// An edit says its file, in the shapes the plugin pulls out of each line
    /// (1.x `metadata.filepath`, 2.x `files[0].file`); a permission with no
    /// tool of ours is still a card, about its pattern.
    func testAnEditAndAnUnknownPermissionAreCardsToo() throws {
        let channel = OpenCodeApprovals()
        func body(_ ask: [String: Any]) -> [String: Any] {
            ["event": "permission.asked", "session": "s1", "directory": "/r", "ask": ask]
        }
        let edit = try XCTUnwrap(channel.request(json: body(["id": "p", "kind": "edit", "patterns": ["a.txt"], "file": "/r/a.txt"])))
        XCTAssertEqual(edit.tool, "Edit")
        XCTAssertEqual(edit.subject, "/r/a.txt")
        let outside = try XCTUnwrap(channel.request(json: body(["id": "p", "kind": "external_directory", "patterns": ["/etc/*"]])))
        XCTAssertEqual(outside.tool, "external_directory")
        XCTAssertEqual(outside.subject, "/etc/*")
    }

    /// A question is answered in OpenCode, and so is no card (the plugin does not
    /// even ask); neither is an event that is no permission.
    func testOnlyAPermissionIsACard() throws {
        let channel = OpenCodeApprovals()
        let asking: [String: Any] = ["event": "question.asked", "session": "s1",
                                     "ask": ["id": "q", "kind": "question",
                                             "questions": [["question": "Which?", "options": [["label": "A"]]]]]]
        XCTAssertNil(channel.request(json: asking))
        let form: [String: Any] = ["event": "form.created", "session": "s1",
                                   "ask": ["id": "f", "kind": "question", "questions": [["question": "Which?"]]]]
        XCTAssertNil(channel.request(json: form))
        XCTAssertNil(channel.request(json: ["event": "session.idle", "session": "s1"]))
        XCTAssertNil(channel.request(json: ["event": "permission.replied", "session": "s1", "reply": "once"]))
        XCTAssertNil(channel.request(json: [:]))
    }

    // MARK: - Versions

    func testTheMeasuredLines() {
        let agent = OpenCode()
        for version in ["1.18.34", "1.18.0", "1.19.0", "2.0.22", "2.0.27", "2.0", nil] {
            XCTAssertTrue(agent.hasMeasured(version: version), version ?? "nil")
        }
        for version in ["1.17.9", "1.20.0", "1.190.1", "2.1.0", "2.01", "3.0.0", "garbage"] {
            XCTAssertFalse(agent.hasMeasured(version: version), version)
        }
        XCTAssertTrue(Claude().hasMeasured(version: "9.9.9"), "an agent measured on no lines has nothing to be outside of")
    }
}
