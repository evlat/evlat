import XCTest
@testable import EvlatCore

/// The `sbx` daemon's `/events` stream, read without a socket: the head,
/// the chunks, one event per line, and the wait before reconnecting.
final class SandboxDaemonTests: XCTestCase {
    private static let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n"
        + "Date: Sat, 03 Oct 2026 11:20:00 GMT\r\nTransfer-Encoding: chunked\r\n\r\n"

    private static func line(_ type: String, _ action: String, _ name: String = "evlat-p4") -> String {
        #"{"action":"\#(action)","created_at":"2026-10-03T11:20:00Z","data":{},"id":"e1","#
            + #""sandbox_id":"id-\#(name)","sandbox_name":"\#(name)","timestamp":"2026-10-03T14:28:18.979235+03:00","type":"\#(type)"}"#
            + "\n"
    }

    private static func chunk(_ text: String) -> String {
        String(text.utf8.count, radix: 16) + "\r\n" + text + "\r\n"
    }

    func testTheRequestAsksForTheEvents() {
        let text = String(decoding: SandboxDaemon.request, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /events HTTP/1.1\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    /// Several lines in one chunk, the other types passed over.
    func testLifecycleEventsAreReadAndOtherTypesSkipped() {
        var stream = SandboxDaemon.Stream()
        let body = Self.line("sync", "complete", "")
            + Self.line("sandbox.lifecycle", "created")
            + Self.line("policy.network", "allowed")
            + Self.line("sandbox.lifecycle", "started")
            + Self.line("sandbox.ports", "published")
        let events = stream.feed(Data((Self.head + Self.chunk(body)).utf8))
        XCTAssertEqual(events, [
            SandboxEvent(name: "evlat-p4", id: "id-evlat-p4", action: .created),
            SandboxEvent(name: "evlat-p4", id: "id-evlat-p4", action: .started),
        ])
        XCTAssertEqual(stream.malformedLines, 0)
        XCTAssertEqual(stream.unknownActions, 0)
        XCTAssertNil(stream.failure)
    }

    /// The bytes cut anywhere — in the head, in a chunk's size, in a line,
    /// in a chunk's closing CRLF — and every piece a `Data` slice that does
    /// not start at zero (`AGENTS.md` → Pitfalls): the same events.
    func testTheStreamCutAnywhereGivesTheSameEvents() {
        let body1 = Self.line("sandbox.lifecycle", "stopped", "a") + Self.line("policy.network", "allowed")
        let body2 = Self.line("sandbox.lifecycle", "deleted", "b")
        let whole = Data((Self.head + Self.chunk(body1) + Self.chunk(body2) + "0\r\n\r\n").utf8)
        let expected = [SandboxEvent(name: "a", id: "id-a", action: .stopped),
                        SandboxEvent(name: "b", id: "id-b", action: .deleted)]
        for size in [1, 2, 3, 7, 64, whole.count] {
            var stream = SandboxDaemon.Stream()
            var events: [SandboxEvent] = []
            var offset = 0
            // A parent with bytes in front, so each piece is a slice whose
            // `startIndex` is not zero.
            let parent = Data("xyz".utf8) + whole
            while offset < whole.count {
                let end = min(offset + size, whole.count)
                let piece = parent[(3 + offset)..<(3 + end)]
                events += stream.feed(piece)
                offset = end
            }
            XCTAssertEqual(events, expected, "pieces of \(size)")
            XCTAssertTrue(stream.ended, "pieces of \(size)")
            XCTAssertNil(stream.failure, "pieces of \(size)")
        }
    }

    /// A word this version does not know is kept and counted; a line that
    /// says `sandbox.lifecycle` but is no event is counted and dropped.
    func testUnknownActionsAndBrokenLinesAreCounted() {
        var stream = SandboxDaemon.Stream()
        let body = Self.line("sandbox.lifecycle", "paused")
            + #"{"type":"sandbox.lifecycle","action":"star"# + "\n"
            + #"{"type":"sandbox.lifecycle","action":"started"}"# + "\n"
            + #"{"type":"policy.network","data":{"note":"sandbox.lifecycle"}}"# + "\n"
            + "\n"
            + Self.line("sandbox.lifecycle", "started")
        let events = stream.feed(Data((Self.head + Self.chunk(body)).utf8))
        XCTAssertEqual(events, [SandboxEvent(name: "evlat-p4", id: "id-evlat-p4", action: .unknown("paused")),
                                SandboxEvent(name: "evlat-p4", id: "id-evlat-p4", action: .started)])
        XCTAssertEqual(stream.unknownActions, 1)
        XCTAssertEqual(stream.malformedLines, 2, "the cut line and the one with no name")
    }

    /// A line past the limit is dropped whole, and the next one is read.
    func testAnOverlongLineIsDropped() {
        var stream = SandboxDaemon.Stream()
        _ = stream.feed(Data(Self.head.utf8))
        let long = #"{"type":"sandbox.lifecycle","pad":""# + String(repeating: "x", count: SandboxDaemon.Stream.lineLimit)
        _ = stream.feed(Data(Self.chunk(long).utf8))
        let events = stream.feed(Data(Self.chunk("\"}\n" + Self.line("sandbox.lifecycle", "started")).utf8))
        XCTAssertEqual(events.map(\.action), [.started])
        XCTAssertEqual(stream.malformedLines, 1)
    }

    /// Not the stream: nothing read, and why.
    func testAHeadThatIsNotTheStreamFails() {
        var refused = SandboxDaemon.Stream()
        XCTAssertEqual(refused.feed(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)), [])
        XCTAssertEqual(refused.failure, .status(404))
        XCTAssertFalse(refused.opened, "a refused head is no connection")

        var html = SandboxDaemon.Stream()
        _ = html.feed(Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".utf8))
        XCTAssertEqual(html.failure, .contentType("text/html"))
        XCTAssertFalse(html.opened)

        var garbage = SandboxDaemon.Stream()
        _ = garbage.feed(Data("hello\r\n\r\n".utf8))
        XCTAssertEqual(garbage.failure, .status(nil))

        for size in ["-1", "+1", "1 2"] {
            var signed = SandboxDaemon.Stream()
            _ = signed.feed(Data((Self.head + size + "\r\nxx\r\n").utf8))
            XCTAssertEqual(signed.failure, .framing, size)
        }

        var badSize = SandboxDaemon.Stream()
        _ = badSize.feed(Data((Self.head + "zz\r\n").utf8))
        XCTAssertEqual(badSize.failure, .framing)
        XCTAssertEqual(badSize.feed(Data(Self.chunk(Self.line("sandbox.lifecycle", "started")).utf8)), [],
                       "a failed stream reads nothing more")
    }

    /// Opened only once the whole head is read and is the stream.
    func testTheStreamIsOpenedByItsHeadOnly() {
        var stream = SandboxDaemon.Stream()
        let head = Data(Self.head.utf8)
        _ = stream.feed(head.prefix(20))
        XCTAssertFalse(stream.opened, "half a head")
        _ = stream.feed(head.dropFirst(20))
        XCTAssertTrue(stream.opened)
    }

    /// Without chunking the body is the lines as they come.
    func testAnUnchunkedBodyIsReadToo() {
        var stream = SandboxDaemon.Stream()
        let events = stream.feed(Data(("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n\r\n"
            + Self.line("sandbox.lifecycle", "started")).utf8))
        XCTAssertEqual(events.map(\.action), [.started])
    }

    // MARK: - Reconnecting

    func testTheDelayDoublesUpToItsCeiling() {
        XCTAssertEqual(SandboxDaemon.delay(afterFailures: 0), 0)
        XCTAssertEqual((1...8).map(SandboxDaemon.delay(afterFailures:)), [1, 2, 4, 8, 16, 32, 60, 60])
        XCTAssertEqual(SandboxDaemon.delay(afterFailures: 10_000), SandboxDaemon.maximumDelay)
    }

    /// A connection that held for a minute starts the schedule over; a
    /// short one, or none, adds a failure.
    func testAStableConnectionStartsTheScheduleOver() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SandboxDaemon.failures(after: 5, connectedAt: now.addingTimeInterval(-60), now: now), 1)
        XCTAssertEqual(SandboxDaemon.failures(after: 5, connectedAt: now.addingTimeInterval(-59), now: now), 6)
        XCTAssertEqual(SandboxDaemon.failures(after: 0, connectedAt: nil, now: now), 1)
        XCTAssertEqual(SandboxDaemon.failures(after: 3, connectedAt: nil, now: now), 4)
    }
}
