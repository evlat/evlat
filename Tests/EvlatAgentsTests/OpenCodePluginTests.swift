import XCTest
import JavaScriptCore
@testable import EvlatCore
@testable import EvlatAgents

/// The plugin file is an installed contract: the bytes below are what every
/// copy of Evlat writes into OpenCode's plugin folder, and OpenCode loads
/// whatever is there. A failing golden means the file changed — bump
/// `OpenCodePlugin.version` once a release has carried the old one, then
/// refresh the fixture with `EVLAT_UPDATE_GOLDEN=1`.
///
/// Its behaviour is held in two halves. The pure part — what an event
/// becomes, and what is held, dropped or told once — runs here in
/// JavaScriptCore, on events shaped like the ones measured on 1.19.0 and
/// 2.0.27. What only a real OpenCode can say (that the file loads, which
/// entry point it calls, what the socket sees) is `OpenCodeLiveTests`'.
final class OpenCodePluginTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    // MARK: - The file

    func testTheFileIsUnchanged() throws {
        let golden = fixtures.appendingPathComponent("opencode-plugin.js")
        if ProcessInfo.processInfo.environment["EVLAT_UPDATE_GOLDEN"] == "1" {
            try OpenCodePlugin.file.contents.write(to: golden, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(OpenCodePlugin.file.contents, try String(contentsOf: golden, encoding: .utf8))
    }

    func testTheFileIsMarkedAndVersioned() {
        let lines = OpenCodePlugin.file.contents.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "// evlat-opencode-plugin")
        XCTAssertEqual(lines[1], "// version \(OpenCodePlugin.version)")
        XCTAssertEqual(OpenCodePlugin.file.state(of: Data(OpenCodePlugin.file.contents.utf8)), .current)
        XCTAssertEqual(OpenCodePlugin.file.path, ".config/opencode/plugins/evlat.js")
    }

    /// OpenCode loads only an ESM `.js`: a CommonJS file is skipped silently
    /// by 2.x. One default export serves both lines.
    func testItIsAnEsModuleWithOneDefaultExport() {
        let text = OpenCodePlugin.file.contents
        XCTAssertTrue(text.contains("export default { id: \"evlat\", server, setup };"))
        XCTAssertFalse(text.contains("module.exports"))
        XCTAssertFalse(text.contains("require("))
        XCTAssertEqual(text.components(separatedBy: "export ").count - 1, 1)
        XCTAssertFalse(OpenCodePlugin.pure.contains("import "), "the pure part runs where there is no module")
        XCTAssertFalse(OpenCodePlugin.pure.contains("export "))
    }

    /// The rules that keep a plugin from hurting the agent it listens to:
    /// it only listens (a hook that fires before a tool and throws refuses
    /// the tool), it never prints (a terminal UI owns the screen), it has no
    /// `$` (Node has none), and every request has its own timeout.
    func testItOnlyListensAndNeverPrints() throws {
        let text = OpenCodePlugin.file.contents
        for hook in ["tool.execute", "permission.ask\"", "chat.message", "chat.params", "shell.env", "\"config\"", "auth:"] {
            XCTAssertFalse(text.contains(hook), "no hook but `event`: \(hook)")
        }
        for printing in ["console.", "process.stdout", "process.stderr", "$`", "Bun.", "fetch("] {
            XCTAssertFalse(text.contains(printing), printing)
        }
        XCTAssertEqual(text.components(separatedBy: "request({").count - 1, 1, "one place posts")
        XCTAssertEqual(text.components(separatedBy: "req.setTimeout(options.timeout").count - 1, 1, "every request is bounded")
        XCTAssertTrue(text.contains("req.on(\"error\", () => finish(null))"))
        XCTAssertTrue(text.contains("{ pid, timeout: TIMEOUT_MS }"), "an event post is bounded by 2 s")
        XCTAssertTrue(text.contains("timeout: BRIDGE_TIMEOUT_MS"), "the held request by the channel's own time")
        // Everything OpenCode calls into is wrapped: a throw there is OpenCode's problem.
        for entry in ["async function setup(ctx) {", "function feed(raw, entry) {", "function learnVersion(input) {",
                      "function post(route, body, options) {", "async function apply(bridge, decision, entry) {",
                      "function abortBridge(id) {"] {
            let start = try XCTUnwrap(text.range(of: entry), entry)
            let body = text[start.upperBound...].prefix(1400)
            XCTAssertTrue(body.contains("try {") && body.contains("catch"), entry)
        }
        XCTAssertTrue(text.contains("return { event: async ({ event }) => feed(event, entry) };"))
    }

    /// The wire a body goes out on is the installed hook's: the socket under
    /// `$HOME`, the loopback `Host:`, the agent's route.
    func testItSpeaksTheInstalledSocketAndRoute() {
        let text = OpenCodePlugin.file.contents
        XCTAssertTrue(text.contains("const SOCKET = \"\(EvlatSocket.relativePath)\";"))
        XCTAssertTrue(text.contains("const ROUTE = \"/hook/opencode\";"))
        XCTAssertTrue(text.contains("const APPROVAL_ROUTE = \"/approval/opencode\";"))
        XCTAssertTrue(text.contains("const BRIDGE_TIMEOUT_MS = 600000;"), "the channel's ten minutes")
        XCTAssertEqual(OpenCodeApprovals.route, OpenCode().approvals?.path)
        XCTAssertEqual(OpenCodeApprovals.timeoutSeconds, OpenCode().approvals?.timeout)
        XCTAssertTrue(text.contains("const HOST = \"127.0.0.1:\(LocalAPI.defaultPort)\";"))
        XCTAssertTrue(text.contains("(process.env.HOME || homedir()) + \"/\" + SOCKET"))
        XCTAssertEqual(OpenCodePlugin.route, OpenCode().hookPath)
    }

    /// The pid header is the agent's own only where the plugin runs in the
    /// agent's process for one terminal: 1.x's `server`, and 2.x `--stdio`.
    func testItSendsThePidOnlyWhereTheProcessIsTheAgents() {
        let text = OpenCodePlugin.file.contents
        XCTAssertTrue(text.contains("line: 1, pid: true"))
        XCTAssertTrue(text.contains("process.argv.includes(\"--stdio\")"))
        XCTAssertTrue(text.contains("if (shared.server || !ctx || !ctx.event"), "1.x calls setup too, with no events")
    }

    // MARK: - Which events are dropped

    func testTheNoiseListNeverCatchesWhatARowIsMovedBy() throws {
        let machine = Machine()
        let needed = ["session.created", "session.deleted", "session.status", "session.idle", "session.error",
                      "permission.asked", "permission.replied", "question.asked", "question.replied",
                      "question.rejected", "form.created", "form.replied", "message.part.updated",
                      "session.execution.started", "session.execution.succeeded", "session.execution.failed",
                      "session.execution.interrupted", "session.tool.input.started", "session.tool.called",
                      "session.tool.success", "session.tool.failed"]
        for type in needed { XCTAssertFalse(machine.isNoise(type), type) }
        let chatty = ["message.part.delta", "session.text.delta", "session.reasoning.delta", "plugin.added",
                      "catalog.updated", "session.updated", "session.diff", "message.updated",
                      "session.step.started", "session.step.failed", "session.text.ended", "session.usage.updated",
                      "session.inbox.enqueued", "session.tool.progress", "shell.created", "location.shutdown",
                      "session.retry.scheduled", "vcs.branch.updated", "models-dev.refreshed"]
        for type in chatty { XCTAssertTrue(machine.isNoise(type), type) }
    }

    func testNoiseAndEventsThatNameNoSessionSayNothing() {
        let machine = Machine()
        XCTAssertTrue(machine.feed(Machine.v1("message.updated", ["sessionID": "s1", "info": ["id": "m1"]])).isEmpty)
        XCTAssertTrue(machine.feed(Machine.v1("file.watcher.updated", ["file": "a", "event": "change"])).isEmpty)
        XCTAssertTrue(machine.feed(Machine.v2("shell.created", ["info": ["id": "sh"]])).isEmpty)
        XCTAssertTrue(machine.feed(["type": "session.status"]).isEmpty, "no id, no properties")
    }

    func testAnUnknownEventThatNamesASessionStaysVisible() throws {
        let machine = Machine()
        let sent = machine.feed(Machine.v1("todo.updated", ["sessionID": "s1", "todos": []]))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].send["event"] as? String, "todo.updated")
        XCTAssertEqual(sent[0].send["session"] as? String, "s1")
    }

    func testAnEventIsToldOnceWhoeverHearsIt() {
        // 2.x boots one plugin instance per folder; every one receives every event.
        let machine = Machine()
        let event = Machine.v2("session.execution.started", ["sessionID": "s1"], id: "evt_same")
        XCTAssertEqual(machine.feed(event).count, 1)
        XCTAssertTrue(machine.feed(event).isEmpty)
    }

    // MARK: - A turn on 1.x

    func testATurnOnTheFirstLine() throws {
        let machine = Machine()
        let directory = "/Users/demo/app"
        let created = machine.feed(Machine.v1("session.created", ["sessionID": "s1", "info": [
            "id": "s1", "directory": directory, "version": "1.19.0"]]))
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].send["event"] as? String, "session.created")
        XCTAssertEqual(created[0].send["directory"] as? String, directory)
        XCTAssertEqual(created[0].send["opencode_version"] as? String, "1.19.0", "learned from the session")
        XCTAssertEqual(created[0].send["line"] as? Int, 1)
        XCTAssertEqual(created[0].send["plugin_version"] as? Int, OpenCodePlugin.version)

        // `busy` repeats all through a turn; only its first says a turn began.
        XCTAssertEqual(machine.feed(Machine.v1("session.status", ["sessionID": "s1", "status": ["type": "busy"]]))
            .map(\.event), ["session.status"])
        XCTAssertTrue(machine.feed(Machine.v1("session.status", ["sessionID": "s1", "status": ["type": "busy"]])).isEmpty)

        // A tool part is `pending` with no input, then `running`; `running` comes again after an answer.
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("pending", input: [:])])).isEmpty)
        let running = machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("running")]))
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].send["status"] as? String, "running")
        XCTAssertEqual(running[0].send["tool"] as? String, "bash")
        XCTAssertEqual((running[0].send["input"] as? [String: Any])?["command"] as? String, "echo hi")
        XCTAssertEqual(running[0].send["directory"] as? String, directory, "the session's folder rides every body")
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("running")])).isEmpty)

        // Text, steps and patches are not tools.
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": ["type": "text", "text": "x"]])).isEmpty)
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": ["type": "step-start"]])).isEmpty)

        XCTAssertEqual(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("completed")])).count, 1)
        // The turn ends with two events at once; one is told, as `session.idle`.
        XCTAssertEqual(machine.feed(Machine.v1("session.status", ["sessionID": "s1", "status": ["type": "idle"]])).map(\.event),
                       ["session.idle"])
        XCTAssertTrue(machine.feed(Machine.v1("session.idle", ["sessionID": "s1"])).isEmpty)
    }

    func testAnAbortEndsTheTurnOnceAndItsTailIsNotANewStep() {
        let machine = Machine()
        machine.begin1("s1")
        _ = machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("running")]))
        let aborted = machine.feed(Machine.v1("session.error", ["sessionID": "s1", "error": ["name": "MessageAbortedError"]]))
        XCTAssertEqual(aborted.count, 1)
        XCTAssertEqual(aborted[0].send["error"] as? String, "MessageAbortedError")
        // Measured: the idle pair, and then the tool's own `error`, come after.
        XCTAssertTrue(machine.feed(Machine.v1("session.status", ["sessionID": "s1", "status": ["type": "idle"]])).isEmpty)
        XCTAssertTrue(machine.feed(Machine.v1("session.idle", ["sessionID": "s1"])).isEmpty)
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("error")])).isEmpty,
                      "a step after the turn ended would put the row back to working")
        // The next turn starts clean.
        XCTAssertEqual(machine.feed(Machine.v1("session.status", ["sessionID": "s1", "status": ["type": "busy"]])).count, 1)
    }

    func testAFailedTurnIsToldOnceAndARetryIsNoEvent() {
        let machine = Machine()
        machine.begin1("s1")
        XCTAssertTrue(machine.feed(Machine.v1("session.status", ["sessionID": "s1", "status": [
            "type": "retry", "attempt": 1, "message": "x", "next": 1]])).isEmpty)
        XCTAssertTrue(machine.feed(Machine.v1("session.status", ["sessionID": "s1", "status": ["type": "busy"]])).isEmpty,
                      "busy after a retry is the same turn")
        let failed = machine.feed(Machine.v1("session.error", ["sessionID": "s1", "error": ["name": "APIError"]]))
        XCTAssertEqual(failed.first?.send["error"] as? String, "APIError")
        XCTAssertTrue(machine.feed(Machine.v1("session.idle", ["sessionID": "s1"])).isEmpty)
        XCTAssertTrue(machine.feed(Machine.v1("session.idle", ["sessionID": "s1"])).isEmpty, "twice, measured")
    }

    // MARK: - Permissions

    func testAPermissionIsHeldBackAndThenTold() throws {
        let machine = Machine()
        machine.begin1("s1")
        let asked = machine.feed(Machine.v1("permission.asked", Machine.permission1(id: "per_1")))
        XCTAssertEqual(asked.count, 1)
        let hold = try XCTUnwrap(asked[0].hold)
        XCTAssertEqual(hold.token, "per_1")
        XCTAssertEqual(hold.ms, OpenCodePlugin.holdMilliseconds)
        XCTAssertNil(asked[0].send["event"], "nothing is told yet")
        let told = machine.fire("per_1")
        XCTAssertEqual(told.count, 1)
        let ask = try XCTUnwrap(told[0].send["ask"] as? [String: Any])
        XCTAssertEqual(ask["id"] as? String, "per_1")
        XCTAssertEqual(ask["kind"] as? String, "bash")
        XCTAssertEqual(ask["command"] as? String, "echo hi")
        XCTAssertTrue(machine.fire("per_1").isEmpty, "a hold runs out once")
    }

    func testAnAnswerInsideTheHoldTellsNeitherOfTheTwo() {
        // `--auto` answers in under 3 ms: no wait to tell.
        let machine = Machine()
        machine.begin1("s1")
        _ = machine.feed(Machine.v1("permission.asked", Machine.permission1(id: "per_1")))
        let replied = machine.feed(Machine.v1("permission.replied", ["sessionID": "s1", "requestID": "per_1", "reply": "once"]))
        XCTAssertTrue(replied.isEmpty)
        XCTAssertTrue(machine.fire("per_1").isEmpty)
    }

    func testAnAnswerAfterTheHoldLiftsTheWait() throws {
        let machine = Machine()
        machine.begin1("s1")
        _ = machine.feed(Machine.v1("permission.asked", Machine.permission1(id: "per_1")))
        _ = machine.fire("per_1")
        let replied = machine.feed(Machine.v1("permission.replied", ["sessionID": "s1", "requestID": "per_1", "reply": "reject"]))
        XCTAssertEqual(replied.count, 1)
        XCTAssertEqual(replied[0].send["event"] as? String, "permission.replied")
        XCTAssertEqual(replied[0].send["reply"] as? String, "reject")
    }

    /// One reply with two tool calls asks twice, a millisecond apart: the
    /// wait lifts when the last one is answered, not the first.
    func testTwoPermissionsLiftTheWaitOnTheLastAnswer() {
        let machine = Machine()
        machine.begin1("s1")
        _ = machine.feed(Machine.v1("permission.asked", Machine.permission1(id: "per_1")))
        _ = machine.feed(Machine.v1("permission.asked", Machine.permission1(id: "per_2")))
        XCTAssertEqual(machine.fire("per_1").count, 1)
        XCTAssertEqual(machine.fire("per_2").count, 1)
        XCTAssertTrue(machine.feed(Machine.v1("permission.replied", ["sessionID": "s1", "requestID": "per_1", "reply": "once"])).isEmpty)
        XCTAssertEqual(machine.feed(Machine.v1("permission.replied", ["sessionID": "s1", "requestID": "per_2", "reply": "once"])).count, 1)
    }

    func testEachLinesPermissionBecomesTheSameAsk() throws {
        let one = Machine()
        one.begin1("s1")
        _ = one.feed(Machine.v1("permission.asked", ["id": "p1", "sessionID": "s1", "permission": "edit", "patterns": ["a.txt"],
                                                     "metadata": ["filepath": "/r/a.txt", "diff": "+x"], "always": ["*"],
                                                     "tool": ["callID": "c"]]))
        let first = try XCTUnwrap(one.fire("p1").first?.send["ask"] as? [String: Any])
        XCTAssertEqual(first["kind"] as? String, "edit")
        XCTAssertEqual(first["file"] as? String, "/r/a.txt")
        XCTAssertNil(first["diff"], "a diff is a file's content: it does not leave")

        let two = Machine()
        _ = two.feed(Machine.v2("session.execution.started", ["sessionID": "s1"]))
        _ = two.feed(Machine.v2("permission.asked", ["id": "p1", "sessionID": "s1", "action": "edit", "resources": ["a.txt"],
                                                     "save": ["*"], "metadata": ["files": [["file": "/r/a.txt", "patch": "+x", "status": "modified"]]],
                                                     "source": ["type": "tool", "id": "c"]]))
        let second = try XCTUnwrap(two.fire("p1").first?.send["ask"] as? [String: Any])
        XCTAssertEqual(second["kind"] as? String, "edit")
        XCTAssertEqual(second["file"] as? String, "/r/a.txt")
        XCTAssertEqual(second["patterns"] as? [String], ["a.txt"])
    }

    func testAQuestionIsToldAtOnceAndAnsweredWithoutAHold() throws {
        let one = Machine()
        one.begin1("s1")
        let asked = one.feed(Machine.v1("question.asked", ["id": "q1", "sessionID": "s1", "questions": Machine.questions,
                                                           "tool": ["callID": "c"]]))
        XCTAssertEqual(asked.count, 1)
        let ask = try XCTUnwrap(asked[0].send["ask"] as? [String: Any])
        XCTAssertEqual(ask["kind"] as? String, "question")
        let questions = try XCTUnwrap(ask["questions"] as? [[String: Any]])
        XCTAssertEqual(questions[0]["question"] as? String, "Which colour?")
        XCTAssertEqual((questions[0]["options"] as? [[String: Any]])?.map { $0["label"] as? String }, ["Red", "Blue"])
        XCTAssertEqual(one.feed(Machine.v1("question.rejected", ["sessionID": "s1", "requestID": "q1"])).first?.send["reply"] as? String, "reject")

        // 2.x asks the same as a form of kind `question`, and its session is inside it.
        let two = Machine()
        let form: [String: Any] = ["form": ["id": "frm_1", "sessionID": "s1", "title": "Questions",
                                            "metadata": ["kind": "question", "tool": ["id": "c"]],
                                            "fields": [["key": "q0", "title": "Colour", "description": "Which colour?", "type": "string",
                                                        "options": [["value": "Red", "label": "Red", "description": "warm"]], "custom": true]]]]
        let formAsk = try XCTUnwrap(two.feed(Machine.v2("form.created", form)).first?.send["ask"] as? [String: Any])
        XCTAssertEqual(formAsk["id"] as? String, "frm_1")
        XCTAssertEqual((formAsk["questions"] as? [[String: Any]])?.first?["question"] as? String, "Which colour?")
        XCTAssertEqual(two.feed(Machine.v2("form.replied", ["sessionID": "s1", "id": "frm_1"])).count, 1)
        // A form that is not a question is a word nothing reads, not a wait.
        let other = Machine().feed(Machine.v2("form.created", ["form": ["id": "frm_2", "sessionID": "s1", "metadata": ["kind": "auth"]]]))
        XCTAssertEqual(other.first?.send["event"] as? String, "form.created")
        XCTAssertNil(other.first?.send["ask"])
    }

    /// While a dialog is up, another step of the turn is not its answer: a
    /// row that read it as one would say `working` over a question the user
    /// still has to answer.
    func testNoStepOfTheTurnLiftsAnOpenDialog() throws {
        let machine = Machine()
        machine.begin1("s1")
        _ = machine.feed(Machine.v1("question.asked", ["id": "q1", "sessionID": "s1", "questions": Machine.questions,
                                                       "tool": ["callID": "call_s1"]]))
        // 1.x says a question before it says its tool is running.
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("running")])).isEmpty)
        // A tool beside it, starting or finishing.
        let other = Machine.tool("running", session: "s1").merging(["callID": "call_other"]) { $1 }
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": other])).isEmpty)
        let finished = other.merging(["state": ["status": "completed", "input": [:]]]) { $1 }
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": finished])).isEmpty)
        // Answered: the wait lifts — and the tool that ended beside the dialog, which
        // OpenCode does not say again, is told after it — and the steps that follow
        // are told again.
        XCTAssertEqual(machine.feed(Machine.v1("question.replied", ["sessionID": "s1", "requestID": "q1"])).map(\.event),
                       ["question.replied", "message.part.updated"])
        XCTAssertEqual(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("running")])).count, 1,
                       "a step held back while the dialog was up is told when it comes again")

        let two = Machine()
        _ = two.feed(Machine.v2("session.execution.started", ["sessionID": "s1"]))
        _ = two.feed(Machine.v2("session.tool.input.started", ["sessionID": "s1", "id": "c1", "name": "shell"]))
        _ = two.feed(Machine.v2("session.tool.called", ["sessionID": "s1", "id": "c1", "input": ["command": "ls"]]))
        _ = two.feed(Machine.v2("permission.asked", ["id": "p1", "sessionID": "s1", "action": "shell", "resources": ["ls"]]))
        _ = two.fire("p1")
        XCTAssertTrue(two.feed(Machine.v2("session.tool.success", ["sessionID": "s1", "id": "c2"])).isEmpty,
                      "another call finishing beside the dialog")
        XCTAssertEqual(two.feed(Machine.v2("permission.replied", ["sessionID": "s1", "requestID": "p1", "reply": "once"])).map(\.event),
                       ["permission.replied", "session.tool.success"], "the other call's end follows the answer")
        XCTAssertEqual(two.feed(Machine.v2("session.tool.success", ["sessionID": "s1", "id": "c1"])).count, 1)
    }

    /// An interrupt never hears its dialog answered; the dialog must not
    /// hold back the next turn's.
    func testADialogNeverAnsweredDoesNotOutliveItsTurn() {
        let machine = Machine()
        machine.begin1("s1")
        _ = machine.feed(Machine.v1("permission.asked", Machine.permission1(id: "per_1")))
        _ = machine.fire("per_1")
        _ = machine.feed(Machine.v1("session.error", ["sessionID": "s1", "error": ["name": "MessageAbortedError"]]))
        machine.begin1("s1")
        _ = machine.feed(Machine.v1("permission.asked", Machine.permission1(id: "per_2")))
        _ = machine.fire("per_2")
        XCTAssertEqual(machine.feed(Machine.v1("permission.replied", ["sessionID": "s1", "requestID": "per_2", "reply": "once"])).count, 1)
    }

    // MARK: - Children and late loads

    func testAChildSessionIsTheRootsRowAndNeverEndsItsTurn() throws {
        let machine = Machine()
        machine.begin1("root")
        XCTAssertTrue(machine.feed(Machine.v1("session.created", ["sessionID": "kid", "info": ["id": "kid", "parentID": "root", "directory": "/d"]])).isEmpty,
                      "a child has no row")
        XCTAssertTrue(machine.feed(Machine.v1("session.status", ["sessionID": "kid", "status": ["type": "busy"]])).isEmpty)
        let tool = machine.feed(Machine.v1("message.part.updated", ["sessionID": "kid", "part": Machine.tool("running", session: "kid")]))
        XCTAssertEqual(tool.first?.send["session"] as? String, "root")
        XCTAssertEqual(tool.first?.send["child"] as? String, "kid")
        _ = machine.feed(Machine.v1("permission.asked", ["id": "p", "sessionID": "kid", "permission": "bash", "patterns": ["ls"]]))
        let ask = machine.fire("p")
        XCTAssertEqual(ask.first?.send["session"] as? String, "root", "the child's wait is on the root's row")
        XCTAssertEqual(ask.first?.send["child"] as? String, "kid")
        // The child's end is not the root's.
        XCTAssertTrue(machine.feed(Machine.v1("session.status", ["sessionID": "kid", "status": ["type": "idle"]])).isEmpty)
        XCTAssertTrue(machine.feed(Machine.v1("session.idle", ["sessionID": "kid"])).isEmpty)
        XCTAssertEqual(machine.feed(Machine.v1("session.idle", ["sessionID": "root"])).count, 1)
        // And the same on 2.x.
        let two = Machine()
        _ = two.feed(Machine.v2("session.execution.started", ["sessionID": "root"]))
        XCTAssertTrue(two.feed(Machine.v2("session.created", ["sessionID": "kid", "parentID": "root"])).isEmpty)
        XCTAssertTrue(two.feed(Machine.v2("session.execution.started", ["sessionID": "kid"])).isEmpty)
        XCTAssertTrue(two.feed(Machine.v2("session.execution.succeeded", ["sessionID": "kid"])).isEmpty)
        XCTAssertEqual(two.feed(Machine.v2("session.execution.succeeded", ["sessionID": "root"])).count, 1)
    }

    func testASessionDeletedLeavesAndItsChildLeavesNothing() {
        let machine = Machine()
        _ = machine.feed(Machine.v1("session.created", ["sessionID": "root", "info": ["id": "root"]]))
        _ = machine.feed(Machine.v1("session.created", ["sessionID": "kid", "info": ["id": "kid", "parentID": "root"]]))
        XCTAssertTrue(machine.feed(Machine.v1("session.deleted", ["sessionID": "kid", "info": ["id": "kid"]])).isEmpty)
        XCTAssertEqual(machine.feed(Machine.v1("session.deleted", ["sessionID": "root", "info": ["id": "root"]])).map(\.event),
                       ["session.deleted"])
    }

    /// The plugin is loaded under a running turn (the desktop app and the 2.x
    /// service load it live): the first thing heard is a step, and the end
    /// of that turn must still be told.
    func testATurnHeardFromTheMiddleStillEnds() {
        let machine = Machine()
        XCTAssertEqual(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("running")])).count, 1)
        XCTAssertEqual(machine.feed(Machine.v1("session.idle", ["sessionID": "s1"])).count, 1)
        // A session of which nothing was heard has no turn to end.
        XCTAssertTrue(Machine().feed(Machine.v1("session.idle", ["sessionID": "never"])).isEmpty)
    }

    // MARK: - 2.x

    func testATurnOnTheSecondLine() throws {
        let machine = Machine()
        let dir = ["directory": "/Users/demo/app"]
        let created = machine.feed(Machine.v2("session.created", ["sessionID": "s1", "location": dir, "version": "2.0.27"],
                                              location: dir), version: "2.0.27")
        XCTAssertEqual(created.first?.send["directory"] as? String, "/Users/demo/app")
        XCTAssertEqual(created.first?.send["opencode_version"] as? String, "2.0.27")
        XCTAssertEqual(created.first?.send["line"] as? Int, 2)
        XCTAssertEqual(machine.feed(Machine.v2("session.execution.started", ["sessionID": "s1"])).count, 1)
        XCTAssertTrue(machine.feed(Machine.v2("session.execution.started", ["sessionID": "s1"])).isEmpty, "a turn starts once")
        // A call's name is said when its input starts and not again.
        XCTAssertTrue(machine.feed(Machine.v2("session.tool.input.started", ["sessionID": "s1", "id": "call_1", "name": "shell"])).isEmpty)
        let called = machine.feed(Machine.v2("session.tool.called", ["sessionID": "s1", "id": "call_1", "input": [
            "command": "ls", "description": "list", "content": "never leaves"]]))
        XCTAssertEqual(called.first?.send["tool"] as? String, "shell")
        XCTAssertEqual(called.first?.send["directory"] as? String, "/Users/demo/app", "the folder is the session's, whichever event said it")
        let input = called.first?.send["input"] as? [String: Any]
        XCTAssertEqual(input?["command"] as? String, "ls")
        XCTAssertNil(input?["content"])
        let done = machine.feed(Machine.v2("session.tool.success", ["sessionID": "s1", "id": "call_1", "content": [["type": "text", "text": "out"]]]))
        XCTAssertEqual(done.first?.send["tool"] as? String, "shell")
        XCTAssertNil(done.first?.send["content"], "a tool's output does not leave")
        XCTAssertEqual(machine.feed(Machine.v2("session.execution.succeeded", ["sessionID": "s1"])).count, 1)
    }

    func testAFailureCarriesItsKind() {
        let machine = Machine()
        _ = machine.feed(Machine.v2("session.execution.started", ["sessionID": "s1"]))
        let failed = machine.feed(Machine.v2("session.execution.failed", ["sessionID": "s1", "error": ["type": "provider.invalid-request", "message": "x"]]))
        XCTAssertEqual(failed.first?.send["error"] as? String, "provider.invalid-request")
        XCTAssertTrue(Machine().feed(Machine.v2("session.retry.scheduled", ["sessionID": "s1", "error": ["type": "provider.internal"], "attempt": 2])).isEmpty)
    }

    // MARK: - The card (the bridge)

    private func asked1(_ machine: Machine, _ id: String, session: String = "s1") {
        var properties = Machine.permission1(id: id)
        properties["sessionID"] = session
        _ = machine.feed(Machine.v1("permission.asked", properties))
    }

    private func replied1(_ machine: Machine, _ id: String, reply: String = "once", session: String = "s1") -> [Machine.Item] {
        machine.feed(Machine.v1("permission.replied", ["sessionID": session, "requestID": id, "reply": reply]))
    }

    /// The card is asked for a permission that stayed: `--auto` answers inside
    /// the hold, and a card for it would flicker. The body is the one the hook
    /// told, so Evlat reads both the same way.
    func testAPermissionGoesToTheCardWhenItsHoldRunsOut() throws {
        let machine = Machine()
        machine.begin1("s1")
        asked1(machine, "per_1")
        XCTAssertTrue(machine.bridged.isEmpty, "nothing is asked of the card yet")
        let told = machine.fire("per_1")
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(machine.bridgedIDs, ["per_1"])
        let bridge = machine.bridged[0]
        XCTAssertEqual(bridge["session"] as? String, "s1", "the session the answer goes to")
        let body = try XCTUnwrap(bridge["body"] as? [String: Any])
        XCTAssertEqual(body["event"] as? String, "permission.asked")
        XCTAssertEqual(body["session"] as? String, "s1")
        XCTAssertEqual((body["ask"] as? [String: Any])?["id"] as? String, "per_1")
        XCTAssertEqual(NSDictionary(dictionary: body), NSDictionary(dictionary: told[0].send), "the hook's own body")
    }

    func testAnAnswerInsideTheHoldOpensNoCard() {
        let machine = Machine()
        machine.begin1("s1")
        asked1(machine, "per_1")
        _ = replied1(machine, "per_1")
        XCTAssertTrue(machine.fire("per_1").isEmpty)
        XCTAssertTrue(machine.bridged.isEmpty)
        XCTAssertTrue(machine.aborted.isEmpty)
    }

    /// A subagent's permission is on its root's card, and is answered to the
    /// session that asked.
    func testASubagentsPermissionIsOnItsRootsCard() throws {
        let machine = Machine()
        machine.begin1("s1")
        _ = machine.feed(Machine.v1("session.created", ["sessionID": "c1", "info": ["id": "c1", "parentID": "s1"]]))
        asked1(machine, "per_c", session: "c1")
        _ = machine.fire("per_c")
        XCTAssertEqual(machine.bridged.first?["session"] as? String, "c1", "answered to the child's own session")
        let body = try XCTUnwrap(machine.bridged.first?["body"] as? [String: Any])
        XCTAssertEqual(body["session"] as? String, "s1", "Evlat's row is the root's")
        XCTAssertEqual(body["child"] as? String, "c1")
    }

    /// One reply with two tool calls asks twice at once. Evlat lets an older
    /// request of a session go when a newer arrives, so the second is not posted
    /// until the first is over — by OpenCode's `replied`, here or in its own
    /// dialog — and the first is closed then.
    func testASecondPermissionOfTheSessionWaitsItsTurn() {
        let machine = Machine()
        machine.begin1("s1")
        asked1(machine, "per_1")
        asked1(machine, "per_2")
        _ = machine.fire("per_1")
        XCTAssertEqual(machine.bridgedIDs, ["per_1"])
        _ = machine.fire("per_2")
        XCTAssertTrue(machine.bridged.isEmpty, "behind the first")

        XCTAssertTrue(replied1(machine, "per_1").isEmpty, "the row still waits on the second")
        XCTAssertEqual(machine.aborted, ["per_1"], "the answered one's card goes")
        XCTAssertEqual(machine.bridgedIDs, ["per_2"], "and the next opens")

        XCTAssertEqual(replied1(machine, "per_2").count, 1)
        XCTAssertEqual(machine.aborted, ["per_2"])
        XCTAssertTrue(machine.bridged.isEmpty)
    }

    func testAnAppliedAnswerOpensTheNextOnce() {
        let machine = Machine()
        machine.begin1("s1")
        asked1(machine, "per_1")
        asked1(machine, "per_2")
        _ = machine.fire("per_1")
        _ = machine.fire("per_2")
        machine.settle("per_1")
        XCTAssertEqual(machine.bridgedIDs, ["per_2"])
        XCTAssertTrue(machine.aborted.isEmpty, "the answered request is over; nothing is held to close")
        machine.settle("per_1")
        XCTAssertTrue(machine.bridged.isEmpty, "applied once")
        // OpenCode then says it answered: nothing of the first is left to let go.
        _ = replied1(machine, "per_1")
        XCTAssertTrue(machine.aborted.isEmpty)
        XCTAssertTrue(machine.bridged.isEmpty)
    }

    func testAnAnswerInOpenCodeBeforeItsTurnDropsTheWaitingCard() {
        let machine = Machine()
        machine.begin1("s1")
        asked1(machine, "per_1")
        asked1(machine, "per_2")
        _ = machine.fire("per_1")
        _ = machine.fire("per_2")
        _ = replied1(machine, "per_2")
        XCTAssertTrue(machine.aborted.isEmpty && machine.bridged.isEmpty, "the first is still on the card")
        _ = replied1(machine, "per_1")
        XCTAssertEqual(machine.aborted, ["per_1"])
        XCTAssertTrue(machine.bridged.isEmpty, "the second never needed one")
    }

    /// A restart with a permission pending says `replied` with a refusal: the
    /// card goes with it, whatever the word.
    func testARefusalFromOpenCodeLetsTheCardGoToo() {
        let machine = Machine()
        machine.begin1("s1")
        asked1(machine, "per_1")
        _ = machine.fire("per_1")
        _ = replied1(machine, "per_1", reply: "reject")
        XCTAssertEqual(machine.aborted, ["per_1"])
    }

    func testEachSessionHasItsOwnCard() {
        let machine = Machine()
        machine.begin1("s1")
        machine.begin1("s2")
        asked1(machine, "per_a")
        asked1(machine, "per_b", session: "s2")
        _ = machine.fire("per_a")
        XCTAssertEqual(machine.bridgedIDs, ["per_a"])
        _ = machine.fire("per_b")
        XCTAssertEqual(machine.bridgedIDs, ["per_b"], "another session is not behind the first")
    }

    /// An interrupt says no `replied`: Evlat lets that card go when it hears the
    /// turn end. What waited behind it is not opened for a turn that is over, and
    /// the next turn's first card is not stuck behind a card that never ended.
    func testAFinishedTurnOpensNoCardAndLeavesNoQueue() {
        let machine = Machine()
        machine.begin1("s1")
        asked1(machine, "per_1")
        asked1(machine, "per_2")
        _ = machine.fire("per_1")
        _ = machine.fire("per_2")
        _ = machine.feed(Machine.v1("session.error", ["sessionID": "s1", "error": ["name": "MessageAbortedError"]]))
        XCTAssertTrue(machine.bridged.isEmpty)
        _ = replied1(machine, "per_1")
        XCTAssertTrue(machine.bridged.isEmpty, "the queue went with the turn")
        XCTAssertTrue(machine.aborted.isEmpty)

        machine.begin1("s1")
        asked1(machine, "per_3")
        _ = machine.fire("per_3")
        XCTAssertEqual(machine.bridgedIDs, ["per_3"], "a new turn starts with a free card")
    }

    /// Only 200 and exactly one of the two words is an answer.
    func testTheCardTakesOnlyAKnownAnswer() {
        let machine = Machine()
        XCTAssertEqual(machine.decision(200, #"{"decision":"once"}"#), "once")
        XCTAssertEqual(machine.decision(200, #"{"decision":"reject"}"#), "reject")
        XCTAssertEqual(machine.decision(200, #"{"decision":"once","extra":1}"#), "once")
        for (status, text) in [(200, "{}"), (200, ""), (200, "not json"), (200, #"{"decision":"always"}"#),
                               (200, #"{"decision":"allow"}"#), (200, #"{"decision":"deny"}"#),
                               (200, #"{"decision":true}"#), (200, #"["once"]"#), (200, "null"),
                               (200, #"{"decision":"once"#), (201, #"{"decision":"once"}"#),
                               (403, #"{"decision":"once"}"#), (404, #"{"decision":"once"}"#),
                               (0, #"{"decision":"once"}"#)] {
            XCTAssertNil(machine.decision(status, text), "\(status) \(text)")
        }
        // What Evlat answers is what the plugin reads.
        let channel = OpenCodeApprovals()
        XCTAssertEqual(machine.decision(200, channel.body(.allow(rules: [], directories: []))), "once")
        XCTAssertEqual(machine.decision(200, channel.body(.deny(interrupt: false))), "reject")
        XCTAssertNil(machine.decision(200, channel.body(.answer(input: Data(), answers: [:]))))
    }

    /// A tool that ended while a dialog of its turn was up says nothing again:
    /// it is told once the wait lifts, not lost (it made the tool count one short).
    func testAToolThatEndedBesideADialogIsToldWhenTheWaitLifts() throws {
        let machine = Machine()
        machine.begin1("s1")
        let first = Machine.tool("running").merging(["callID": "call_first"]) { $1 }
        XCTAssertEqual(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": first])).count, 1)
        asked1(machine, "per_2")
        _ = machine.fire("per_2")
        let done = first.merging(["state": ["status": "completed", "input": [:]]]) { $1 }
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": done])).isEmpty, "held back")
        XCTAssertTrue(machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": done])).isEmpty,
                      "and held back once")
        let lifted = replied1(machine, "per_2")
        XCTAssertEqual(lifted.map(\.event), ["permission.replied", "message.part.updated"])
        XCTAssertEqual(lifted[1].send["status"] as? String, "completed")
        XCTAssertEqual(lifted[1].send["call"] as? String, "call_first")
        XCTAssertEqual(lifted[1].send["tool"] as? String, "bash")
        XCTAssertEqual(replied1(machine, "per_2").map(\.event), ["permission.replied"], "told once")

        // The second line: the tool's name was learnt when it started.
        let two = Machine()
        _ = two.feed(Machine.v2("session.execution.started", ["sessionID": "s1"]))
        _ = two.feed(Machine.v2("session.tool.input.started", ["sessionID": "s1", "id": "c1", "name": "shell"]))
        _ = two.feed(Machine.v2("session.tool.called", ["sessionID": "s1", "id": "c1", "input": ["command": "ls"]]))
        _ = two.feed(Machine.v2("permission.asked", ["id": "p2", "sessionID": "s1", "action": "shell", "resources": ["pwd"]]))
        _ = two.fire("p2")
        XCTAssertTrue(two.feed(Machine.v2("session.tool.success", ["sessionID": "s1", "id": "c1"])).isEmpty)
        let after = two.feed(Machine.v2("permission.replied", ["sessionID": "s1", "requestID": "p2", "reply": "once"]))
        XCTAssertEqual(after.map(\.event), ["permission.replied", "session.tool.success"])
        XCTAssertEqual(after[1].send["tool"] as? String, "shell")
    }

    /// What was held back for a turn that has ended is not told in the next.
    func testWhatWasHeldBackDoesNotOutliveItsTurn() {
        let machine = Machine()
        machine.begin1("s1")
        let first = Machine.tool("running").merging(["callID": "call_first"]) { $1 }
        _ = machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": first]))
        asked1(machine, "per_2")
        _ = machine.fire("per_2")
        let done = first.merging(["state": ["status": "completed", "input": [:]]]) { $1 }
        _ = machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": done]))
        _ = machine.feed(Machine.v1("session.error", ["sessionID": "s1", "error": ["name": "MessageAbortedError"]]))
        machine.begin1("s1")
        asked1(machine, "per_3")
        _ = machine.fire("per_3")
        XCTAssertEqual(replied1(machine, "per_3").map(\.event), ["permission.replied"])
    }

    func testAToolInputKeepsOnlyItsSubject() {
        let machine = Machine()
        machine.begin1("s1")
        let long = String(repeating: "x", count: OpenCodePlugin.textLimit + 500)
        let sent = machine.feed(Machine.v1("message.part.updated", ["sessionID": "s1", "part": Machine.tool("running", input: [
            "filePath": "a.swift", "oldString": "secret old", "newString": "secret new", "command": long])]))
        let input = sent.first?.send["input"] as? [String: Any]
        XCTAssertEqual(Set(input?.keys.map { $0 } ?? []), ["filePath", "command"])
        XCTAssertEqual((input?["command"] as? String)?.count, OpenCodePlugin.textLimit)
    }
}

// MARK: - JavaScriptCore

/// The pure part, alone: a state and `reduce(state, input)`. Events go in as
/// OpenCode sends them to a plugin; what comes out is what the plugin would
/// post, or a hold to be released.
private final class Machine {
    struct Item {
        let send: [String: Any]
        let hold: (token: String, ms: Int)?
        var event: String { send["event"] as? String ?? "" }
    }

    private let context = JSContext()!
    private var counter = 0

    /// What the last call opened on the card and let go of (the bridge),
    /// which is not something the plugin posts as an event.
    private(set) var bridged: [[String: Any]] = []
    private(set) var aborted: [String] = []
    var bridgedIDs: [String] { bridged.compactMap { $0["id"] as? String } }

    init() {
        context.exceptionHandler = { _, exception in XCTFail("JavaScript: \(exception?.toString() ?? "?")") }
        context.evaluateScript(OpenCodePlugin.pure)
        context.evaluateScript("""
            var state = createState();
            function step(json) { return JSON.stringify(reduce(state, JSON.parse(json))); }
            function fire(token) { return JSON.stringify(release(state, token)); }
            function noise(type) { return isNoise(type); }
            function settle(token) { return JSON.stringify(applied(state, token)); }
            function decide(status, text) { return decisionOf(status, text); }
            """)
    }

    func isNoise(_ type: String) -> Bool {
        context.objectForKeyedSubscript("noise")!.call(withArguments: [type])!.toBool()
    }

    @discardableResult
    func feed(_ raw: [String: Any], line: Int? = nil, version: String? = nil) -> [Item] {
        var event = raw
        counter += 1
        if event["id"] == nil, event["type"] != nil { event["id"] = "evt_\(counter)" }
        let isSecond = event["data"] != nil
        var input: [String: Any] = ["raw": event, "line": line ?? (isSecond ? 2 : 1)]
        if let version { input["version"] = version }
        return items(context.objectForKeyedSubscript("step")!.call(withArguments: [json(input)])!.toString())
    }

    func fire(_ token: String) -> [Item] {
        items(context.objectForKeyedSubscript("fire")!.call(withArguments: [token])!.toString())
    }

    /// The card's answer was applied.
    @discardableResult
    func settle(_ token: String) -> [Item] {
        items(context.objectForKeyedSubscript("settle")!.call(withArguments: [token])!.toString())
    }

    func decision(_ status: Int, _ text: String) -> String? {
        let value = context.objectForKeyedSubscript("decide")!.call(withArguments: [status, text])!
        return value.isNull ? nil : value.toString()
    }

    /// A turn already begun on 1.x.
    func begin1(_ session: String) {
        _ = feed(Machine.v1("session.status", ["sessionID": session, "status": ["type": "busy"]]))
    }

    private func items(_ text: String?) -> [Item] {
        guard let data = text?.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        bridged = list.compactMap { $0["bridge"] as? [String: Any] }
        aborted = list.compactMap { $0["abort"] as? String }
        return list.filter { $0["bridge"] == nil && $0["abort"] == nil }.map { item in
            let hold = (item["hold"] as? [String: Any]).flatMap { hold -> (String, Int)? in
                guard let token = hold["token"] as? String, let ms = hold["ms"] as? Int else { return nil }
                return (token, ms)
            }
            return Item(send: item["send"] as? [String: Any] ?? [:], hold: hold.map { (token: $0.0, ms: $0.1) })
        }
    }

    private func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    // MARK: Events as OpenCode sends them

    static func v1(_ type: String, _ properties: [String: Any], id: String? = nil) -> [String: Any] {
        var event: [String: Any] = ["type": type, "properties": properties]
        if let id { event["id"] = id }
        return event
    }

    static func v2(_ type: String, _ data: [String: Any], id: String? = nil, location: [String: Any]? = nil) -> [String: Any] {
        var event: [String: Any] = ["type": type, "data": data, "created": 1]
        if let id { event["id"] = id }
        if let location { event["location"] = location }
        return event
    }

    static func tool(_ status: String, session: String = "s1", input: [String: Any] = ["command": "echo hi", "description": "hi"]) -> [String: Any] {
        ["type": "tool", "tool": "bash", "callID": "call_\(session)", "sessionID": session,
         "state": ["status": status, "input": input]]
    }

    static func permission1(id: String) -> [String: Any] {
        ["id": id, "sessionID": "s1", "permission": "bash", "patterns": ["echo hi"],
         "metadata": ["command": "echo hi"], "always": ["echo *"], "tool": ["callID": "call_s1"]]
    }

    static let questions: [[String: Any]] = [["question": "Which colour?", "header": "Colour",
                                              "options": [["label": "Red", "description": "warm"], ["label": "Blue", "description": "cool"]]]]
}
