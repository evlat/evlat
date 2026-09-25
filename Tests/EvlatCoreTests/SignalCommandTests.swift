import XCTest
@testable import EvlatCore

/// `Evlat signal` and `Evlat watch` as arguments (`012/phase-4`): what each
/// word means, where Evlat's flags end and the wrapped command begins, and
/// that every body the command builds is one the route accepts.
final class SignalCommandTests: XCTestCase {
    private func parsed(_ arguments: [String], file: StaticString = #filePath,
                        line: UInt = #line) -> SignalCommand.Parsed? {
        switch SignalCommand.parse(arguments) {
        case .success(let parsed): return parsed
        case .failure(let error):
            XCTFail("refused: \(error.message)", file: file, line: line)
            return nil
        }
    }

    private func refused(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let parsed) = SignalCommand.parse(arguments) {
            XCTFail("accepted: \(parsed)", file: file, line: line)
        }
    }

    private func watch(_ arguments: [String], file: StaticString = #filePath,
                       line: UInt = #line) -> SignalCommand.Watch? {
        guard case .watch(let watch)? = parsed(["watch"] + arguments, file: file, line: line) else {
            XCTFail("not a watch", file: file, line: line)
            return nil
        }
        return watch
    }

    private func post(_ arguments: [String], file: StaticString = #filePath,
                      line: UInt = #line) -> SignalCommand.Post? {
        guard case .signal(let post)? = parsed(["signal"] + arguments, file: file, line: line) else {
            XCTFail("not a signal", file: file, line: line)
            return nil
        }
        return post
    }

    /// The body as the route reads it: the two halves' contract.
    private func report(_ post: SignalCommand.Post, file: StaticString = #filePath,
                        line: UInt = #line) throws -> SignalReport {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: post.body) as? [String: Any],
                                 file: file, line: line)
        return try SignalReport.parse(json: json).get()
    }

    // MARK: - Which word

    /// Only `argv[1]` decides: a wrapped command's own `--capture` or `--list`
    /// is the command's, and a subcommand word further on is nobody's.
    func testTheSubcommandIsReadFromTheFirstArgumentOnly() {
        XCTAssertEqual(SignalCommand.subcommand(["Evlat", "watch", "make"]), "watch")
        XCTAssertEqual(SignalCommand.subcommand(["Evlat", "signal", "x"]), "signal")
        XCTAssertNil(SignalCommand.subcommand(["Evlat"]))
        XCTAssertNil(SignalCommand.subcommand(["Evlat", "--list"]))
        XCTAssertNil(SignalCommand.subcommand(["Evlat", "--list", "watch"]))
        XCTAssertNil(SignalCommand.subcommand(["Evlat", "Watch"]))
    }

    // MARK: - watch

    /// Evlat's flags come only before the command; everything from the first
    /// word that is not one belongs to the command, `--capture` included.
    func testEverythingAfterTheCommandBelongsToIt() {
        let parsed = watch(["--label", "R", "blender", "-b", "x", "--capture"])
        XCTAssertEqual(parsed?.command, ["blender", "-b", "x", "--capture"])
        XCTAssertEqual(parsed?.label, "R")
        XCTAssertNil(parsed?.sender)
        XCTAssertEqual(watch(["make", "--label", "x"])?.command, ["make", "--label", "x"])
        XCTAssertNil(watch(["make", "--label", "x"])?.label)
        XCTAssertEqual(watch(["ls", "--list"])?.command, ["ls", "--list"])
    }

    /// `--` is optional, and is the way to wrap a command that starts with a dash.
    func testTheSeparatorIsOptional() {
        XCTAssertEqual(watch(["--", "npm", "run", "build"])?.command, ["npm", "run", "build"])
        XCTAssertEqual(watch(["npm", "run", "build"])?.command, ["npm", "run", "build"])
        XCTAssertEqual(watch(["--sender", "ci", "--", "--odd", "--"])?.command, ["--odd", "--"])
        XCTAssertEqual(watch(["--sender", "ci", "--", "--odd"])?.sender, "ci")
    }

    func testWatchArgumentErrors() {
        refused(["watch"])
        refused(["watch", "--"])
        refused(["watch", "--label"])
        refused(["watch", "--label", "x"])
        refused(["watch", "--nope", "make"])
        refused(["watch", "--progress", "0.5", "make"])
    }

    /// The row's id is the wrapper's pid, its label the command line, its
    /// sender the program's name and its detail the folder it ran in.
    func testTheRowIsDerivedFromTheCommand() throws {
        let parsed = try XCTUnwrap(watch(["/usr/local/bin/npm", "run", "build"]))
        let home = "/Users/me"
        let running = parsed.post(.running, pid: 4242, directory: "/Users/me/code/app", home: home)
        XCTAssertEqual(running.id, "watch-4242")
        XCTAssertEqual(running.word, .working)
        XCTAssertEqual(running.ttl, SignalCommand.watchTTL)
        XCTAssertEqual(running.label, "/usr/local/bin/npm run build")
        XCTAssertEqual(running.sender, "npm")
        XCTAssertEqual(running.detail, "~/code/app")

        let done = parsed.post(.exited(0), pid: 4242, directory: "/Users/me/code/app", home: home)
        XCTAssertEqual(done.word, .done)
        XCTAssertEqual(done.detail, "~/code/app")
        let failed = parsed.post(.exited(3), pid: 4242, directory: "/Users/me/code/app", home: home)
        XCTAssertEqual(failed.word, .failed)
        XCTAssertEqual(failed.detail, "exit 3 · ~/code/app")
        let killed = parsed.post(.signaled(2), pid: 4242, directory: "/tmp", home: home)
        XCTAssertEqual(killed.word, .failed)
        XCTAssertEqual(killed.detail, "signal 2 · /tmp")

        // The home itself, and a folder that only starts with the same letters.
        XCTAssertEqual(parsed.post(.running, pid: 1, directory: "/Users/me", home: home).detail, "~")
        XCTAssertEqual(parsed.post(.running, pid: 1, directory: "/Users/meg/x", home: home).detail, "/Users/meg/x")
    }

    func testTheLabelAndSenderFlagsWin() throws {
        let parsed = try XCTUnwrap(watch(["--label", "Render", "--sender", "farm", "blender", "-b"]))
        let post = parsed.post(.running, pid: 1, directory: "/", home: "/Users/me")
        XCTAssertEqual(post.label, "Render")
        XCTAssertEqual(post.sender, "farm")
    }

    /// A long command line is shortened to what the row can hold, with an
    /// ellipsis rather than a silent cut.
    func testALongCommandLineIsShortened() throws {
        let words = ["make"] + Array(repeating: "target", count: 30)
        let label = try XCTUnwrap(watch(words)).post(.running, pid: 1, directory: "/", home: "/h").label
        XCTAssertEqual(label?.count, SignalReport.labelLimit)
        XCTAssertEqual(label?.last, "…")
        XCTAssertTrue(label?.hasPrefix("make target target") ?? false)
    }

    func testEveryWatchBodyIsOneTheRouteAccepts() throws {
        let parsed = try XCTUnwrap(watch(["sh", "-c", "exit 7"]))
        for state: SignalCommand.Watch.State in [.running, .exited(0), .exited(7), .signaled(15)] {
            let report = try report(parsed.post(state, pid: 99, directory: "/Users/me/p", home: "/Users/me"))
            XCTAssertEqual(report.id, "watch-99")
            XCTAssertEqual(report.label, "sh -c exit 7")
            XCTAssertEqual(report.sender, "sh")
        }
        let failed = try report(parsed.post(.exited(7), pid: 99, directory: "/Users/me/p", home: "/Users/me"))
        XCTAssertEqual(failed.word, .failed)
        XCTAssertEqual(failed.detail, "exit 7 · ~/p")
    }

    // MARK: - signal

    func testSignalDefaults() throws {
        let working = try XCTUnwrap(post(["build"]))
        XCTAssertEqual(working.id, "build")
        XCTAssertEqual(working.word, .working)
        XCTAssertEqual(working.ttl, 900)
        XCTAssertEqual(post(["build", "--waiting"])?.ttl, 900)
        XCTAssertEqual(post(["build", "--waiting"])?.word, .waiting)
        XCTAssertEqual(post(["build", "--done"])?.word, .done)
        XCTAssertEqual(post(["build", "--done"])?.ttl, 600)
        XCTAssertEqual(post(["build", "--failed"])?.word, .failed)
        XCTAssertEqual(post(["build", "--failed"])?.ttl, 600)
        let clear = try XCTUnwrap(post(["build", "--clear"]))
        XCTAssertEqual(clear.ttl, 0)
        XCTAssertNil(clear.word)
    }

    func testSignalFlags() throws {
        let full = try XCTUnwrap(post(["render-1", "--label", "Render", "--progress", "0.4",
                                       "--detail", "frame 40/100", "--sender", "blender", "--ttl", "120"]))
        let report = try report(full)
        XCTAssertEqual(report.id, "render-1")
        XCTAssertEqual(report.word, .working)
        XCTAssertEqual(report.ttl, 120)
        XCTAssertEqual(report.label, "Render")
        XCTAssertEqual(report.progress, 0.4)
        XCTAssertEqual(report.detail, "frame 40/100")
        XCTAssertEqual(report.sender, "blender")
        // Flags may come before the id too.
        XCTAssertEqual(post(["--done", "build"])?.word, .done)
        let cleared = try self.report(XCTUnwrap(post(["build", "--clear"])))
        XCTAssertEqual(cleared.ttl, 0)
        // An id may start with `-`, as the route allows: after `--`.
        XCTAssertEqual(post(["--done", "--", "-nightly"])?.id, "-nightly")
        refused(["signal", "--", "-nightly", "--done"])   // after -- nothing is a flag: two ids
    }

    func testSignalArgumentErrors() {
        refused(["signal"])
        refused(["signal", "bad id"])
        refused(["signal", "a:b"])
        refused(["signal", "x", "y"])
        refused(["signal", "x", "--progress", "1.5"])
        refused(["signal", "x", "--progress", "nan"])
        refused(["signal", "x", "--progress"])
        refused(["signal", "x", "--ttl", "-1"])
        refused(["signal", "x", "--ttl", "86401"])
        refused(["signal", "x", "--ttl", "1.5"])
        refused(["signal", "x", "--done", "--failed"])
        refused(["signal", "x", "--clear", "--label", "y"])
        refused(["signal", "x", "--bogus"])
    }

    func testHelpIsAskedForAndNotAnError() {
        XCTAssertEqual(parsed(["signal", "--help"]), .help)
        XCTAssertEqual(parsed(["watch", "-h"]), .help)
        // After the command it is the command's.
        XCTAssertEqual(watch(["ls", "--help"])?.command, ["ls", "--help"])
        XCTAssertFalse(SignalCommand.usage.isEmpty)
        XCTAssertEqual(SignalCommand.usageExitCode, 2)
    }
}
