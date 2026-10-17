import XCTest
@testable import EvlatCore

final class GitRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("repository-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ value: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    func testClonesUsingSSHAndHTTPSHaveTheSameIdentityWithoutCredentials() throws {
        try write("[remote \"origin\"]\n url = git@GitHub.com:team/project.git\n", "first/.git/config")
        try write("[remote \"origin\"]\n url = https://user:secret@github.com/team/project/\n", "second/.git/config")
        let first = try XCTUnwrap(GitRepository.origin(in: root.appendingPathComponent("first").path))
        let second = GitRepository.origin(in: root.appendingPathComponent("second").path)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.key, "github.com/team/project")
        XCTAssertEqual(first.name, "project")
        XCTAssertEqual(GitRepository.identity("ssh://git@github.com:22/team/project.git", relativeTo: "/"), first)
        XCTAssertNotEqual(GitRepository.identity("https://github.com/other/project.git", relativeTo: "/"), first)
    }

    func testWorktreeAndSubfolderUseTheCommonConfig() throws {
        try write("[remote \"origin\"]\nurl=https://example.com/team/project.git\n", "main/.git/config")
        try write("../..\n", "main/.git/worktrees/feature/commondir")
        try write("gitdir: ../main/.git/worktrees/feature\n", "feature/.git")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("feature/Sources/App"), withIntermediateDirectories: true)
        XCTAssertEqual(GitRepository.origin(in: root.appendingPathComponent("feature/Sources/App").path),
                       GitRepository.origin(in: root.appendingPathComponent("main").path))
        XCTAssertNotNil(GitRepository.origin(in: root.appendingPathComponent("feature").path))
    }

    func testOnlyOriginIsReadAndIncludesAreNotFollowed() throws {
        try write("[remote \"upstream\"]\nurl=https://example.com/project\n[include]\npath=../../included\n", "repo/.git/config")
        try write("[remote \"origin\"]\nurl=https://example.com/private\n", "included")
        XCTAssertNil(GitRepository.origin(in: root.appendingPathComponent("repo").path))
        XCTAssertNil(GitRepository.origin(in: "/path/that/does/not/exist"))
        XCTAssertNil(GitRepository.origin(in: "relative/folder"))
    }

    func testConfigQuotesCommentsAndFirstFetchURL() {
        let config = """
        # unrelated data
        [remote "origin"] ; comment
          fetch = +refs/heads/*:refs/remotes/origin/*
          URL = "https://example.com/team/project.git" # comment
          url = https://example.com/other.git
        [remote "upstream"]
          url = https://example.com/upstream.git
        """
        XCTAssertEqual(GitRepository.originURL(in: config), "https://example.com/team/project.git")
        XCTAssertNil(GitRepository.originURL(in: "[remote \"Origin\"]\nurl=https://example.com/project"))
        XCTAssertNil(GitRepository.originURL(in: "[remote \"origin\"]\nurl=\"unfinished"))
    }

    func testMalformedNextSectionAndRemoteHelpersAreUnknown() {
        XCTAssertNil(GitRepository.originURL(in: "[remote \"origin\"]\n[remote \"unfinished]\nurl=https://example.com/other"))
        XCTAssertNil(GitRepository.identity("ext::some-command", relativeTo: "/repo"))
        XCTAssertNil(GitRepository.identity("file:///", relativeTo: "/repo"))
    }

    func testOversizedAndMalformedMetadataFallsBack() throws {
        try write(String(repeating: "x", count: 65_536), "repo/.git/config")
        XCTAssertNil(GitRepository.origin(in: root.appendingPathComponent("repo").path))
        try write("", "repo/.git/commondir")
        XCTAssertNil(GitRepository.origin(in: root.appendingPathComponent("repo").path))
        XCTAssertNil(GitRepository.identity("https://example.com", relativeTo: "/"))
        XCTAssertNil(GitRepository.identity("https://example.com/repo\nsecret", relativeTo: "/"))
        XCTAssertNil(GitRepository.identity("file://another-host/repo", relativeTo: "/"))
    }
}
