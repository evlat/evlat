import XCTest
import EvlatCore
@testable import EvlatApp

/// `~/.local/bin/evlat` (`014`, R4): the five states, the writer's rules and
/// the manual line. Every path is under a temporary home; the user's
/// `~/.local/bin` is never read or written here.
final class CommandLinkTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var link: URL { CommandLink.link(home: home) }
    private var binary: URL!
    private var otherCopy: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat.tests.link.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        binary = try bundle("this")
        otherCopy = try bundle("other")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// `<root>/<name>/Evlat.app/Contents/MacOS/Evlat` with Evlat's bundle id.
    private func bundle(_ name: String, id: String = CommandLink.bundleID) throws -> URL {
        let contents = root.appendingPathComponent("\(name)/Evlat.app/Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id],
                                                       format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("Evlat")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        return executable
    }

    private func makeLink(to destination: String) throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
    }

    private func destination() -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) }

    func testTheFiveStates() throws {
        XCTAssertEqual(CommandLink.state(at: link, binary: binary), .missing)
        try makeLink(to: binary.path)
        XCTAssertEqual(CommandLink.state(at: link, binary: binary), .current)
        try FileManager.default.removeItem(at: link)
        try makeLink(to: otherCopy.path)
        XCTAssertEqual(CommandLink.state(at: link, binary: binary),
                       .otherCopy(target: otherCopy.resolvingSymlinksInPath().path))
        try FileManager.default.removeItem(at: link)
        try makeLink(to: root.appendingPathComponent("gone/Evlat").path)
        XCTAssertEqual(CommandLink.state(at: link, binary: binary),
                       .broken(target: root.appendingPathComponent("gone/Evlat").path))
        try FileManager.default.removeItem(at: link)
        try makeLink(to: try bundle("stranger", id: "com.example.evlat").path)
        XCTAssertEqual(CommandLink.state(at: link, binary: binary), .foreign, "a binary called Evlat is not enough")
        try FileManager.default.removeItem(at: link)
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: link)
        XCTAssertEqual(CommandLink.state(at: link, binary: binary), .foreign, "a file of the user's own")
    }

    func testARelativeLinkIsReadFromItsDirectory() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let relative = "../../../this/Evlat.app/Contents/MacOS/Evlat"
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: relative)
        XCTAssertEqual(CommandLink.state(at: link, binary: binary), .current)
    }

    func testTheWriterNeverTouchesSomeoneElses() throws {
        try Data("mine".utf8).write(to: { try? FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true); return link }())
        XCTAssertThrowsError(try CommandLinkWriter.install(at: link, binary: binary, replacing: true)) {
            XCTAssertEqual($0 as? CommandLinkWriter.Failure, .foreign)
        }
        XCTAssertThrowsError(try CommandLinkWriter.remove(at: link, binary: binary)) {
            XCTAssertEqual($0 as? CommandLinkWriter.Failure, .foreign)
        }
        XCTAssertEqual(try String(contentsOf: link), "mine")
    }

    func testAnotherCopysOrABrokenLinkIsReplacedOnlyWithConsent() throws {
        for target in [otherCopy.path, root.appendingPathComponent("gone/Evlat").path] {
            try makeLink(to: target)
            XCTAssertThrowsError(try CommandLinkWriter.install(at: link, binary: binary, replacing: false)) {
                XCTAssertEqual($0 as? CommandLinkWriter.Failure, .notAgreed)
            }
            XCTAssertEqual(destination(), target, "untouched without consent")
            try CommandLinkWriter.install(at: link, binary: binary, replacing: true)
            XCTAssertEqual(CommandLink.state(at: link, binary: binary), .current)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: link.deletingLastPathComponent().path),
                           ["evlat"], "no temporary link left beside it")
            try FileManager.default.removeItem(at: link)
        }
    }

    func testInstallThenRemove() throws {
        try CommandLinkWriter.install(at: link, binary: binary, replacing: false)
        XCTAssertEqual(destination(), binary.path)
        try CommandLinkWriter.install(at: link, binary: binary, replacing: false)
        try CommandLinkWriter.remove(at: link, binary: binary)
        XCTAssertEqual(CommandLink.state(at: link, binary: binary), .missing)
        XCTAssertThrowsError(try CommandLinkWriter.remove(at: link, binary: binary))
        try makeLink(to: otherCopy.path)
        XCTAssertThrowsError(try CommandLinkWriter.remove(at: link, binary: binary),
                             "another copy's link is its own to remove")
        XCTAssertEqual(destination(), otherCopy.path)
    }

    /// The line a user pastes makes the link the writer makes, and the
    /// removal line takes it away.
    func testTheManualLineMakesTheSameLink() throws {
        func sh(_ line: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", line]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, line)
        }
        let line = CommandLink.manualLine(binary: binary)
        XCTAssertTrue(line.hasPrefix("mkdir -p ~/.local/bin && ln -sf '"), line)
        // Offered over another copy's link and a broken one too: it replaces.
        for stale in [otherCopy.path, home.appendingPathComponent("gone/Evlat").path] {
            try makeLink(to: stale)
            try sh(line)
            XCTAssertEqual(CommandLink.state(at: link, binary: binary), .current, stale)
            try FileManager.default.removeItem(at: link)
        }
        try sh(line)
        let byHand = destination()
        XCTAssertEqual(CommandLink.state(at: link, binary: binary), .current)
        try sh(CommandLink.removeLine)
        XCTAssertEqual(CommandLink.state(at: link, binary: binary), .missing)
        try CommandLinkWriter.install(at: link, binary: binary, replacing: false)
        XCTAssertEqual(destination(), byHand)
    }

    func testAQuoteInThePathSurvivesTheManualLine() throws {
        let odd = try bundle("it's here")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CommandLink.manualLine(binary: odd)]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(destination(), odd.path)
    }

    func testThePathCheckReadsTildeAndHome() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        XCTAssertTrue(CommandLink.isOnPath("/usr/bin:/Users/someone/.local/bin:/bin", home: home))
        XCTAssertTrue(CommandLink.isOnPath("/usr/bin:~/.local/bin", home: home))
        XCTAssertTrue(CommandLink.isOnPath("$HOME/.local/bin/", home: home))
        XCTAssertFalse(CommandLink.isOnPath("/usr/bin:/bin:/Users/someone/bin", home: home))
        XCTAssertFalse(CommandLink.isOnPath("", home: home))
    }
}
