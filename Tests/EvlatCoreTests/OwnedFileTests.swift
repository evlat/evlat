import XCTest
@testable import EvlatCore

/// A file Evlat writes whole, beside a user's own files: whose it is is
/// read from its head, a write is one `rename`, and nothing of the user's is
/// ever written over or deleted. Every file is under a temporary home.
final class OwnedFileTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.owned.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func file(version: Int = 2, body: String = "export default {}\n") -> OwnedFile {
        OwnedFile(path: ".tool/plugins/evlat.js", comment: "//", marker: "evlat-owned-file", version: version, body: body)
    }

    private var url: URL { file().url(home: home) }

    private func write(_ text: String, mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8),
                                       attributes: [.posixPermissions: mode])
    }

    private func names(in path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(path).path).sorted()
    }

    // MARK: - From the bytes

    func testTheHeadIsTheMarkerAndTheVersionInTheShapeOfTheRemoteCommand() {
        XCTAssertEqual(file().contents, "// evlat-owned-file\n// version 2\nexport default {}\n")
    }

    func testTheStateIsReadFromTheBytes() {
        let current = file()
        XCTAssertEqual(current.state(of: nil), .missing)
        XCTAssertEqual(current.state(of: Data(current.contents.utf8)), .current)
        XCTAssertEqual(current.state(of: Data(file(version: 1).contents.utf8)), .outdated, "an earlier version")
        XCTAssertEqual(current.state(of: Data(file(body: "export default { changed: 1 }\n").contents.utf8)), .outdated,
                       "marked, this version, other bytes: written back")
        XCTAssertEqual(current.state(of: Data("// evlat-owned-file\n".utf8)), .outdated, "marked with no version line")
        XCTAssertEqual(current.state(of: Data("// evlat-owned-file\n// version next\n".utf8)), .outdated)
    }

    func testALaterVersionIsNotCalledOld() {
        let later = file(version: 3, body: "export default { newer: true }\n")
        XCTAssertEqual(file().state(of: Data(later.contents.utf8)), .current,
                       "another copy of Evlat that is newer wrote it; this one never writes it back")
    }

    func testAFileWithoutTheMarkerIsTheUsers() {
        let current = file()
        XCTAssertEqual(current.state(of: Data("export default {}\n".utf8)), .foreign)
        XCTAssertEqual(current.state(of: Data()), .foreign, "an empty file at the path is theirs too")
        let quoted = String(repeating: "// line\n", count: OwnedFile.headerLines) + current.contents
        XCTAssertEqual(current.state(of: Data(quoted.utf8)), .foreign, "the marker counts at the head only")
        XCTAssertEqual(current.state(of: Data(("// not-evlat-owned-file\n// version 2\n").utf8)), .foreign)
    }

    func testAShebangBeforeTheMarkerStillMarksIt() {
        let text = "#!/bin/sh\n// evlat-owned-file\n// version 1\n"
        XCTAssertEqual(file().state(of: Data(text.utf8)), .outdated)
    }

    // MARK: - On disk

    func testInstallWritesTheFileAndItReadsCurrent() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(try file().state(home: home), .missing)
        XCTAssertEqual(try file().install(home: home, opensDirectory: false), .written)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), file().contents)
        XCTAssertEqual(try file().state(home: home), .current)
        XCTAssertEqual(try file().install(home: home, opensDirectory: false), .unchanged, "nothing to write")
    }

    func testANewFileIsReadableByTheUsersOtherProcessesAndLeavesNothingBehind() throws {
        try file().install(home: home, opensDirectory: true)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644)
        XCTAssertEqual(try names(in: ".tool/plugins"), ["evlat.js"], "no temporary file is left next to it")
    }

    func testTheFolderIsMadeOnlyWhenTheRuleSaysSo() throws {
        XCTAssertThrowsError(try file().install(home: home, opensDirectory: false)) {
            XCTAssertEqual($0 as? SettingsFile.Failure, .noDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".tool").path))
        XCTAssertEqual(try file().state(home: home), .missing, "a missing folder reads as a missing file")
        XCTAssertEqual(try file().install(home: home, opensDirectory: true), .written)
        XCTAssertEqual(try file().state(home: home), .current)
    }

    func testAnOlderCopyIsWrittenOverAndKeepsItsMode() throws {
        try write(file(version: 1).contents, mode: 0o600)
        XCTAssertEqual(try file().state(home: home), .outdated)
        XCTAssertEqual(try file().install(home: home, opensDirectory: false), .written)
        XCTAssertEqual(try file().state(home: home), .current)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the mode the user gave it stays")
        XCTAssertEqual(try names(in: ".tool/plugins"), ["evlat.js"], "and no backup: it is regenerated from constants")
    }

    func testAFileOfTheUsersIsNeverWrittenOverOrRemoved() throws {
        let theirs = "export default { mine: true }\n"
        try write(theirs)
        XCTAssertEqual(try file().state(home: home), .foreign)
        XCTAssertThrowsError(try file().install(home: home, opensDirectory: true)) {
            XCTAssertEqual($0 as? SettingsFile.Failure, .malformed)
        }
        XCTAssertEqual(try file().remove(home: home), .unchanged)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), theirs)
        XCTAssertEqual(try names(in: ".tool/plugins"), ["evlat.js"])
    }

    func testALinkAtThePathIsTheUsersAndIsNotFollowed() throws {
        let target = home.appendingPathComponent("dotfiles/evlat.js")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file(version: 1).contents.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertEqual(try file().state(home: home), .foreign, "even a link to one of Evlat's own files")
        XCTAssertThrowsError(try file().install(home: home, opensDirectory: false))
        XCTAssertEqual(try file().remove(home: home), .unchanged)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), file(version: 1).contents)
    }

    func testADanglingLinkAndADirectoryAreTheUsersToo() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: home.appendingPathComponent("nowhere"))
        XCTAssertEqual(try file().state(home: home), .foreign)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(try file().state(home: home), .foreign)
        XCTAssertThrowsError(try file().install(home: home, opensDirectory: true))
        XCTAssertEqual(try file().remove(home: home), .unchanged)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func testRemoveTakesTheMarkedFileAndNothingAroundIt() throws {
        try file().install(home: home, opensDirectory: true)
        let neighbour = url.deletingLastPathComponent().appendingPathComponent("theirs.js")
        try "export default {}\n".write(to: neighbour, atomically: true, encoding: .utf8)
        XCTAssertEqual(try file().remove(home: home), .written)
        XCTAssertEqual(try names(in: ".tool/plugins"), ["theirs.js"], "the folder and its neighbours stay")
        XCTAssertEqual(try file().state(home: home), .missing)
        XCTAssertEqual(try file().remove(home: home), .unchanged, "nothing left to remove")
    }

    func testRemoveTakesAnOlderAndANewerMarkedCopyToo() throws {
        try write(file(version: 1).contents)
        XCTAssertEqual(try file().remove(home: home), .written)
        try write(file(version: 9).contents)
        XCTAssertEqual(try file().remove(home: home), .written, "marked is Evlat's, whichever copy wrote it")
    }

    func testAFileThatCannotBeReadIsRefusedNotGuessedAt() throws {
        try write(file().contents, mode: 0o000)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        try XCTSkipIf(geteuid() == 0, "root reads it")
        XCTAssertThrowsError(try file().state(home: home)) {
            XCTAssertEqual($0 as? SettingsFile.Failure, .unreadable)
        }
    }
}
