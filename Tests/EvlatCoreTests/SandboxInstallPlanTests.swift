import XCTest
@testable import EvlatCore

/// The `sbx` commands that set a sandbox up and take it out again, whatever
/// file is installed: the rule always scoped to the sandbox, the content on
/// stdin, the name checked before it enters an argument. What Claude Code
/// gets is pinned with the agents (`EvlatAgentsTests.SandboxInstallTests`).
final class SandboxInstallPlanTests: XCTestCase {
    private static let content = """
        {
          "quote" : "it's $HOME and `id` and \\"x\\"",

          "end" : true
        }
        """

    private let install = SandboxInstall(port: 50002, path: "/etc/x/y.d/evlat.json", content: content)

    func testThePortIsTheMainOnePlusOne() {
        XCTAssertEqual(SandboxInstall.defaultPort, LocalAPI.defaultPort + 1)
        XCTAssertEqual(SandboxInstall(path: "/a", content: "").port, SandboxInstall.defaultPort)
    }

    /// The rule, then the file, written beside itself and moved into place.
    func testTheInstallCommandsAreUnchanged() throws {
        let commands = try XCTUnwrap(install.install(sandbox: "claude-evlat"))
        XCTAssertEqual(commands, [
            SandboxInstall.Command(arguments: ["policy", "allow", "network", "--sandbox", "claude-evlat",
                                               "localhost:50002"]),
            SandboxInstall.Command(arguments: [
                "exec", "-i", "-u", "root", "claude-evlat", "sh", "-c",
                "mkdir -p '/etc/x/y.d' && cat > '/etc/x/y.d/evlat.json.tmp.'$$"
                    + " && mv -f '/etc/x/y.d/evlat.json.tmp.'$$ '/etc/x/y.d/evlat.json'",
            ], input: Self.content),
        ])
    }

    /// Evlat's file alone, then the sandbox's rule, with no question asked.
    func testTheUninstallCommandsAreUnchanged() throws {
        XCTAssertEqual(try XCTUnwrap(install.uninstall(sandbox: "claude-evlat")), [
            SandboxInstall.Command(arguments: ["exec", "-u", "root", "claude-evlat", "rm", "-f",
                                               "/etc/x/y.d/evlat.json"]),
            SandboxInstall.Command(arguments: ["policy", "rm", "network", "--sandbox", "claude-evlat",
                                               "--resource", "localhost:50002", "--force"]),
        ])
    }

    /// Without `--sandbox` a rule goes into the global policy, open to every
    /// sandbox on the Mac; the content is never an argument.
    func testEveryRuleNamesItsSandboxAndTheContentGoesOnStdin() throws {
        let commands = try XCTUnwrap(install.install(sandbox: "s")) + XCTUnwrap(install.uninstall(sandbox: "s"))
        for command in commands where command.arguments.first == "policy" {
            let flag = try XCTUnwrap(command.arguments.firstIndex(of: "--sandbox"))
            XCTAssertEqual(command.arguments[flag + 1], "s")
        }
        XCTAssertTrue(commands.contains { $0.arguments.starts(with: ["policy", "rm"]) && $0.arguments.last == "--force" })
        XCTAssertFalse(commands.flatMap(\.arguments).contains { $0.contains("\"end\"") })
        XCTAssertEqual(commands.compactMap(\.input), [Self.content])
    }

    /// The temporary file is not a `*.json`, so the folder's reader never
    /// sees half of it, and it is the run's own (`$$`), so two runs at
    /// once never write into one.
    func testTheTemporaryFileIsNotReadAsSettings() throws {
        let script = try XCTUnwrap(install.install(sandbox: "s")?.last?.arguments.last)
        XCTAssertTrue(script.contains("evlat.json.tmp.'$$"))
        XCTAssertFalse(script.contains(".json'$$"))
    }

