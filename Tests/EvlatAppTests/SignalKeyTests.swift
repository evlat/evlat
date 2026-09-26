import XCTest
import EvlatCore
@testable import EvlatApp

/// The `/signal` key on disk: who may write it, with what
/// mode, and that a planted link is not followed. Every file here is under a
/// temporary home; the user's `Application Support` is never touched.
final class SignalKeyTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-signal-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private var location: URL { SignalKey.location(port: 48999, home: home, environment: [:])! }

    // MARK: - Where

    func testTheFileIsPerPortUnderTheHome() {
        XCTAssertEqual(location.path,
                       home.path + "/Library/Application Support/Evlat/signal-48999.token")
        XCTAssertEqual(SignalKey.location(port: 48151, environment: ["EVLAT_HOME": home.path])?.lastPathComponent,
                       "signal-48151.token")
    }

    /// `EVLAT_PORT` without `EVLAT_HOME` is a measured process: no key to
    /// write or read — it must not overwrite the user's.
    func testAnIsolatedProcessHasNoKeyFile() {
        XCTAssertNil(SignalKey.location(port: 48999, home: home, environment: ["EVLAT_PORT": "48999"]))
        XCTAssertNotNil(SignalKey.location(port: 48999, home: home,
                                           environment: ["EVLAT_PORT": "48999", "EVLAT_HOME": home.path]))
        XCTAssertNotNil(SignalKey.location(port: 48999, home: home, environment: ["EVLAT_PORT": " "]),
                        "a blank override is no override")
        XCTAssertNil(SignalKey.location(port: 48999, home: nil, environment: [:]), "no home, no file")

        let writer = AppController.signalKeyWriter(home: home, environment: ["EVLAT_PORT": "48999"])
        XCTAssertNil(writer(48999))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path),
                       "nothing written at all")
    }

    // MARK: - How

    func testTheKeyIsWrittenOwnerOnlyInAnOwnerOnlyDirectory() throws {
        let key = try XCTUnwrap(SignalKey.write(to: location))
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(try mode(location), 0o600)
        XCTAssertEqual(try mode(location.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(SignalKey.read(from: location), key)
        // No temporary left beside it.
        let names = try FileManager.default.contentsOfDirectory(atPath: location.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["signal-48999.token"])
    }

    /// The chats' store makes the directory first, at `0755`; the key's
    /// writer states `0700` on it anyway.
    func testAnExistingDirectoryIsMadeOwnerOnly() throws {
        let directory = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertNotNil(SignalKey.write(to: location))
        XCTAssertEqual(try mode(directory), 0o700)
    }

    /// Quitting takes the key away — only its own: a key another launch wrote
    /// since stays.
    func testQuittingRemovesItsOwnKeyOnly() throws {
        let written = SignalKey.Written()
        let writer = AppController.signalKeyWriter(home: home, environment: [:], written: written)
        XCTAssertNotNil(writer(48999))
        written.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))

        let other = SignalKey.Written()
        XCTAssertNotNil(AppController.signalKeyWriter(home: home, environment: [:], written: other)(48999))
        let newer = try XCTUnwrap(SignalKey.write(to: location))
        other.remove()
        XCTAssertEqual(SignalKey.read(from: location), newer)
    }

    /// Whatever holds the port wrote the refusal; it goes to a terminal.
    func testARefusalIsCleanedBeforeItIsPrinted() {
        let body = #"{"error":{"code":"x","message":"\u001b]0;owned\u0007\u001b[2Jhi"}}"#
        XCTAssertEqual(SignalClient.refusal(code: 400, body: body), "400 x: ]0;owned[2Jhi")
    }

    func testEveryLaunchWritesANewKey() throws {
        let first = try XCTUnwrap(SignalKey.write(to: location))
        let second = try XCTUnwrap(SignalKey.write(to: location))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(SignalKey.read(from: location), second)
        XCTAssertEqual(try mode(location), 0o600)
    }

    /// A link planted at the path is replaced, not written through: its
    /// target keeps its bytes and the path becomes the key file.
    func testALinkAtThePathIsNotFollowed() throws {
        let directory = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("victim")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: location, withDestinationURL: target)

        let key = try XCTUnwrap(SignalKey.write(to: location))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep me")
        let type = try FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
        XCTAssertEqual(try mode(location), 0o600)
        XCTAssertEqual(SignalKey.read(from: location), key)
    }

    /// Nowhere to write: no key, so the listener refuses every `/signal`.
    func testAKeyThatCannotBeWrittenIsNone() throws {
        // A file where the directory should be.
        let blocked = home.appendingPathComponent("Library")
        try Data().write(to: blocked)
        XCTAssertNil(SignalKey.write(to: location))
    }

    func testReadingTrimsAndRefusesEmpty() throws {
        let directory = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("  abc \n".utf8).write(to: location)
        XCTAssertEqual(SignalKey.read(from: location), "abc")
        try Data("\n".utf8).write(to: location)
        XCTAssertNil(SignalKey.read(from: location))
        try FileManager.default.removeItem(at: location)
        XCTAssertNil(SignalKey.read(from: location))
    }

    // MARK: - What `--list` and `--capture` print

    func testTheProbeSaysWhatItsAnswerMeans() {
        XCTAssertEqual(AppController.signalProbeText(nil), "no key file")
        XCTAssertEqual(AppController.signalProbeText(.status(200)), "ok")
        XCTAssertEqual(AppController.signalProbeText(.status(403)), "key mismatch (403)")
        XCTAssertEqual(AppController.signalProbeText(.status(404)), "no /signal route (404: v1 or older v2)")
        XCTAssertEqual(AppController.signalProbeText(.notRunning), "not running")
    }

    /// The capture names the id, the phase and the ttl — never the detail.
    func testTheCaptureLineKeepsTheDetailOff() throws {
        let json: [String: Any] = ["id": "build", "ttl": 60, "phase": "working",
                                   "detail": "secret path", "label": "npm run build", "sender": "npm"]
        let report = try SignalReport.parse(json: json).get()
        let line = AppController.signalCaptureLine(report)
        XCTAssertEqual(line, "  signal   build  working  ttl 60  from npm")
        XCTAssertFalse(line.contains("secret"))
        let clear = try SignalReport.parse(json: ["id": "build", "ttl": 0]).get()
        XCTAssertEqual(AppController.signalCaptureLine(clear), "  signal   build  clear  ttl 0")
    }

    func testADroppedRowIsOneStderrLine() {
        XCTAssertEqual(AppController.droppedSignalLine(id: "x", limit: 32), "Evlat: signal x dropped: 32 rows\n")
        XCTAssertEqual(AppController.droppedSignalLine(id: "x", limit: 32, machine: "devbox"),
                       "Evlat: signal x from devbox dropped: 32 rows\n")
    }
}
