import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp
@testable import EvlatAgents

/// A Docker sandbox's session on this Mac: its `sbx` client found by name
/// and start (`Sandbox`, `StartMatch`), its card (`DetailModel`), its
/// and its listener (`SandboxListener`).
/// The chain is the one measured on sbx 0.46.0:
/// `sbx run --name evlat-hook … claude → -zsh → login → Bateri`.
@MainActor
final class SandboxTests: XCTestCase {
    struct Proc {
        let parent: Int32
        let path: String?
        var app: SessionHost.App? = nil
        var arguments: [String] = []
        var terminal: Bool? = true
        var cwd: String? = nil
        var started: TimeInterval? = nil
        var environment: [String] = []
    }

    static let sbx = "/opt/homebrew/bin/sbx"
    static let bateriPath = "/Applications/Bateri.app/Contents/MacOS/bateri"
    nonisolated static let start: TimeInterval = 1_790_990_000
    let bateri = SessionHost.App(bundleID: "dev.bateri.bateri", name: "Bateri", pid: 580)
    let metalterm = SessionHost.App(bundleID: "dev.metalterm.Metalterm", name: "Metalterm", pid: 500)

    static func tab(_ id: String) -> [String] { ["BATERI_TAB_URL=bateri://tab/\(id)"] }
    /// A tab id as Bateri makes them: a UUID, here one per client.
    static func tabID(_ pid: Int32) -> String { String(format: "00000000-0000-4000-8000-%012d", pid) }

    func probe(_ table: [Int32: Proc]) -> SessionHost.Probe {
        SessionHost.Probe(parent: { table[$0]?.parent },
                          regularApp: { table[$0]?.app },
                          executablePath: { table[$0]?.path },
                          bundle: { _ in nil },
                          running: { _ in nil },
                          environment: { table[$0]?.environment ?? [] },
                          arguments: { table[$0]?.arguments ?? [] },
                          processes: { Array(table.keys) },
                          hasTerminal: { table[$0]?.terminal ?? nil },
                          startedAt: { table[$0]?.started.map(Date.init(timeIntervalSince1970:)) },
                          currentDirectory: { table[$0]?.cwd })
    }

    /// The daemon, and a client of `evlat-hook` in a Bateri tab started
    /// `offset` before the session.
    func client(_ pid: Int32, offset: TimeInterval = 2, shell: Int32, app: Int32 = 580,
                arguments: [String] = ["sbx", "run", "--name", "evlat-hook", "claude"],
                tab: String? = nil) -> [Int32: Proc] {
        [pid: Proc(parent: shell, path: Self.sbx, arguments: arguments, started: Self.start - offset,
                   environment: Self.tab(tab ?? Self.tabID(pid))),
         shell: Proc(parent: app, path: "/bin/zsh")]
    }

    var base: [Int32: Proc] {
        [77946: Proc(parent: 1, path: Self.sbx, arguments: ["sbx", "daemon", "start"], terminal: false),
         580: Proc(parent: 1, path: Self.bateriPath, app: bateri),
         500: Proc(parent: 1, path: "/Applications/Metalterm.app/Contents/MacOS/Metalterm", app: metalterm)]
    }

    func table(_ parts: [Int32: Proc]...) -> [Int32: Proc] {
        parts.reduce(base) { $0.merging($1) { a, _ in a } }
    }

    func resolve(_ table: [Int32: Proc], name: String? = "evlat-hook",
                 start: TimeInterval? = SandboxTests.start) -> Sandbox.Found {
        Sandbox.resolve(name: name, start: start.map(Date.init(timeIntervalSince1970:)), probe(table))
    }

    func tab(_ found: Sandbox.Found) -> String? {
        guard case .host(.app(let app)) = found else { return nil }
        return app.tab?.absoluteString
    }

    // MARK: - The shared start rule

