import XCTest
@testable import EvlatCore

/// The chats' small index file: versioned, round-trips, and a file it
/// cannot read is reported rather than replaced.
final class ChatIndexTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let id = "6B1F3C52-7B8B-4F4B-9C1E-2B7C1D0E9A11"

    private func entry(run: ChatIndex.Run? = nil) -> ChatIndex.Entry {
        ChatIndex.Entry(id: id, sessionID: "S1", title: "Report", folder: "/tmp/p",
                        isWorkspace: true, createdAt: t0, lastActivity: t0 + 5, pinned: false,
                        lastReply: "ok", allowedRules: ["Bash(ls:*)"], addedDirectories: ["/x"],
                        run: run)
    }

    func testRoundTrip() throws {
        let index = ChatIndex(entries: [entry(run: ChatIndex.Run(pid: 42, startedAt: t0))])
        XCTAssertEqual(try ChatIndex.decode(index.encoded()), index)
        XCTAssertEqual(index.version, ChatIndex.currentVersion)
    }

    func testTheFileSaysItsVersion() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ChatIndex(entries: []).encoded()) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
    }

    /// The caller must not overwrite what it could not read: the error is
    /// the signal to leave the file alone.
    func testAnUnreadableFileIsAnError() {
        XCTAssertThrowsError(try ChatIndex.decode(Data("{nope".utf8)))
        XCTAssertThrowsError(try ChatIndex.decode(Data(#"{"version":2,"entries":[]}"#.utf8))) {
            XCTAssertEqual($0 as? ChatIndex.DecodeError, .unsupportedVersion(2))
        }
    }

    /// An id is later turned into a path under `chats/` (pruning, `phase-5`),
    /// so one that is not a UUID makes the whole file unreadable rather than
    /// a path someone else chose.
    func testAnEntryWhoseIdIsNotAUUIDIsAnError() throws {
        var bad = entry()
        bad.id = "../../Documents"
        XCTAssertThrowsError(try ChatIndex.decode(ChatIndex(entries: [bad]).encoded())) {
            XCTAssertEqual($0 as? ChatIndex.DecodeError, .badID("../../Documents"))
        }
    }

    /// A turn recorded as running when Evlat starts was cut off by Evlat
    /// going away. Its process is ended if it is still the same process;
    /// the chat is marked interrupted either way.
    func testOrphans() {
        let other = "0C9E7D1A-8E57-4B9B-8D0F-7F2B4E6A1C33"
        let third = "5A8F2E10-3C4D-4E5F-8A9B-0C1D2E3F4A5B"
        var dead = entry(run: ChatIndex.Run(pid: 7, startedAt: t0))
        dead.id = other
        var idle = entry()
        idle.id = third
        let index = ChatIndex(entries: [entry(run: ChatIndex.Run(pid: 42, startedAt: t0)), dead, idle])
        let platform = Platform(isAlive: { $0 == 42 }, processStartedAt: { [t0] _ in t0 })
        let orphans = index.orphans(platform: platform)
        XCTAssertEqual(orphans.terminate, [42])
        XCTAssertEqual(orphans.interrupted, [id, other])
    }

    /// A run saved without a start time cannot be told from a recycled pid.
    func testARunWithoutAStartTimeIsNotTerminated() {
        let index = ChatIndex(entries: [entry(run: ChatIndex.Run(pid: 42, startedAt: nil))])
        let platform = Platform(isAlive: { _ in true })
        XCTAssertEqual(index.orphans(platform: platform).terminate, [])
        XCTAssertEqual(index.orphans(platform: platform).interrupted, [id])
    }

    /// A recycled pid is someone else's process and is never signalled.
    func testARecycledPidIsNotTerminated() {
        let index = ChatIndex(entries: [entry(run: ChatIndex.Run(pid: 42, startedAt: t0))])
        let platform = Platform(isAlive: { _ in true }, processStartedAt: { [t0] _ in t0 + 86_400 })
        XCTAssertEqual(index.orphans(platform: platform).terminate, [])
        XCTAssertEqual(index.orphans(platform: platform).interrupted, [id])
    }
}
