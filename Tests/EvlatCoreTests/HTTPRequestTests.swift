import XCTest
@testable import EvlatCore

/// Parsing of the bytes a hook's `curl` puts on the wire. **Socketless**: the
/// request is a `Data` literal, which is how v1 tested the same code even
/// though it sat in a file importing `Network`.
final class HTTPRequestTests: XCTestCase {
    private func raw(_ text: String) -> Data { Data(text.utf8) }

    func testReadsTheRequestLineAndTheHeadersItCaresAbout() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(raw("""
            POST /hook HTTP/1.1\r
            Host: 127.0.0.1:48151\r
            Content-Type: application/json\r
            X-Evlat-Task: build-42\r
            X-Evlat-Pid: 7747\r
            Content-Length: 13\r
            \r
            {"a":"bcdef"}
            """)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/hook")
        XCTAssertEqual(request.body, raw("{\"a\":\"bcdef\"}"))
        XCTAssertEqual(request.taskID, "build-42")
        XCTAssertEqual(request.pid, "7747")
        XCTAssertEqual(request.host, "127.0.0.1:48151")
        XCTAssertNil(request.origin)
    }

    /// A chat turn's permission hook sends its token in its own header; the
    /// name is `ChatRequest.tokenHeader`, the one the inline settings write.
    func testReadsThePermissionToken() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(raw(
            "POST /permission HTTP/1.1\r\nHost: 127.0.0.1\r\n\(ChatRequest.tokenHeader): T-1\r\n\r\n")))
        XCTAssertEqual(request.permissionToken, "T-1")
        XCTAssertNil(try XCTUnwrap(HTTPRequest.parse(raw("POST /hook HTTP/1.1\r\nx-evlat-permission:\r\n\r\n")))
            .permissionToken, "empty counts as absent")
        XCTAssertNil(try XCTUnwrap(HTTPRequest.parse(raw("POST /hook HTTP/1.1\r\n\r\n"))).permissionToken)
    }

    /// An outside program's key, in the `X-Evlat-*` family; empty
    /// counts as absent, so it can never match an empty listener key.
    func testReadsTheSignalKey() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(raw(
            "POST /signal HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Evlat-Key: abc123\r\n\r\n")))
        XCTAssertEqual(request.signalKey, "abc123")
        XCTAssertEqual(SignalReport.keyHeader, "X-Evlat-Key")
        XCTAssertNil(try XCTUnwrap(HTTPRequest.parse(raw("POST /signal HTTP/1.1\r\nx-evlat-key: \r\n\r\n")))
            .signalKey, "empty counts as absent")
        XCTAssertNil(try XCTUnwrap(HTTPRequest.parse(raw("POST /signal HTTP/1.1\r\n\r\n"))).signalKey)
    }

    /// A broken length leaves the request body-less. A **negative** one used to
    /// reverse the body slice and bring the process down: every local process
    /// could kill Evlat by sending one header.
    func testBrokenContentLengthIsNotFatal() throws {
        for length in ["-1", "abc", "-99999", ""] {
            let request = HTTPRequest.parse(raw("POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(length)\r\n\r\n"))
            XCTAssertEqual(try XCTUnwrap(request, length).body, Data(), length)
        }
        // Announced but not arrived: not broken, just incomplete. The caller
        // keeps reading instead of answering half a body.
        XCTAssertNil(HTTPRequest.parse(raw("POST /hook HTTP/1.1\r\nContent-Length: 99999\r\n\r\n")))
    }

    /// A valueless header line is not dropped: an empty `Origin:` is still a
    /// browser's mark, and splitting the line on `:` while omitting empty
    /// pieces silently lost it.
    func testValuelessHeaderIsKept() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(raw("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin:\r\n\r\n")))
        XCTAssertEqual(request.origin, "", "the line is there, the value is empty")
        XCTAssertNotNil(request.origin)
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(raw("""
            POST /hook HTTP/1.1\r
            HOST: 127.0.0.1:48151\r
            oRiGiN: https://example.com\r
            x-evlat-pid: 7747\r
            \r

            """)))
        XCTAssertEqual(request.host, "127.0.0.1:48151")
        XCTAssertEqual(request.origin, "https://example.com")
        XCTAssertEqual(request.pid, "7747")
    }

    /// An empty `X-Evlat-*` value counts as absent. The installed command sends
    /// `X-Evlat-Task: ${EVLAT_TASK:-}`, which is empty in the user's own
    /// sessions — the server has to read that as "no task", not as a task named
    /// "".
    func testEmptyEvlatHeadersCountAsAbsent() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(raw("POST /hook HTTP/1.1\r\nX-Evlat-Task:\r\nX-Evlat-Pid: \r\n\r\n")))
        XCTAssertNil(request.taskID)
        XCTAssertNil(request.pid)
    }

    /// Nothing can be decided before the blank line arrives.
    func testHeaderNotYetCompleteIsNotARequest() {
        XCTAssertNil(HTTPRequest.parse(raw("POST /hook HTTP/1.1\r\nHost: 127.0")))
        XCTAssertNil(HTTPRequest.parse(Data()))
        XCTAssertNil(HTTPRequest.parse(raw("GET\r\n\r\n")), "a request line needs a target")
    }

    /// The listener hands over its accumulating buffer, and a buffer that has
    /// already had one request taken out of it **does not start at zero**.
    /// `Data`'s indices are absolute, so mixing them with a literal `0` traps
    /// and mixing them with `count` makes a complete request look forever
    /// incomplete. Both were real: the first crashed the process.
    func testARequestThatStartsPartWayIntoTheBufferIsRead() throws {
        let first = raw("GET /health HTTP/1.1\r\n\r\n")
        let second = raw("POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}")
        let rest = (first + second).dropFirst(first.count)
        XCTAssertNotEqual(rest.startIndex, 0, "the fixture only bites while the slice is offset")

        let request = try XCTUnwrap(HTTPRequest.parse(rest))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/hook")
        XCTAssertEqual(request.body, raw("{}"))
        // The body is a slice too, and it is what gets decoded as JSON.
        let agent = TestAgent(paths: [RouteTable.installedPrefix])
        XCTAssertEqual(LocalAPI.handle(request, listener: LocalAPI.Listener(routes: RouteTable([agent])),
                                       agents: [agent]).response?.body, "{}")
        // The same slice one byte short is still "not yet", not "never".
        XCTAssertNil(HTTPRequest.parse(rest.dropLast()))
    }

    /// A byte that is not UTF-8 must not stall the connection. `nil` means
    /// "keep reading", and no byte arriving later could ever make an
    /// undecodable header decode — so the listener would hold the connection
    /// and grow its buffer until the client timed out. Header bytes are read as
    /// Latin-1, which cannot fail.
    func testAnUndecodableHeaderByteDoesNotStallTheRequest() throws {
        var bytes = raw("POST /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Evlat-Task: ")
        bytes.append(0x80)
        bytes.append(contentsOf: raw("\r\n\r\n"))
        let request = try XCTUnwrap(HTTPRequest.parse(bytes))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.host, "127.0.0.1")
    }

    /// The body is exactly `Content-Length` bytes: anything after it belongs to
    /// the next request, not to this one.
    func testBodyIsSlicedToTheAnnouncedLength() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(raw("POST /hook HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}GET /health HTTP/1.1\r\n\r\n")))
        XCTAssertEqual(request.body, raw("{}"))
    }

    /// A sandbox's two headers (`SandboxKit`), read as text like the pid:
    /// what they may say is `HookEvent`'s rule, and whether they count is
    /// the listener's. Empty counts as absent.
    func testReadsTheSandboxHeaders() throws {
        let request = try XCTUnwrap(HTTPRequest.parse(raw(
            "POST /hook HTTP/1.1\r\nX-Evlat-Sandbox: claude-evlat\r\nx-evlat-kit: 1\r\n\r\n")))
        XCTAssertEqual(request.sandboxName, "claude-evlat")
        XCTAssertEqual(request.kitVersion, "1")
        let empty = try XCTUnwrap(HTTPRequest.parse(raw(
            "POST /hook HTTP/1.1\r\nX-Evlat-Sandbox: \r\nX-Evlat-Kit:\r\n\r\n")))
        XCTAssertNil(empty.sandboxName, "empty counts as absent")
        XCTAssertNil(empty.kitVersion)
    }
}