    func testTheStartRuleTable() {
        let at = { (seconds: [Int32: TimeInterval]) in
            { (pid: Int32) in seconds[pid].map { Date(timeIntervalSince1970: 100 + $0) } }
        }
        let rule = Sandbox.rule
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(StartMatch.choose([], start: start, rule: rule, startedAt: at([:])), .none)
        XCTAssertEqual(StartMatch.choose([1], start: start, rule: rule, startedAt: at([1: -14])), .one(1),
                       "alone at 14 s, as creating a sandbox measured")
        XCTAssertEqual(StartMatch.choose([1], start: start, rule: rule, startedAt: at([1: -30])), .one(1),
                       "alone at 30 s: just inside")
        XCTAssertEqual(StartMatch.choose([1], start: start, rule: rule, startedAt: at([1: -40])), .none,
                       "alone past 30 s: not chosen")
        XCTAssertEqual(StartMatch.choose([1], start: start, rule: rule, startedAt: at([:])), .one(1),
                       "alone with a start that cannot be read")
        XCTAssertEqual(Sandbox.rule, StartMatch.Rule(nearest: 5, apart: 10, aloneWithin: 30), "the sandbox's own")
        XCTAssertEqual(StartMatch.choose([1, 2], start: start, rule: rule, startedAt: at([1: -5, 2: -10.5])),
                       .one(1), "5 s and 10.5 s: just inside both")
        XCTAssertEqual(StartMatch.choose([1, 2], start: start, rule: rule, startedAt: at([1: -5.5, 2: -60])),
                       .ambiguous([1, 2]), "nearest past 5 s")
        XCTAssertEqual(StartMatch.choose([1, 2], start: start, rule: rule, startedAt: at([1: -1, 2: -9])),
                       .ambiguous([1, 2]), "the other within 10 s")
        XCTAssertEqual(StartMatch.choose([1, 2], start: start, rule: rule, startedAt: at([1: -1])),
                       .ambiguous([1, 2]), "a start that cannot be read")
        XCTAssertEqual(StartMatch.choose([1, 2], start: nil, rule: rule, startedAt: at([1: -1, 2: -60])),
                       .ambiguous([1, 2]), "no reference start")
        XCTAssertEqual(Ssh.rule, StartMatch.Rule(nearest: 2, apart: 10, aloneWithin: 10), "ssh's own")
    }

    // MARK: - Which clients

    func testTheClientsName() {
        let cwd = { "/Users/u/Projects/ws-probe" as String? }
        func name(_ arguments: [String]) -> String? { Sandbox.clientName(arguments: arguments, directory: cwd) }
        XCTAssertEqual(name(["sbx", "run", "--name", "evlat-hook", "claude"]), "evlat-hook")
        XCTAssertEqual(name(["sbx", "run", "--name=evlat-hook"]), "evlat-hook")
        XCTAssertEqual(name(["/opt/homebrew/bin/sbx", "--debug", "run", "--kit", "/k", "--name", "x", "claude"]), "x")
        XCTAssertEqual(name(["sbx", "run", "shell"]), "shell-ws-probe", "unnamed: <agent>-<folder>")
        XCTAssertEqual(name(["sbx", "run", "--kit", "/a b/kit", "-e", "A=1", "--clone", "claude"]), "claude-ws-probe")
        XCTAssertEqual(name(["sbx", "run", "claude", "--", "--name", "y"]), "claude-ws-probe",
                       "after -- the agent's own arguments")
        XCTAssertNil(name(["sbx", "run", "claude", "../other"]), "a workspace path: not the folder")
        XCTAssertNil(name(["sbx", "run", "./my-kit"]), "a kit reference is no agent word")
        XCTAssertNil(name(["sbx", "run", "--unknown", "claude"]), "an option not read whole")
        XCTAssertNil(name(["sbx", "run"]), "nothing to name it by")
        XCTAssertNil(name(["sbx", "--cloud", "run", "--name", "x"]), "cloud")
        XCTAssertNil(name(["sbx", "run", "--cloud", "--name", "x"]), "cloud")
        XCTAssertNil(name(["sbx", "daemon", "start"]))
        XCTAssertNil(name(["sbx", "exec", "evlat-hook", "env"]))
        XCTAssertNil(Sandbox.clientName(arguments: ["sbx", "run", "shell"], directory: { nil }))
        XCTAssertNil(Sandbox.clientName(arguments: ["sbx", "run", "claude"], directory: { "/Users/u/My Project" }),
                     "a folder no hook name could match")
    }

