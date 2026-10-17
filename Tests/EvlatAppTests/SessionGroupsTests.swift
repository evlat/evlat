import XCTest
import EvlatCore
@testable import EvlatApp

final class SessionGroupsTests: XCTestCase {
    func testSavedMemberMarkerDefaultsAndChoices() {
        XCTAssertEqual(SessionGroupBullet.stored(nil), .dot)
        XCTAssertEqual(SessionGroupBullet.stored("unknown"), .dot)
        for marker in SessionGroupBullet.allCases {
            XCTAssertEqual(SessionGroupBullet.stored(marker.rawValue), marker)
        }
        XCTAssertEqual(SessionGroupBullet.dot.symbol, "•")
        XCTAssertEqual(SessionGroupBullet.dash.symbol, "–")
        XCTAssertNil(SessionGroupBullet.none.symbol)
    }

    private func signal(_ id: String, _ folder: String? = "/work/project", kind: Signal.Kind = .session,
                        machine: Signal.Machine? = nil) -> Signal {
        Signal(provider: "test", entity: id, kind: kind, phase: .idle, label: "CLI \(id)",
               detail: folder, fidelity: .derived, updatedAt: Date(), machine: machine)
    }

    func testSameFolderGroupsAcrossToolsAndTitlesAndKeepsMemberOrder() {
        let rows = [signal("b"), signal("other", "/another"), signal("a", "/work/./project")]
        let groups = SessionGroup.groups(rows) { _ in nil }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "project")
        XCTAssertEqual(groups.first?.entities, ["b", "a"])
    }

    func testSameOriginGroupsDifferentFoldersAndDifferentOriginsStayApart() {
        let groups = SessionGroup.groups([signal("a", "/clone-a"), signal("b", "/clone-b"), signal("c", "/other")]) {
            GitRepository.Identity(key: $0.entity == "c" ? "example.com/other/project" : "example.com/team/project", name: "project")
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.key, .repository("example.com/team/project"))
        XCTAssertEqual(groups.first?.entities, ["a", "b"])
    }

    func testRemoteAndSandboxFoldersAreScopedWithoutReadingTheirGitFiles() {
        let first = Signal.Machine(name: "first", dim: nil, id: "sandbox")
        let second = Signal.Machine(name: "second", dim: nil, id: "sandbox")
        let groups = SessionGroup.groups([signal("local"), signal("a", machine: first), signal("b", machine: first),
                                          signal("different", machine: second)]) {
            XCTAssertNil($0.machine, "Remote paths must not be read locally")
            return nil
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.entities, ["a", "b"])
        XCTAssertEqual(groups.first?.title, "project · first")
    }

    func testJobsUsageAndMissingFoldersDoNotBecomeGroupsOrReadGit() {
        let rows = [signal("job", kind: .job), signal("custom", kind: .custom),
                    signal("usage", kind: .usage), signal("missing", nil), signal("relative", "relative")]
        XCTAssertTrue(SessionGroup.groups(rows) { _ in XCTFail("Unexpected repository read"); return nil }.isEmpty)
    }
}