    /// The write step, run by `sh` as `sbx exec` runs it (the paths moved
    /// into a temporary folder), with the content on stdin: the folder is
    /// made and the file is the content byte for byte, nothing in it
    /// expanded; no temporary file stays behind; a second run replaces it.
    func testTheWriteStepWritesTheContentByteForByte() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("it's here/managed.d/evlat.json").path
        for content in ["old", Self.content] {
            let step = try XCTUnwrap(SandboxInstall(path: path, content: content).install(sandbox: "s")?.last)
            XCTAssertEqual(Array(step.arguments.prefix(7)), ["exec", "-i", "-u", "root", "s", "sh", "-c"])
            let sh = Process()
            let input = Pipe()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-c", try XCTUnwrap(step.arguments.last)]
            sh.standardInput = input
            try sh.run()
            input.fileHandleForWriting.write(Data(try XCTUnwrap(step.input).utf8))
            try input.fileHandleForWriting.close()
            sh.waitUntilExit()
            XCTAssertEqual(sh.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), content)
        }
        let folder = (path as NSString).deletingLastPathComponent
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), ["evlat.json"])
    }

    // MARK: - Names

    /// A name from the daemon goes into an argument vector only if `sbx`
    /// cannot take it for a flag or anything but one word.
    func testANameIsCheckedBeforeAnyCommandIsMade() {
        let good = ["a", "claude-evlat", "Evlat_2.x", "0", String(repeating: "a", count: 64)]
        let bad = ["", "-rf", "--sandbox", ".hidden", "_x", "a b", "a/b", "a;b", "a\nb", "caf\u{e9}",
                   String(repeating: "a", count: 65)]
        for name in good {
            XCTAssertTrue(SandboxInstall.isSandboxName(name), name)
            XCTAssertNotNil(install.install(sandbox: name), name)
        }
        for name in bad {
            XCTAssertFalse(SandboxInstall.isSandboxName(name), name)
            XCTAssertNil(install.install(sandbox: name), name)
            XCTAssertNil(install.uninstall(sandbox: name), name)
        }
    }

    // MARK: - The list

    /// `sbx ls --json` as 0.46.0 prints it.
    func testTheListIsRead() throws {
        XCTAssertEqual(SandboxInstall.list.arguments, ["ls", "--json"])
        XCTAssertNil(SandboxInstall.list.input)
        let data = Data("""
            {
              "sandboxes": [
                {
                  "name": "evlat-p4",
                  "id": "fd8db953-d61f-4ae6-8484-b08a15d88692",
                  "agent": "claude",
                  "status": "running",
                  "last_used_at": "2026-10-03T11:18:38.461091Z",
                  "workspaces": ["/private/tmp/w"],
                  "created_at": "2026-10-03T11:18:34Z"
                },
                {"name": "sh", "agent": "shell", "status": "stopped"},
                {"name": "bare"},
                {"agent": "claude", "status": "running"},
                "noise"
              ]
            }
            """.utf8)
        let sandboxes = try XCTUnwrap(SandboxInstall.sandboxes(fromList: data))
        XCTAssertEqual(sandboxes, [
            SandboxInstall.Sandbox(name: "evlat-p4", agent: "claude", status: "running", workspace: "/private/tmp/w"),
            SandboxInstall.Sandbox(name: "sh", agent: "shell", status: "stopped"),
            SandboxInstall.Sandbox(name: "bare", agent: nil, status: nil),
        ])
        XCTAssertEqual(sandboxes.map(\.isRunning), [true, false, false])
        XCTAssertEqual(SandboxInstall.sandboxes(fromList: Data(#"{"sandboxes": []}"#.utf8)), [])
        XCTAssertNil(SandboxInstall.sandboxes(fromList: Data("[]".utf8)))
        XCTAssertNil(SandboxInstall.sandboxes(fromList: Data("no".utf8)))
    }

    /// `sbx version`'s line as 0.46.0 printed it; anything else is no version.
    func testTheVersionIsReadFromSbxsLine() {
        XCTAssertEqual(SandboxInstall.version.arguments, ["version"])
        XCTAssertNil(SandboxInstall.version.input)
        let line = "sbx version: v0.46.0 991967dc90ce0d9a440cd1df1bdf3e395c5a2693\n"
        XCTAssertEqual(SandboxInstall.version(fromOutput: Data(line.utf8)), "0.46.0")
        XCTAssertEqual(SandboxInstall.version(fromOutput: Data("sbx version: v1.2.10\n".utf8)), "1.2.10")
        XCTAssertNil(SandboxInstall.version(fromOutput: Data("sbx version: vnext\n".utf8)))
        XCTAssertNil(SandboxInstall.version(fromOutput: Data("v1.2 v1..3 v1.2.x".utf8)))
        XCTAssertNil(SandboxInstall.version(fromOutput: Data()))
        XCTAssertEqual(SandboxInstall.measuredVersion, "0.46.0")
    }
}