    /// Only `sbx` clients of that sandbox with a terminal, started no later
    /// than the session.
    func testTheCandidates() {
        var t = table(client(1001, shell: 1000), client(1101, shell: 1100,
                                                        arguments: ["sbx", "run", "--name", "other"]))
        t[1201] = Proc(parent: 1200, path: Self.sbx, arguments: ["sbx", "run", "--name", "evlat-hook"],
                       terminal: false, started: Self.start - 2)
        t[1301] = Proc(parent: 1300, path: Self.sbx, arguments: ["sbx", "run", "--name", "evlat-hook"],
                       started: Self.start + 1)
        t[1401] = Proc(parent: 1400, path: "/usr/bin/env", arguments: ["env", "run", "--name", "evlat-hook"],
                       started: Self.start - 2)
        t[1501] = Proc(parent: 1500, path: Self.sbx, arguments: ["sbx", "run", "claude"],
                       cwd: "/Users/u/evlat-hook", started: Self.start - 2)
        t[1601] = Proc(parent: 1600, path: Self.sbx, arguments: ["sbx", "run", "claude"],
                       cwd: "/Users/u/hook", started: Self.start - 2)
        let start = Date(timeIntervalSince1970: Self.start)
        XCTAssertEqual(Sandbox.candidates(named: "evlat-hook", startedBy: start, probe(t)), [1001])
        XCTAssertEqual(Sandbox.candidates(named: "claude-hook", startedBy: start, probe(t)), [1601],
                       "unnamed, by its folder; exact only")
        XCTAssertEqual(Sandbox.candidates(named: "evlat-hook", startedBy: nil, probe(t)), [1001, 1301],
                       "no start rules nobody out by it")
    }

    /// The real lookup reads this process's own working directory.
    func testTheRealWorkingDirectoryIsRead() {
        XCTAssertEqual(SessionHost.currentDirectory(getpid()).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        XCTAssertNil(SessionHost.currentDirectory(0))
    }

    // MARK: - What the card gets

    func testOneClientIsItsTab() {
        XCTAssertEqual(tab(resolve(table(client(1001, shell: 1000)))), "bateri://tab/\(Self.tabID(1001))")
        XCTAssertEqual(tab(resolve(table(client(1001, offset: 14, shell: 1000)))), "bateri://tab/\(Self.tabID(1001))",
                       "14 s before the session, as creating a sandbox measured")
    }

    /// A lone client 40 s before the session may be an earlier session's:
    /// the app, never its tab, and never no button.
    func testAFarLoneClientBringsTheAppOnly() {
        XCTAssertEqual(resolve(table(client(1001, offset: 40, shell: 1000))), .host(.app(bateri)))
    }

    /// Three clients ~27 s apart, as measured: the one just before the
    /// session; the later one is another session's.
    func testTheStartTellsClientsApart() {
        let t = table(client(1001, offset: 56, shell: 1000), client(1101, offset: 29, shell: 1100),
                      client(1201, offset: 2, shell: 1200), client(1301, offset: -25, shell: 1300))
        XCTAssertEqual(tab(resolve(t)), "bateri://tab/\(Self.tabID(1201))")
    }

    func testCloseClientsInOneAppBringTheAppOnly() {
        let t = table(client(1001, offset: 2, shell: 1000), client(1101, offset: 4, shell: 1100))
        XCTAssertEqual(resolve(t), .host(.app(bateri)))
    }

    func testCloseClientsInTwoAppsFindNothing() {
        let t = table(client(1001, offset: 2, shell: 1000), client(1101, offset: 4, shell: 1100, app: 500))
        XCTAssertEqual(resolve(t), .host(.notFound))
    }

    /// No start heard: even one client may be another session's.
    func testWithoutAStartTheAppAloneWithNoTab() {
        XCTAssertEqual(resolve(table(client(1001, shell: 1000)), start: nil), .host(.app(bateri)))
    }

    func testNoClientIsNoTerminal() {
        XCTAssertEqual(resolve(base), .noTerminal)
        XCTAssertEqual(resolve(table(client(1001, offset: -5, shell: 1000))), .noTerminal,
                       "the only client started after the session")
        XCTAssertEqual(resolve(table(client(1001, shell: 1000)), name: nil), .host(.notFound),
                       "a row that names no sandbox says nothing")
        var unread = table(client(1001, shell: 1000, arguments: ["sbx", "run", "claude"]))
        unread[1001]?.cwd = "/Users/u/My Project"
        XCTAssertEqual(resolve(unread), .host(.notFound), "a client whose sandbox cannot be read may be it")
        XCTAssertEqual(resolve(table(client(1001, shell: 1000, arguments: ["sbx", "run", "--unknown", "claude"]))),
                       .host(.notFound), "an option not read whole: no claim either way")
        XCTAssertEqual(resolve(table(client(1001, shell: 1000, arguments: ["sbx", "run", "--name", "other"]))),
                       .noTerminal, "another sandbox's client is no doubt")
    }

    // MARK: - The card

    private let sandboxSession = "6c1f0e4e-0000-4000-8000-000000000001"

    private func sandboxSignal(start: Date? = Date(timeIntervalSince1970: SandboxTests.start)) -> Signal {
        Signal(provider: "hooks", entity: "remote:\(SandboxListener.identity.id):\(sandboxSession)",
               phase: .waiting, label: "evlat", detail: "/Users/u/evlat", source: AgentID("claude"),
               fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0),
               activity: Signal.Activity(sandboxName: "evlat-hook", sessionStartedAt: start),
               machine: Signal.Machine(name: "evlat-hook", id: SandboxListener.identity.id))
    }

