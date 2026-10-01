import XCTest
@testable import EvlatCore

/// The branch read from git's files, against folders built in a temporary
/// directory: a repository, a worktree, a subfolder, a stranger's file.
final class GitHeadTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "githead-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // `/var` is a link to `/private/var`; the reader standardises paths.
        root = (root as NSString).resolvingSymlinksInPath
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ text: String, to path: String) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    private func folder(_ path: String) throws -> String {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    // MARK: - Layouts

    func testARepositoryNamesItsBranch() throws {
        try write("ref: refs/heads/main\n", to: "shop-api/.git/HEAD")
        XCTAssertEqual(GitHead.branch(in: root + "/shop-api"), "main")
    }

    /// Branch names hold slashes; only the `refs/heads/` prefix goes.
    func testASlashedBranchKeepsItsSlashes() throws {
        try write("ref: refs/heads/feat/checkout-v2\n", to: "shop-api/.git/HEAD")
        XCTAssertEqual(GitHead.branch(in: root + "/shop-api"), "feat/checkout-v2")
    }

    func testASubfolderReadsItsRepository() throws {
        try write("ref: refs/heads/main\n", to: "shop-api/.git/HEAD")
        let sub = try folder("shop-api/Sources/App")
        XCTAssertEqual(GitHead.branch(in: sub), "main")
    }

    /// The case the feature is for: worktrees whose folders share a name,
    /// each with its own `HEAD` under the main repository's `.git/worktrees`.
    func testAWorktreeReadsItsOwnHead() throws {
        try write("ref: refs/heads/main\n", to: "a/shop-api/.git/HEAD")
        try write("ref: refs/heads/fix/rate-limit\n", to: "a/shop-api/.git/worktrees/shop-api/HEAD")
        try write("gitdir: \(root!)/a/shop-api/.git/worktrees/shop-api\n", to: "b/shop-api/.git")
        XCTAssertEqual(GitHead.branch(in: root + "/b/shop-api"), "fix/rate-limit")
        XCTAssertEqual(GitHead.branch(in: root + "/a/shop-api"), "main")
    }

    func testARelativeGitdirIsReadFromTheFilesFolder() throws {
        try write("ref: refs/heads/feat/x\n", to: "repo/.git/worktrees/wt/HEAD")
        try write("gitdir: ../repo/.git/worktrees/wt\n", to: "wt/.git")
        XCTAssertEqual(GitHead.branch(in: root + "/wt"), "feat/x")
    }

    func testADetachedHeadIsItsShortID() throws {
        try write("a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\n", to: "r/.git/HEAD")
        XCTAssertEqual(GitHead.branch(in: root + "/r"), "a1b2c3d")
    }

    // MARK: - Nothing to say

    func testAFolderOutsideAnyRepositoryHasNoBranch() throws {
        XCTAssertNil(GitHead.branch(in: try folder("plain")))
    }

    func testARelativeOrMissingFolderHasNoBranch() {
        XCTAssertNil(GitHead.branch(in: "shop-api"))
        XCTAssertNil(GitHead.branch(in: ""))
        XCTAssertNil(GitHead.branch(in: root + "/nowhere"))
    }

    /// The folder came from a request body: what is not one of git's two
    /// shapes is not drawn.
    func testAHeadGitDidNotWriteIsNotDrawn() throws {
        try write("hello there\n", to: "r/.git/HEAD")
        XCTAssertNil(GitHead.branch(in: root + "/r"))
        try write(String(repeating: "x", count: 4096), to: "s/.git/HEAD")
        XCTAssertNil(GitHead.branch(in: root + "/s"), "a file longer than git's is not read")
        try write("gitdir-ish nonsense\n", to: "t/.git")
        XCTAssertNil(GitHead.branch(in: root + "/t"))
    }

    func testParseRefusesWhatGitRefuses() {
        XCTAssertNil(GitHead.parse("ref: refs/heads/"))
        XCTAssertNil(GitHead.parse("ref: refs/heads/a b"))
        XCTAssertNil(GitHead.parse("ref: refs/heads/a\u{1B}[31mb"))
        XCTAssertNil(GitHead.parse("ref: refs/tags/v1"), "HEAD on a tag ref is not a branch")
        XCTAssertNil(GitHead.parse("A1B2C3D4E5F60718293A4B5C6D7E8F9012345678"), "git writes lower-case ids")
        XCTAssertEqual(GitHead.parse("ref: refs/heads/main\r\n"), "main")
    }
}
