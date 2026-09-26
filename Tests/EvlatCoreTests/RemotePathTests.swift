import XCTest
@testable import EvlatCore

/// `RemotePath`'s pure half: the one line, what adding and removing it does
/// to a startup file's bytes, and the probe's answer line. The scripts run
/// against a fake `ssh` and fake login shells in
/// `EvlatAppTests.RemoteReadingTests`.
final class RemotePathTests: XCTestCase {
    private func plan(_ action: RemoteSettings.Action, _ text: String?) throws -> String? {
        try RemotePath.plan(action, original: text.map { Data($0.utf8) }).map { String(decoding: $0, as: UTF8.self) }
    }

    func testTheLineIsMarkedAndPutsTheCommandsFolderFirst() {
        XCTAssertEqual(RemotePath.line, #"export PATH="$HOME/.local/bin:$PATH"  # evlat-path"#)
        XCTAssertTrue(RemotePath.line.hasSuffix(RemotePath.marker))
        XCTAssertEqual(RemotePath.directory, (RemoteCommand.commandPath as NSString).deletingLastPathComponent)
    }

    func testAddingAppendsOneLineOnce() throws {
        let line = RemotePath.line
        XCTAssertEqual(try plan(.install, nil), line + "\n", "no file: the line alone")
        XCTAssertEqual(try plan(.install, ""), line + "\n")
        XCTAssertEqual(try plan(.install, "alias ll='ls -l'\n"), "alias ll='ls -l'\n" + line + "\n")
        XCTAssertEqual(try plan(.install, "alias ll='ls -l'"), "alias ll='ls -l'\n" + line + "\n",
                       "a last line without its newline keeps its own line")
        XCTAssertNil(try plan(.install, "a\n" + line + "\nb\n"), "already there: nothing to write")
        let once = try XCTUnwrap(try plan(.install, "a\n"))
        XCTAssertNil(try plan(.install, once), "idempotent")
    }

    func testRemovingTakesOnlyEvlatsLine() throws {
        let line = RemotePath.line
        let theirs = #"export PATH="$HOME/.local/bin:$PATH""#
        let file = "a\n\(theirs)\n\(line)\nb\n"
        XCTAssertEqual(try plan(.remove, file), "a\n\(theirs)\nb\n", "the user's own PATH line stays")
        XCTAssertEqual(try plan(.remove, line + "\n"), "")
        XCTAssertEqual(try plan(.remove, "a\n" + line), "a\n", "the last line, without its newline")
        XCTAssertNil(try plan(.remove, "a\n\(theirs)\n"), "no line of Evlat's: nothing to write")
        XCTAssertNil(try plan(.remove, nil))
        XCTAssertNil(try plan(.remove, "a\n\(line) # edited\n"), "a line changed by hand is not Evlat's any more")
    }

    func testAFileThatIsNotTextIsLeftAlone() {
        for bytes in [Data([0x61, 0xFF, 0xFE, 0x0A]), Data([0x61, 0x00, 0x62, 0x0A])] {
            for action in [RemoteSettings.Action.install, .remove] {
                XCTAssertThrowsError(try RemotePath.plan(action, original: bytes)) {
                    XCTAssertEqual($0 as? SettingsFile.Failure, .malformed)
                }
            }
        }
    }

    func testTheWriterPlansThePathLineWithoutJSON() throws {
        let write = try XCTUnwrap(try RemoteSettings.plan(.pathLine(".bashrc"), .install, original: Data("# not json\n".utf8)))
        XCTAssertEqual(String(decoding: write.contents, as: UTF8.self), "# not json\n" + RemotePath.line + "\n")
        XCTAssertNil(write.backup)
        XCTAssertEqual(RemoteSettings.Change.pathLine(".zshrc").path, ".zshrc")
        XCTAssertThrowsError(try RemoteSettings.plan(.pathLine(".bashrc"), .install, original: Data([0xFF]))) {
            XCTAssertEqual($0 as? RemoteSettings.Failure, .file(.malformed))
        }
    }

    func testTheProbesLineIsFoundBehindNoise() {
        let output = Data("motd\nN path 1 0 .bashrc\nX path 0 0 .zshrc\n".utf8)
        XCTAssertEqual(RemotePath.status(output: output, nonce: "N"), .init(onPath: true, file: ".bashrc", added: false))
        XCTAssertEqual(RemotePath.status(output: Data("N path 0 1 .zshrc\n".utf8), nonce: "N"),
                       .init(onPath: false, file: ".zshrc", added: true))
        XCTAssertEqual(RemotePath.status(output: Data("N path - 0 .profile\n".utf8), nonce: "N"),
                       .init(onPath: nil, file: ".profile", added: false), "the shell did not answer")
        XCTAssertNil(RemotePath.status(output: Data("N path 1 0 .evil\n".utf8), nonce: "N"), "only the three files")
        XCTAssertNil(RemotePath.status(output: Data("motd\n".utf8), nonce: "N"))
    }
}