    /// Looked up on this Mac, once per card and again when its start
    /// arrives; never asked of a server, though its agent keeps records.
    func testASandboxCardLooksUpItsClientNotAServer() throws {
        let model = DetailModel()
        var asked = 0
        var lookups: [(String?, Date?)] = []
        model.findRemote = { _, _ in asked += 1; return true }
        model.resolveSandbox = { name, start in
            lookups.append((name, start))
            return .host(.app(self.bateri))
        }
        let early = sandboxSignal(start: nil)
        model.update(row: SessionRow(early), signal: early)
        let signal = sandboxSignal()
        model.update(row: SessionRow(signal), signal: signal)
        model.update(row: SessionRow(signal), signal: signal)
        XCTAssertEqual(asked, 0, "no ssh query")
        XCTAssertEqual(lookups.map(\.0), ["evlat-hook", "evlat-hook"])
        XCTAssertEqual(lookups.map(\.1), [nil, Date(timeIntervalSince1970: Self.start)])
        let detail = try XCTUnwrap(model.detail)
        XCTAssertTrue(detail.hasSandboxHost)
        XCTAssertFalse(detail.hasRemoteHost)
        XCTAssertTrue(DetailCard.showsButton(detail))
        XCTAssertEqual(DetailCard.footerPlace(detail), "Bateri")

        var activated: [SessionHost.App] = []
        model.activate = { activated.append($0); return true }
        XCTAssertTrue(model.go())
        XCTAssertEqual(lookups.count, 3, "looked up again at the click")
        XCTAssertEqual(activated, [bateri])
    }

    func testASandboxCardWithNoClientSaysSoAndHasNoButton() throws {
        let model = DetailModel()
        model.resolveSandbox = { _, _ in .noTerminal }
        let signal = sandboxSignal()
        model.update(row: SessionRow(signal), signal: signal)
        var detail = try XCTUnwrap(model.detail)
        XCTAssertTrue(detail.noTerminalOpen)
        XCTAssertFalse(DetailCard.showsButton(detail))
        XCTAssertEqual(DetailCard.footerPlace(detail, in: "en"), "No terminal open")
        XCTAssertFalse(model.go())

        model.resolveSandbox = { _, _ in .host(.notFound) }
        model.cardClosed()
        model.update(row: SessionRow(signal), signal: signal)
        detail = try XCTUnwrap(model.detail)
        XCTAssertFalse(detail.noTerminalOpen)
        XCTAssertFalse(DetailCard.showsButton(detail), "two apps: no button, no words")
        XCTAssertNil(DetailCard.footerPlace(detail))
    }

    // MARK: - The listener and its sets

    func testASandboxsRowsAnswerToThisMacsSwitches() {
        let local: Set<AgentID> = [AgentID("codex")]
        var remoteAsked: [String] = []
        let remote = { (id: String) -> Set<AgentID>? in remoteAsked.append(id); return [AgentID("claude")] }
        XCTAssertEqual(AppController.machineSources(SandboxListener.identity.id, local: { local }, remote: remote),
                       local)
        XCTAssertEqual(remoteAsked, [])
        XCTAssertEqual(AppController.machineSources("m-1", local: { local }, remote: remote), [AgentID("claude")])
        XCTAssertNotNil(RemoteMachine.validate(target: SandboxListener.identity.id),
                        "no machine can have the sandbox's id")

        let controller = AppController()
        controller.wireMachineSources()
        XCTAssertEqual(controller.registry.machineSources(SandboxListener.identity.id), controller.enabledAgents)
        XCTAssertNil(controller.registry.machineSources("m-1"), "no tunnels: every agent")
    }

    func testIsolation() {
        XCTAssertEqual(SandboxListener.port(environment: [:]), SandboxInstall.defaultPort)
        XCTAssertNil(SandboxListener.port(environment: ["EVLAT_PORT": "48999"]), "isolated: no listener")
        XCTAssertEqual(SandboxListener.port(environment: ["EVLAT_PORT": "48999", "EVLAT_SANDBOX_PORT": "48998"]),
                       48998)
        XCTAssertNil(SandboxListener.port(environment: ["EVLAT_SANDBOX_PORT": "0"]))
        XCTAssertNil(SandboxListener.port(environment: ["EVLAT_SANDBOX_PORT": "x"]))


        XCTAssertNil(AppController().sandbox, "nothing listens until launched")
    }

