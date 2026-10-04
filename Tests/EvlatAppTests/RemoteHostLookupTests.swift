import XCTest
import EvlatCore
@testable import EvlatApp

/// `RemoteHostLookup.select`: the click's one call to a server, over the
/// machine's tunnel master and only over it.
final class RemoteHostLookupTests: XCTestCase {
    private static let session = "8087b2ed-d738-42da-abf1-8693d1094eda"
    private static let records = SessionRecords(directory: ".claude/sessions", idKey: "sessionId", pidKey: "pid",
                                                startedAtKey: "startedAt")
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lookup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// A fake `ssh` that keeps its arguments and its stdin, and answers as
    /// a server whose herdr took the pane: the nonce is the script's own.
    private func fakeSSH(answers: Bool = true) throws -> String {
        let url = folder.appendingPathComponent("ssh")
        let text = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(folder.path)/argv'
            cat > '\(folder.path)/stdin'
            n=$(sed -n "1s/^n='\\(.*\\)'$/\\1/p" '\(folder.path)/stdin')
            \(answers ? "printf 'Welcome\\n%s focused\\n' \"$n\"" : "printf 'Welcome\\n'")
            """
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Over the master or nowhere (`RemoteHost.arguments`: the fallback
    /// connection fails before it opens), with the select script on stdin.
    func testTheSelectionRidesOnlyTheMaster() throws {
        let ssh = try fakeSSH()
        XCTAssertTrue(RemoteHostLookup.selectPane(sessionID: Self.session, records: Self.records, target: "devbox",
                                                  controlPath: "/tmp/e/1", ssh: ssh))
        let argv = try String(contentsOf: folder.appendingPathComponent("argv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, RemoteHost.arguments(target: "devbox", controlPath: "/tmp/e/1"))
        XCTAssertTrue(argv.contains("ProxyCommand=/usr/bin/false"))
        let stdin = try String(contentsOf: folder.appendingPathComponent("stdin"), encoding: .utf8)
        XCTAssertTrue(stdin.contains("agent focus"))
        XCTAssertTrue(stdin.contains("id='\(Self.session)'"))
    }

    func testNoLineOfItsOwnIsNoSelection() throws {
        XCTAssertFalse(RemoteHostLookup.selectPane(sessionID: Self.session, records: Self.records, target: "devbox",
                                                   controlPath: "/tmp/e/1", ssh: try fakeSSH(answers: false)))
    }

    /// An id that is not a session id never reaches a script: no call, and
    /// no completion.
    func testOnlyASessionIDIsSelected() throws {
        let lookup = RemoteHostLookup(sshPath: try fakeSSH())
        XCTAssertFalse(lookup.select(sessionID: "w2:p3", records: Self.records, target: "devbox",
                                     controlPath: "/tmp/e/1", startBy: 1) { XCTFail("no call, no completion") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("argv").path))
    }

    /// A selection still queued past its start — behind another card's
    /// slow question — is not made, and still completes.
    func testASelectionQueuedTooLongIsNotMade() throws {
        let queue = DispatchQueue(label: "test.remote-host")
        let lookup = RemoteHostLookup(sshPath: try fakeSSH(), queue: queue)
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        let done = expectation(description: "completed")
        XCTAssertTrue(lookup.select(sessionID: Self.session, records: Self.records, target: "devbox",
                                    controlPath: "/tmp/e/1", startBy: 0.05) { done.fulfill() })
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        wait(for: [done], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("argv").path))
    }
}
