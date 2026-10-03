import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// The kit Evlat makes for a Docker sandbox, as installed: the hook command
/// inside it, the managed settings that carry the command, and the kit's
/// `spec.yaml`. Once a sandbox is made with the kit these bytes live in it,
/// and nothing on this Mac can change them there: a change is a new
/// version, which the hook says in `X-Evlat-Kit`.
final class SandboxKitTests: XCTestCase {
    // MARK: - The command

    /// The Mac's command's twin: the VM's way to this Mac, the sandbox's own
    /// name and the kit's version; no `$PPID` and no task, which would speak
    /// about the VM.
    func testTheSandboxCommandIsUnchanged() {
        XCTAssertEqual(
            LocalAPI.installedHookCommand(for: .claude, endpoint: .sandbox(port: SandboxKit.defaultPort)),
            "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true")
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
        XCTAssertFalse(command.contains("127.0.0.1"), "the VM's own loopback is not this Mac's")
    }

    /// The header names the command sends are the ones the parser reads.
    func testTheSandboxCommandSendsTheHeadersTheServerReads() throws {
        let command = LocalAPI.installedHookCommand(for: .claude, endpoint: .sandbox(port: 48152))
        XCTAssertTrue(command.contains("X-Evlat-Sandbox: ${SANDBOX_NAME:-}"))
        XCTAssertTrue(command.contains("X-Evlat-Kit: \(SandboxKit.version)"))
        let request = try XCTUnwrap(HTTPRequest.parse(Data(
            "POST /hook HTTP/1.1\r\nX-Evlat-Sandbox: claude-evlat\r\nX-Evlat-Kit: \(SandboxKit.version)\r\n\r\n".utf8)))
        XCTAssertEqual(request.sandboxName, "claude-evlat")
        XCTAssertEqual(request.kitVersion, "\(SandboxKit.version)")
    }

    // MARK: - The kit

    /// Claude Code's managed settings: every event the Mac installs, each
    /// with the sandbox's command, in the shape `HookSettings` writes.
    func testTheManagedSettingsCarryEveryEventWithTheSandboxCommand() throws {
        let kit = Agents.sandboxKit()
        XCTAssertEqual(kit.port, SandboxKit.defaultPort)
        let install = try XCTUnwrap(kit.installs.first)
        XCTAssertEqual(kit.installs.count, 1)
        XCTAssertEqual(install.path, "/etc/claude-code/managed-settings.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(install.content.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(AgentID.claude.agent.hooks.events))
        let command = LocalAPI.installedHookCommand(for: .claude, endpoint: .sandbox(port: kit.port))
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
    /// network rule, so one kit never speaks to a port it may not reach.
    func testThePortReachesTheCommandAndTheRule() {
        let kit = Agents.sandboxKit(port: 50001)
        XCTAssertTrue(kit.installs[0].content.contains("http://host.docker.internal:50001/hook"))
        XCTAssertTrue(kit.spec.contains("      - localhost:50001\n"))
        XCTAssertFalse(kit.spec.contains("48152"))
    }

    /// The whole of `spec.yaml` as a sandbox gets it. A failing comparison
    /// is a contract change: every sandbox made with the old bytes keeps
    /// them, so the new bytes get a new `SandboxKit.version` (which this
    /// string carries twice: in its header and in the hook's `X-Evlat-Kit`).
    func testTheSpecIsUnchanged() {
        XCTAssertEqual(Agents.sandboxKit().spec, Self.spec)
        XCTAssertEqual(Agents.sandboxKit().files, [SandboxKit.File(path: "spec.yaml", content: Self.spec)])
    }

    private static let spec = #"""
        # evlat-sandbox-kit
        # version 1
        #
        # Made by Evlat: it lets the agent in this sandbox tell Evlat on the
        # Mac what it is doing. Evlat writes this folder again as it needs to,
        # so an edit here is lost.
        schemaVersion: "2"
        kind: mixin
        name: evlat
        displayName: Evlat
        description: "Sends the agent's hook events to Evlat on the Mac"
        permissions:
          network:
            allow:
              - localhost:48152
        setup:
          install:
            - description: "Write /etc/claude-code/managed-settings.json"
              command: |
                mkdir -p '/etc/claude-code' && cat > '/etc/claude-code/managed-settings.json' <<'EVLAT_KIT'
                {
                  "hooks" : {
                    "Notification" : [
                      {
                        "hooks" : [
                          {
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
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
                            "command" : "curl -s -m 2 -X POST -H 'Content-Type: application/json' -H \"X-Evlat-Sandbox: ${SANDBOX_NAME:-}\" -H 'X-Evlat-Kit: 1' --data-binary @- http://host.docker.internal:48152/hook >/dev/null 2>&1 || true",
                            "timeout" : 5,
                            "type" : "command"
                          }
                        ]
                      }
                    ]
                  }
                }
                EVLAT_KIT

        """#
}
