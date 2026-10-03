import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// What Evlat writes into a Docker sandbox, as installed: the hook command
/// inside it and the managed settings file that carries the command. A
/// running sandbox keeps these bytes until Evlat writes them again, and a
/// stopped one keeps them for good: a failing golden string here is a
/// contract change.
final class SandboxInstallTests: XCTestCase {
    // MARK: - The command

    /// The Mac's command's twin: the VM's way to this Mac and the
    /// sandbox's own name; no `$PPID` and no task, which would speak about
    /// the VM.
    func testTheSandboxCommandIsUnchanged() {
        XCTAssertEqual(
            LocalAPI.installedHookCommand(for: .claude, endpoint: .sandbox(port: SandboxInstall.defaultPort)),
            "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true")
    }

    /// The endpoint's default is the Mac's bytes, unchanged
    /// (`LocalAPITests.testTheInstalledHookCommandIsUnchanged` pins them).
    func testTheLocalEndpointIsTheInstalledCommand() {
        for agent in Agents.all {
            XCTAssertEqual(LocalAPI.installedHookCommand(for: agent, endpoint: .local),
                           LocalAPI.installedHookCommand(for: agent), agent.id.rawValue)
        }
    }

    /// Silent as the Mac's: `-m 2`, nothing on stdout, never a failed hook.
    /// And through the VM's proxy: a `--noproxy` would never reach the Mac.
    func testTheSandboxCommandFailsSilentlyThroughTheProxy() {
        let command = LocalAPI.installedHookCommand(for: .claude, endpoint: .sandbox(port: 48152))
        XCTAssertTrue(command.contains("-m 2"))
        XCTAssertTrue(command.hasSuffix(" >/dev/null 2>&1 || true"))
        XCTAssertFalse(command.contains("noproxy"))
        XCTAssertFalse(command.contains("$PPID"), "the VM's pid names no process here")
        XCTAssertFalse(command.contains("X-Evlat-Task"))
        XCTAssertFalse(command.contains("X-Evlat-Kit"), "there is no kit")
        XCTAssertFalse(command.contains("127.0.0.1"), "the VM's own loopback is not this Mac's")
    }

    /// The header the command sends is the one the parser reads.
    func testTheSandboxCommandSendsTheHeaderTheServerReads() throws {
        let command = LocalAPI.installedHookCommand(for: .claude, endpoint: .sandbox(port: 48152))
        XCTAssertTrue(command.contains("X-Evlat-Sandbox: ${SANDBOX_NAME:-}"))
        let request = try XCTUnwrap(HTTPRequest.parse(Data(
            "POST /hook HTTP/1.1\r\nX-Evlat-Sandbox: claude-evlat\r\n\r\n".utf8)))
        XCTAssertEqual(request.sandboxName, "claude-evlat")
    }

    // MARK: - The file

    /// Claude Code's own file in `managed-settings.d`, never
    /// `managed-settings.json`: every event the Mac installs, each with the
    /// sandbox's command, in the shape `HookSettings` writes.
    func testTheManagedSettingsCarryEveryEventWithTheSandboxCommand() throws {
        let install = Agents.sandboxInstall()
        XCTAssertEqual(install.port, SandboxInstall.defaultPort)
        XCTAssertEqual(install.path, "/etc/claude-code/managed-settings.d/evlat.json")
        XCTAssertEqual(Agents.sandboxAgent, .claude)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(install.content.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(AgentID.claude.agent.hooks.events))
        let command = LocalAPI.installedHookCommand(for: .claude, endpoint: .sandbox(port: install.port))
        for (event, groups) in hooks {
            let entries = (groups as? [[String: Any]])?.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(entries?.count, 1, event)
            XCTAssertEqual(entries?.first?["type"] as? String, "command", event)
            XCTAssertEqual(entries?.first?["command"] as? String, command, event)
            XCTAssertEqual(entries?.first?["timeout"] as? Int, 5, event)
        }
        XCTAssertEqual(Set(json.keys), ["hooks"], "nothing but hooks: the sandbox's own settings stay its own")
    }

    /// A port other than the default reaches both the command and the
    /// network rule, so one sandbox never speaks to a port it may not reach.
    func testThePortReachesTheCommandAndTheRule() throws {
        let install = Agents.sandboxInstall(port: 50001)
        XCTAssertTrue(install.content.contains("http://host.docker.internal:50001/hook"))
        XCTAssertFalse(install.content.contains("48152"))
        let rule = try XCTUnwrap(install.install(sandbox: "s")?.first)
        XCTAssertEqual(rule.arguments.last, "localhost:50001")
    }

    /// The whole file as a sandbox gets it, on stdin.
    func testTheManagedSettingsAreUnchanged() throws {
        XCTAssertEqual(Agents.sandboxInstall().content, Self.managedSettings)
        let write = try XCTUnwrap(Agents.sandboxInstall().install(sandbox: "claude-evlat")?.last)
        XCTAssertEqual(write.input, Self.managedSettings)
    }

    private static let managedSettings = #"""
        {
          "hooks" : {
            "Notification" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "PermissionDenied" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "PermissionRequest" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "PostToolUse" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "PostToolUseFailure" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "PreToolUse" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "SessionEnd" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "SessionStart" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "Stop" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "StopFailure" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ],
            "UserPromptSubmit" : [
              {
                "hooks" : [
                  {
                    "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                    "timeout" : 5,
                    "type" : "command"
                  }
                ]
              }
            ]
          }
        }
        """#
}
