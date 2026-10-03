import XCTest
@testable import EvlatCore

/// The kit's own rules, whatever is installed with it: marked and
/// versioned, the port in its network rule, and a step that writes each
/// install's content byte for byte. What Claude Code gets is pinned with
/// the agents (`EvlatAgentsTests.SandboxKitTests`).
final class SandboxKitScriptTests: XCTestCase {
    private static let content = """
        {
          "quote" : "it's $HOME and `id` and \\"x\\"",

          "end" : true
        }
        """

    func testTheSpecIsMarkedVersionedAndMadeFromTheConstants() {
        let kit = SandboxKit(port: 50002, installs: [SandboxKit.Install(path: "/etc/x/y.json", content: "{}")])
        let lines = kit.spec.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(String(lines[0]), SandboxKit.marker)
        XCTAssertEqual(String(lines[1]), "# version \(SandboxKit.version)")
        XCTAssertTrue(kit.spec.contains("name: \(SandboxKit.name)\n"))
        XCTAssertTrue(kit.spec.contains("      - localhost:50002\n"))
        XCTAssertTrue(kit.spec.hasSuffix("\n"))
        XCTAssertEqual(SandboxKit.defaultPort, LocalAPI.defaultPort + 1)
        XCTAssertEqual(SandboxKit(installs: []).port, SandboxKit.defaultPort)
        XCTAssertEqual(kit.files.map(\.path), ["spec.yaml"])
    }

    /// The step, run by `sh` as the kit runs it (with the path moved into a
    /// temporary folder): the folder is made and the file is the content,
    /// nothing in it expanded — a quote, a `$`, a backtick, a blank line.
    func testTheStepWritesTheContentByteForByte() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("it's here/managed.json").path
        let step = SandboxKit.command(writing: SandboxKit.Install(path: path, content: Self.content))
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", step]
        try sh.run()
        sh.waitUntilExit()
        XCTAssertEqual(sh.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), Self.content + "\n")
    }

    /// In the YAML the step is a literal block: every line of it, the
    /// content's included, indented the same, so the block gives it back.
    func testTheStepIsALiteralBlockInTheSpec() {
        let install = SandboxKit.Install(path: "/etc/x/y.json", content: Self.content)
        let spec = SandboxKit(installs: [install]).spec
        let block = SandboxKit.command(writing: install).split(separator: "\n", omittingEmptySubsequences: false)
            .map { "        " + $0 }.joined(separator: "\n")
        XCTAssertTrue(spec.contains("    - description: \"Write /etc/x/y.json\"\n      command: |\n" + block + "\n"))
    }
}
