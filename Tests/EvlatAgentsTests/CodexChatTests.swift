import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// Codex as the chat's backend: `codex app-server` per turn, driven over its
/// stdio in the shapes measured on 0.156.1. The reader is fed what the
/// server says and checked for what it writes back.
final class CodexChatTests: XCTestCase {
    private let chat = CodexChat()

    private func spec(resume: Bool = false, session: String = "evlat-picked", attachments: [String] = [],
                      mode: CodexMode = .workspace) -> TurnSpec {
        TurnSpec(chatID: "C1", sessionID: session, resume: resume, prompt: "say ok", attachments: attachments,
                 directory: "/tmp/project", mode: mode.chatMode)
    }

    private func line(_ text: String) -> Data { Data((text + "\n").utf8) }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private let initialized = #"{"id":1,"result":{"userAgent":"evlat/0.156.1 (Mac OS 26.4.1; arm64) bateri/0.1.0","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
    private let threadStarted = #"{"id":2,"result":{"thread":{"id":"thr-1"},"approvalPolicy":"on-request"}}"#

    /// Ready to stream: the handshake and the thread are done.
    private func running(_ spec: TurnSpec? = nil) -> AppServerStream {
        var stream = AppServerStream(spec: spec ?? self.spec())
        _ = stream.feed(line(initialized))
        _ = stream.feed(line(threadStarted))
        _ = stream.feed(line(#"{"method":"turn/started","params":{"threadId":"thr-1","turn":{"id":"turn-1"}}}"#))
        return stream
    }

    // MARK: - Values

    func testItsValues() {
        XCTAssertEqual(chat.id, .codex)
        XCTAssertEqual(chat.executableVariable, "EVLAT_CODEX")
        XCTAssertEqual(chat.modeKey, "chat.codex.mode")
        XCTAssertEqual(chat.indexFile, "chats-codex.json")
        XCTAssertEqual(chat.caps, ChatCapabilities(asks: true, alwaysOption: .thisCommand, resume: true,
                                                   memory: false, transport: .duplex))
        XCTAssertEqual(chat.stopPlan, .inBand)
        XCTAssertEqual(chat.measuredVersion, "0.156.1")
        XCTAssertEqual(chat.noteKey, "settings.chat.backend.codex.note")
        XCTAssertNotEqual(Agents.routes.permission, .codex,
                          "a duplex backend asks on its own channel, not through /permission")
    }

    /// Read only and the folder ask; full access asks first and is never a
    /// default. Each is an approval policy and a sandbox.
    func testTheModes() {
        XCTAssertEqual(chat.modes.map(\.id), ["readOnly", "workspace", "fullAccess"])
        XCTAssertEqual(chat.offered.map(\.id), ["workspace", "readOnly"])
        XCTAssertEqual(chat.standardMode.id, "workspace")
        XCTAssertEqual(chat.modes.filter(\.asksBeforePicking).map(\.id), ["fullAccess"])
        XCTAssertEqual(chat.modes.filter { !$0.mayBeDefault }.map(\.id), ["fullAccess"])
        XCTAssertEqual(chat.modes.map(\.retryDenialAs), [nil, nil, nil])
        XCTAssertEqual(CodexMode.allCases.map(\.approvalPolicy), ["on-request", "on-request", "never"])
        XCTAssertEqual(CodexMode.allCases.map(\.sandbox), ["read-only", "workspace-write", "danger-full-access"])
    }

    /// The launch is the server alone, its first line `initialize`; the
    /// task variable reaches the user's hooks, which the server runs.
    func testTheLaunch() {
        let launch = chat.turn(spec(), ctx: TurnContext(socket: "", token: "T"))
        XCTAssertEqual(launch.arguments, ["app-server"])
        XCTAssertEqual(launch.environment, [TurnLaunch.taskVariable: "C1"])
        XCTAssertEqual(launch.directory, "/tmp/project")
        XCTAssertEqual(launch.input.count, 1)
        let first = json(launch.input[0])
        XCTAssertEqual(first["method"] as? String, "initialize")
        XCTAssertEqual(first["id"] as? Int, 1)
        XCTAssertEqual(launch.input[0].last, 0x0A)
    }

    // MARK: - The handshake

    /// `initialize` answered: its version is read, `initialized` and the
    /// thread go out with the chat's folder and mode.
    func testANewChatStartsAThread() {
        var stream = AppServerStream(spec: spec(mode: .readOnly))
        let (events, replies) = stream.feed(line(initialized))
        XCTAssertEqual(events, [])
        XCTAssertEqual(stream.version, "0.156.1")
        XCTAssertEqual(replies.map { json($0)["method"] as? String }, ["initialized", "thread/start"])
        let params = json(replies[1])["params"] as? [String: Any]
        XCTAssertEqual(params?["cwd"] as? String, "/tmp/project")
        XCTAssertEqual(params?["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(params?["sandbox"] as? String, "read-only")
        XCTAssertNil(params?["threadId"])

        let (started, turn) = stream.feed(line(threadStarted))
        XCTAssertEqual(started, [.started(sessionID: "thr-1")], "the thread's id is the chat's session")
        XCTAssertEqual(json(turn[0])["method"] as? String, "turn/start")
        let input = (json(turn[0])["params"] as? [String: Any])?["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["text"] as? String, "say ok")
        XCTAssertEqual((json(turn[0])["params"] as? [String: Any])?["threadId"] as? String, "thr-1")
    }

    /// A later turn resumes the thread by its id, in the chat's mode now.
    func testALaterTurnResumesTheThread() {
        var stream = AppServerStream(spec: spec(resume: true, session: "thr-1", attachments: ["/tmp/a.pdf"],
                                                mode: .fullAccess))
        let replies = stream.feed(line(initialized)).replies
        XCTAssertEqual(json(replies[1])["method"] as? String, "thread/resume")
        let params = json(replies[1])["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thr-1")
        XCTAssertEqual(params?["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params?["sandbox"] as? String, "danger-full-access")
        let turn = stream.feed(line(threadStarted)).replies
        let input = (json(turn[0])["params"] as? [String: Any])?["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["text"] as? String, "say ok\n\n/tmp/a.pdf", "files are named under the prompt")
    }

    /// The version is between the first `/` and the first space.
    func testTheVersionIsReadFromTheUserAgent() {
        XCTAssertEqual(AppServerStream.version(fromUserAgent: "evlat/0.156.1 (Mac OS 26.4.1; arm64) x/1"), "0.156.1")
        XCTAssertEqual(AppServerStream.version(fromUserAgent: "evlat/0.158.0"), "0.158.0")
        XCTAssertNil(AppServerStream.version(fromUserAgent: "evlat"))
        XCTAssertNil(AppServerStream.version(fromUserAgent: nil))
    }

    /// A refused thread or turn is the turn's end, as an error.
    func testAnErrorAnswerEndsTheTurn() {
        var stream = AppServerStream(spec: spec(resume: true, session: "gone"))
        _ = stream.feed(line(initialized))
        let events = stream.feed(line(#"{"id":2,"error":{"code":-32600,"message":"no rollout found"}}"#)).events
        XCTAssertEqual(events, [.result(.init(subtype: "error", isError: true, text: "no rollout found"))])
    }

    // MARK: - The stream

    /// Deltas stream the reply, the finished message replaces it, a command
    /// is a tool line with its outcome, `turn/completed` is the result.
    /// What says nothing a chat shows is quiet; an unknown word is counted.
    func testTheStream() {
        var stream = running()
        let feed = [
            #"{"method":"mcpServer/startupStatus/updated","params":{"name":"x","status":"starting"}}"#,
            #"{"method":"item/started","params":{"item":{"type":"reasoning","id":"rs-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"o","itemId":"m"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"k","itemId":"m"}}"#,
            #"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-1","command":"/bin/zsh -lc 'ls'","commandActions":[{"type":"listFiles","command":"ls"}],"status":"inProgress"}}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-1","status":"completed","exitCode":0,"aggregatedOutput":"\na b\nc\n"}}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m","text":"ok"}}}"#,
            #"{"method":"account/rateLimits/updated","params":{}}"#,
            #"{"method":"thread/brandNew","params":{}}"#,
            #"{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}"#,
        ].joined(separator: "\n") + "\n"
        let (events, replies) = stream.feed(Data(feed.utf8))
        XCTAssertEqual(replies, [])
        XCTAssertEqual(events, [
            .textDelta("o"), .textDelta("k"),
            .assistant(text: nil, tools: [.init(id: "exec-1", name: "Bash", subject: "ls")]),
            .toolResult(id: "exec-1", isError: false, output: "a b"),
            .assistant(text: "ok", tools: []),
            .result(.init(subtype: "success", isError: false, text: "ok")),
        ])
        XCTAssertEqual(stream.unrecognized, ["thread/brandNew": 1])
    }

    /// A declined or failed command is a failed tool line; an interrupted
    /// turn and a failed one are not successes.
    func testHowATurnEnds() {
        var stream = running()
        XCTAssertEqual(stream.feed(line(#"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"e","status":"declined"}}}"#)).events,
                       [.toolResult(id: "e", isError: true, output: nil)])
        XCTAssertEqual(stream.feed(line(#"{"method":"turn/completed","params":{"turn":{"status":"interrupted"}}}"#)).events,
                       [.result(.init(subtype: "interrupted", isError: true, text: nil))])
        XCTAssertEqual(stream.feed(line(#"{"method":"turn/completed","params":{"turn":{"status":"failed","error":{"message":"boom"}}}}"#)).events,
                       [.result(.init(subtype: "failed", isError: true, text: "boom"))])
    }

    /// Every tool line that starts also ends: a web search too.
    func testAWebSearchLineEnds() {
        var stream = running()
        XCTAssertEqual(stream.feed(line(#"{"method":"item/started","params":{"item":{"type":"webSearch","id":"ws","query":"swift"}}}"#)).events,
                       [.assistant(text: nil, tools: [.init(id: "ws", name: "WebSearch", subject: "swift")])])
        XCTAssertEqual(stream.feed(line(#"{"method":"item/completed","params":{"item":{"type":"webSearch","id":"ws","query":"swift"}}}"#)).events,
                       [.toolResult(id: "ws", isError: false, output: nil)])
        XCTAssertEqual(AppServerStream.firstLine(of: "\n  \n first \nsecond"), "first")
    }

    /// A slice of a larger buffer, split mid-line, reads the same.
    func testAChunkSplitMidLine() {
        var stream = running()
        let text = Data(#"xx{"method":"item/agentMessage/delta","params":{"delta":"hi"}}"#.utf8 + [0x0A])
        let slice = text[2...]
        let cut = slice.startIndex + 10
        XCTAssertEqual(stream.feed(slice[slice.startIndex..<cut]).events, [])
        XCTAssertEqual(stream.feed(slice[cut...]).events, [.textDelta("hi")])
    }

    // MARK: - Asking

    /// A command's approval is a card on the turn's own channel: its whole
    /// command, the parsed line as its subject, the server's reason and its
    /// call id; every answer is a line back with that id.
    func testACommandsApprovalIsACardAnsweredOnStdin() throws {
        var stream = running()
        let ask = #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","itemId":"exec-1","reason":"May I write a.txt?","command":"/bin/zsh -lc 'echo one > a.txt'","commandActions":[{"type":"unknown","command":"echo one > a.txt"}]}}"#
        let (events, replies) = stream.feed(line(ask))
        XCTAssertEqual(replies, [], "nothing is answered before the user")
        guard case .asked(let request)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(request.tool, "Bash")
        XCTAssertEqual(request.subject, "echo one > a.txt")
        XCTAssertEqual(request.command, "/bin/zsh -lc 'echo one > a.txt'")
        XCTAssertEqual(request.reason, "May I write a.txt?")
        XCTAssertEqual(request.callID, "0")
        XCTAssertEqual(request.replyTarget, .runner)
        XCTAssertNil(request.token)

        let answers: [(ChatDecision, String)] = [
            (.allow(rules: [], directories: []), "accept"), (.allowForSession, "acceptForSession"),
            (.deny(interrupt: false), "decline"), (.deny(interrupt: true), "cancel"),
        ]
        for (decision, word) in answers {
            guard case .line(let data) = chat.encode(decision, for: request) else { return XCTFail() }
            XCTAssertEqual(String(decoding: data, as: UTF8.self),
                           #"{"id":0,"jsonrpc":"2.0","result":{"decision":""# + word + "\"}}\n")
        }
    }

    /// Two turns both ask with id 0: the cards are told apart by Evlat's own
    /// id, never the server's.
    func testEveryCardHasItsOwnID() {
        var one = running(), two = running()
        let ask = line(#"{"method":"item/commandExecution/requestApproval","id":0,"params":{"command":"ls"}}"#)
        guard case .asked(let a)? = one.feed(ask).events.first,
              case .asked(let b)? = two.feed(ask).events.first else { return XCTFail() }
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.callID, b.callID)
    }

    /// A file change's approval names only its item: the paths come from
    /// the item that started before it. Its "always" is not a command's.
    func testAFileChangesApprovalNamesItsFiles() {
        var stream = running()
        _ = stream.feed(line(#"{"method":"item/started","params":{"item":{"type":"fileChange","id":"fc-1","changes":[{"path":"/tmp/project/a.txt"},{"path":"/tmp/project/b.txt"}],"status":"inProgress"}}}"#))
        let events = stream.feed(line(#"{"method":"item/fileChange/requestApproval","id":"x-2","params":{"itemId":"fc-1","reason":"Write two files"}}"#)).events
        guard case .asked(let request)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(request.tool, "Edit")
        XCTAssertEqual(request.subject, "/tmp/project/a.txt, /tmp/project/b.txt")
        XCTAssertNil(request.command)
        XCTAssertEqual(request.callID, #""x-2""#)
        guard case .line(let data) = chat.encode(.deny(interrupt: false), for: request) else { return XCTFail() }
        XCTAssertEqual(json(data)["id"] as? String, "x-2", "a string id goes back a string")
    }

    /// A request the bubble cannot answer is refused at once — left
    /// unanswered the turn would wait for ever — and said in the chat.
    func testAnUnknownRequestIsRefusedAndTheTurnGoesOn() {
        var stream = running()
        let (events, replies) = stream.feed(line(#"{"method":"item/tool/requestUserInput","id":"q-7","params":{"questions":[]}}"#))
        XCTAssertEqual(events, [.unsupported("item/tool/requestUserInput")])
        XCTAssertEqual(replies.count, 1)
        let reply = json(replies[0])
        XCTAssertEqual(reply["id"] as? String, "q-7")
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, AppServerStream.methodNotFound)
        XCTAssertNil(reply["result"])
        XCTAssertEqual(stream.unrecognized, ["request/item/tool/requestUserInput": 1])
    }

    // MARK: - Stop

    /// Stop names the thread and the turn: before the turn started there is
    /// nothing to name.
    func testStopIsTurnInterruptOnceTheTurnIsKnown() {
        var stream = AppServerStream(spec: spec())
        XCTAssertNil(stream.stopLine())
        _ = stream.feed(line(initialized))
        _ = stream.feed(line(threadStarted))
        XCTAssertNil(stream.stopLine(), "the thread alone is not enough")
        _ = stream.feed(line(#"{"id":3,"result":{"turn":{"id":"turn-9","status":"inProgress"}}}"#))
        let stop = json(stream.stopLine() ?? Data())
        XCTAssertEqual(stop["method"] as? String, "turn/interrupt")
        XCTAssertEqual(stop["params"] as? [String: String], ["threadId": "thr-1", "turnId": "turn-9"])
    }
}
