import XCTest
@testable import EvlatCore

/// The stream-json reader. Lines are shaped like the ones a real
/// `claude -p --output-format stream-json --verbose --include-partial-messages`
/// printed (Claude Code 2.1.281, `011/phase-1`), cut to the fields read.
final class ChatStreamTests: XCTestCase {
    private func events(_ lines: [String]) -> ([ChatStream.Event], ChatStream) {
        var stream = ChatStream()
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        return (stream.feed(data), stream)
    }

    func testInitGivesTheSessionID() {
        let (events, _) = events([#"{"type":"system","subtype":"init","cwd":"/tmp/a","session_id":"S1","tools":["Bash"]}"#])
        XCTAssertEqual(events, [.started(sessionID: "S1")])
    }

    func testATextDeltaIsReadFromThePartialMessage() {
        let (events, _) = events([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}},"session_id":"S1"}"#,
        ])
        XCTAssertEqual(events, [.textDelta("ok")])
    }

    /// The partial-message machinery (`message_start`, a tool's
    /// `input_json_delta`, …) is known and says nothing a chat shows; it is
    /// neither an event nor unrecognised.
    func testOtherPartialMessagesAreKnownAndQuiet() {
        let (events, stream) = events([
            #"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{"}}}"#,
            #"{"type":"system","subtype":"status","status":"requesting","session_id":"S1"}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
            #"{"type":"system","subtype":"thinking_tokens","session_id":"S1"}"#,
        ])
        XCTAssertEqual(events, [])
        XCTAssertEqual(stream.unrecognized, [:])
    }

    func testAnAssistantMessageCarriesTextAndOneLineTools() {
        let (events, _) = events([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la\nrm -rf /","description":"List"}}]}}"#,
        ])
        XCTAssertEqual(events, [.assistant(text: "Looking.",
                                           tools: [.init(id: "t1", name: "Bash", subject: "ls -la")])])
    }

    func testAToolResultSaysWhetherItFailed() {
        let (events, _) = events([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"x","is_error":true}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t2","type":"tool_result","content":"y"}]}}"#,
        ])
        XCTAssertEqual(events, [.toolResult(id: "t1", isError: true, output: "x"),
                                .toolResult(id: "t2", isError: false, output: "y")])
    }

    func testTheResult() {
        let (events, _) = events([
            #"{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"S1","num_turns":1}"#,
            #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"S1"}"#,
        ])
        XCTAssertEqual(events, [
            .result(.init(subtype: "success", isError: false, text: "ok")),
            .result(.init(subtype: "error_during_execution", isError: true, text: nil)),
        ])
    }

    func testAPermissionDenial() {
        let (events, _) = events([#"{"type":"system","subtype":"permission_denied","tool_name":"Write"}"#])
        XCTAssertEqual(events, [.permissionDenied(.init(tool: "Write"))])
    }

    /// The frame as 2.1.281 wrote it for a deny rule on a compound command
    /// (`011/phase-3` ek, measured).
    func testAMeasuredDenialKeepsItsCallAndReason() {
        let (events, _) = events([#"{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"toolu_01J","decision_reason_type":"subcommandResults","message":"Permission to use Bash with command touch x.txt && ls -l x.txt has been denied.","uuid":"u","session_id":"S"}"#])
        XCTAssertEqual(events, [.permissionDenied(.init(
            tool: "Bash", toolUseID: "toolu_01J", reason: "subcommandResults",
            message: "Permission to use Bash with command touch x.txt && ls -l x.txt has been denied."))])
    }

    /// An unknown word is counted, not swallowed (`rawStatus`'s spirit).
    func testAnUnknownTypeIsCounted() {
        let (events, stream) = events([
            #"{"type":"brand_new","x":1}"#,
            #"{"type":"system","subtype":"brand_new"}"#,
            #"not json"#,
            #"{"type":"brand_new"}"#,
        ])
        XCTAssertEqual(events, [])
        XCTAssertEqual(stream.unrecognized, ["brand_new": 2, "system/brand_new": 1, ChatStream.unparsable: 1])
    }

    /// A line split across reads, fed as a slice that does not start at
    /// zero: the listener's buffer is exactly such a slice, and `Data`'s
    /// indices stay absolute in it (`proje.md` → Tuzaklar).
    func testALineSplitAcrossChunksFromANonZeroSlice() {
        let line = #"{"type":"system","subtype":"init","session_id":"S1"}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"# + "\n"
        let bytes = Data(("xxxx" + line).utf8)
        let whole = bytes[4...]
        XCTAssertNotEqual(whole.startIndex, 0)
        var stream = ChatStream()
        let cut = whole.startIndex + 20
        var events = stream.feed(whole[whole.startIndex..<cut])
        XCTAssertEqual(events, [])
        events += stream.feed(whole[cut...])
        XCTAssertEqual(events, [.started(sessionID: "S1"), .textDelta("hi")])
    }

    func testAFinalLineWithoutANewlineIsReadAtTheEnd() {
        var stream = ChatStream()
        XCTAssertEqual(stream.feed(Data(#"{"type":"result","subtype":"success","is_error":false}"#.utf8)), [])
        XCTAssertEqual(stream.finish(), [.result(.init(subtype: "success", isError: false, text: nil))])
        XCTAssertEqual(stream.finish(), [])
    }
}