    /// The real socket, on a free port: a hook with the sandbox's header is
    /// a row drawn with the sandbox's name, in its own namespace, and not
    /// dimmed while the listener listens.
    func testTheListenerDrawsASandboxsHook() throws {
        let controller = AppController()
        controller.startSandboxListener(port: 0)
        let sandbox = try XCTUnwrap(controller.sandbox)
        defer { sandbox.stop() }
        let listening = expectation(for: NSPredicate { _, _ in sandbox.boundPort != nil }, evaluatedWith: nil)
        wait(for: [listening], timeout: 5)
        let port = try XCTUnwrap(sandbox.boundPort)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook/claude")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("evlat-hook", forHTTPHeaderField: "X-Evlat-Sandbox")
        request.setValue("446", forHTTPHeaderField: "X-Evlat-Pid")
        request.httpBody = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s-1","cwd":"/Users/u/evlat","tool_name":"Bash"}"#.utf8)
        let answered = expectation(description: "answer")
        URLSession.shared.dataTask(with: request) { _, _, _ in answered.fulfill() }.resume()
        wait(for: [answered], timeout: 5)
        let drawn = expectation(for: NSPredicate { _, _ in !sandbox.hooks.currentSignals().isEmpty },
                                evaluatedWith: nil)
        wait(for: [drawn], timeout: 5)

        let row = try XCTUnwrap(controller.registry.signals().first { $0.entity.hasSuffix(":s-1") })
        XCTAssertEqual(row.entity, "remote:\(SandboxListener.identity.id):s-1")
        XCTAssertEqual(row.machine?.name, "evlat-hook", "the header reached the row")
        XCTAssertEqual(row.machine?.id, SandboxListener.identity.id)
        XCTAssertNil(row.machine?.dim, "listening: not dimmed")
        XCTAssertNil(row.activity?.pid, "the VM's pid is not this Mac's")
        XCTAssertEqual(row.phase, .waiting)
        XCTAssertEqual(sandbox.status.heard, ["evlat-hook"])
        XCTAssertEqual(sandbox.status.listener, .listening(port))
    }

    /// End to end: a sandbox's row, heard on the real socket, leaves the bar
    /// when its agent is switched off in Settings → Agents — this Mac's
    /// switch, since the agent runs here — and comes back when it is on.
    func testASandboxsRowHidesWhenItsAgentIsSwitchedOff() throws {
        let controller = AppController()
        controller.applyEnabledAgents()
        controller.startSandboxListener(port: 0)
        let sandbox = try XCTUnwrap(controller.sandbox)
        defer { sandbox.stop() }
        let listening = expectation(for: NSPredicate { _, _ in sandbox.boundPort != nil }, evaluatedWith: nil)
        wait(for: [listening], timeout: 5)
        let port = try XCTUnwrap(sandbox.boundPort)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook/claude")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("evlat-hook", forHTTPHeaderField: "X-Evlat-Sandbox")
        request.httpBody = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s-2","cwd":"/Users/u/evlat"}"#.utf8)
        let answered = expectation(description: "answer")
        URLSession.shared.dataTask(with: request) { _, _, _ in answered.fulfill() }.resume()
        wait(for: [answered], timeout: 5)
        let drawn = expectation(for: NSPredicate { _, _ in !sandbox.hooks.currentSignals().isEmpty },
                                evaluatedWith: nil)
        wait(for: [drawn], timeout: 5)

        let entity = "remote:\(SandboxListener.identity.id):s-2"
        let row = try XCTUnwrap(controller.registry.signals().first { $0.entity == entity }, "on: drawn")
        let agent = try XCTUnwrap(row.source)
        XCTAssertEqual(row.phase, .working)

        controller.setEnabled(agent, false)
        XCTAssertFalse(controller.enabledAgents.contains(agent))
        XCTAssertNil(controller.registry.signals().first { $0.entity == entity }, "off: hidden")
        XCTAssertFalse(sandbox.hooks.currentSignals().isEmpty, "hidden, not forgotten")

        controller.setEnabled(agent, true)
        XCTAssertNotNil(controller.registry.signals().first { $0.entity == entity }, "on again: back")
    }
}
