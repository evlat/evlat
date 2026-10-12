import XCTest
import EvlatCore
@testable import EvlatApp
@testable import EvlatAgents

/// The plugin against the OpenCodes themselves: what only a real one can
/// say — that the file loads, which entry point it calls, what reaches the
/// socket, and what Evlat's own provider makes of it. Skipped unless
/// `make test-opencode` hands it binaries:
///
///     make test-opencode OPENCODE="/path/opencode-1.19.0 /path/opencode-2.0.27" \
///                        OPENCODE_DESKTOP=/Applications/OpenCode.app
///
/// Each runs in a home of its own, behind a fake model (`fake-opencode-model`,
/// so nothing reaches a real one), with the plugin written by the installer
/// the app uses, and Evlat's own `HookListener` at the socket under that
/// home. 1.x runs as `opencode serve` and is driven over its HTTP API; 2.x as
/// its background service and driven by `opencode api`; the desktop app's
/// server module runs under its own Electron-as-Node, as the app starts it.
/// The user's OpenCode, its files and its service are never touched.
///
/// The permission card is held to the same: the listener's approval route
/// feeds Evlat's own `ApprovalStore`, a press on it answers the held request,
/// and OpenCode's side — the file it edits, the dialog it still asks — says
/// whether the answer was applied.
///
/// The versions this was last run on are the ones `OpenCode.measuredVersions`
/// names; a new line is measured here before it is added there.
final class OpenCodeLiveTests: XCTestCase {
    func testThePluginReportsEveryOpenCodeItIsGiven() throws {
        let environment = ProcessInfo.processInfo.environment
        let binaries = (environment["OPENCODE"] ?? "").split(separator: " ").map(String.init)
        let desktop = environment["OPENCODE_DESKTOP"].flatMap { $0.isEmpty ? nil : $0 }
        guard !binaries.isEmpty || desktop != nil else {
            throw XCTSkip("OPENCODE is not set; `make test-opencode` sets it")
        }
        for binary in binaries {
            try XCTContext.runActivity(named: binary) { _ in try Target.cli(binary).measure() }
        }
        if let desktop {
            try XCTContext.runActivity(named: desktop) { _ in try Target.desktop(desktop).measure() }
        }
    }
}

// MARK: - What is measured

private enum Target {
    case cli(String)
    case desktop(String)

    var name: String {
        switch self {
        case .cli(let path): return (path as NSString).lastPathComponent
        case .desktop: return "desktop"
        }
    }

    func measure() throws {
        let world = try World(target: self)
        defer { world.tearDown() }
        try world.start()
        let scenarios = Scenarios(world: world)
        scenarios.allowed()
        scenarios.rejected()
        scenarios.twoAtOnce()
        scenarios.subagent()
        scenarios.questionThenInterrupt()
        scenarios.failedTurn()
        scenarios.retryingTurn()
        scenarios.cardAllowed()
        scenarios.cardDenied()
        scenarios.cardLetGo()
        scenarios.cardAnsweredInOpenCode()
        scenarios.twoCards()
        scenarios.subagentCard()
        scenarios.otherFolder()
        scenarios.evlatClosed()
    }
}

private final class Scenarios {
    let world: World
    init(world: World) { self.world = world }

    private func say(_ text: String) -> String { "[\(world.target.name)] \(text)" }

    /// A tool waits for the user, who allows it: working → waiting → working → done.
    func allowed() {
        world.begin("bash please")
        guard world.reach(.waiting) else { return fail("never waited") }
        let row = world.row
        XCTAssertEqual(row?.activity?.blockingTool?.name, "Bash", say("what it waits on"))
        XCTAssertEqual(row?.activity?.blockingTool?.subject, "echo evlat-probe", say("the command, not a guess"))
        XCTAssertEqual(row?.activity?.waitKind, .approval, say("a yes or no"))
        XCTAssertEqual(row?.label, "work", say("named for the session's folder"))
        world.checkProcessAndVersion()
        world.answer(allow: true)
        XCTAssertTrue(world.reach(.review), say("allowed: never finished; \(world.trace)"))
        XCTAssertEqual(world.moves, ["working", "waiting", "working", "review"], say("allowed"))
        XCTAssertEqual(world.mostRows, 1, say("one session, one row"))
    }

    func rejected() {
        world.begin("bash please")
        guard world.reach(.waiting) else { return fail("never waited") }
        world.answer(allow: false)
        XCTAssertTrue(world.reach(.review), say("rejected: never finished; \(world.trace)"))
        XCTAssertEqual(world.moves, ["working", "waiting", "working", "review"], say("rejected"))
    }

    /// One reply, two tool calls, two permissions at once: the row waits
    /// until the last is answered.
    func twoAtOnce() {
        world.begin("two please")
        guard world.reach(.waiting) else { return fail("never waited") }
        let pending = world.driver.pending()
        XCTAssertEqual(pending.count, 2, say("two permissions are open"))
        if let first = pending.first { world.driver.reply(first, allow: true) }
        world.pump(2.5)
        XCTAssertEqual(world.row?.phase, .waiting, say("one answered, one still asked: \(world.trace)"))
        world.answer(allow: true)
        XCTAssertTrue(world.reach(.review), say("two: never finished; \(world.trace)"))
        XCTAssertEqual(world.moves, ["working", "waiting", "working", "review"], say("two"))
    }

    /// A subagent asks: it is the root's row that waits, and the subagent
    /// finishing is not the root finishing.
    func subagent() {
        world.begin("task please")
        guard world.reach(.waiting) else { return fail("never waited") }
        XCTAssertEqual(world.row?.activity?.blockingTool?.name, "Bash", say("the subagent's tool"))
        world.answer(allow: true)
        XCTAssertTrue(world.reach(.review), say("subagent: never finished; \(world.trace)"))
        XCTAssertEqual(world.moves.filter { $0 == "review" }.count, 1, say("one finish: \(world.trace)"))
        XCTAssertEqual(world.moves.last, "review", say("subagent"))
        XCTAssertEqual(world.mostRows, 1, say("a subagent has no row of its own"))
    }

    /// A question is a wait for words; the user's interrupt ends the turn,
    /// which is not a failure.
    func questionThenInterrupt() {
        world.begin("question please")
        guard world.reach(.waiting) else { return fail("never waited") }
        XCTAssertEqual(world.row?.activity?.waitKind, .answer, say("words, not a yes or no"))
        XCTAssertEqual(world.row?.activity?.blockingTool?.name, "AskUserQuestion", say("the question"))
        world.driver.stop(world.session)
        XCTAssertTrue(world.reach(.review), say("interrupt: never finished; \(world.trace)"))
        XCTAssertFalse(world.moves.contains("failed"), say("an interrupt is the user's: \(world.trace)"))
    }

    func failedTurn() {
        world.begin("bad please")
        XCTAssertTrue(world.reach(.failed), say("a refused request is a failed turn; \(world.trace)"))
        XCTAssertEqual(world.moves, ["working", "failed"], say("failed"))
    }

    /// OpenCode retries a server error by itself: nothing is asked, nothing
    /// finished, and the row says what it is doing.
    func retryingTurn() {
        world.begin("fail please")
        world.pump(7)
        XCTAssertEqual(world.row?.phase, .working, say("retrying: \(world.trace)"))
        XCTAssertEqual(world.moves, ["working"], say("a retry is no event"))
        world.driver.stop(world.session)
        XCTAssertTrue(world.reach(.review), say("retry: the interrupt never finished it; \(world.trace)"))
    }

    // MARK: The card

    /// A tool waits, the card is pressed Allow: the file is edited, OpenCode's own
    /// dialog is closed by the answer, and the card is gone.
    func cardAllowed() {
        world.resetReadme()
        world.begin("editx please")
        guard world.reach(.waiting), let card = world.waitCard() else { return fail("no card") }
        XCTAssertEqual(card.tool, "Edit", say("the tool"))
        XCTAssertTrue(card.subject?.hasSuffix("README.md") == true, say("the file: \(card.subject ?? "nil")"))
        XCTAssertEqual(card.source, .opencode, say("the route's agent"))
        XCTAssertEqual(card.sessionID, world.session, say("the row's session"))
        XCTAssertTrue(world.press(allow: true), say("pressed"))
        XCTAssertTrue(world.reach(.review), say("allowed on the card: never finished; \(world.trace)"))
        XCTAssertEqual(world.readme, "hello\n", say("allowed: the edit was made"))
        XCTAssertEqual(world.moves, ["working", "waiting", "working", "review"], say("card allowed"))
        XCTAssertTrue(world.cards.isEmpty, say("the card is gone"))
        XCTAssertTrue(world.driver.pending().isEmpty, say("OpenCode asks nothing more"))
    }

    func cardDenied() {
        world.resetReadme()
        world.begin("editx please")
        guard world.reach(.waiting), world.waitCard() != nil else { return fail("no card") }
        XCTAssertTrue(world.press(allow: false), say("pressed"))
        XCTAssertTrue(world.reach(.review), say("denied on the card: never finished; \(world.trace)"))
        XCTAssertEqual(world.readme, "hi\n", say("denied: the file is as it was"))
        XCTAssertTrue(world.cards.isEmpty, say("the card is gone"))
        XCTAssertTrue(world.driver.pending().isEmpty, say("OpenCode asks nothing more"))
    }

    /// `{}` is no decision: Evlat lets the card go and OpenCode's own dialog stays,
    /// which the user answers there.
    func cardLetGo() {
        world.resetReadme()
        world.begin("editx please")
        guard world.reach(.waiting), world.waitCard() != nil else { return fail("no card") }
        world.letGo()
        world.pump(1.5)
        XCTAssertEqual(world.driver.pending().count, 1, say("OpenCode still asks"))
        XCTAssertEqual(world.row?.phase, .waiting, say("and the row still waits"))
        XCTAssertEqual(world.readme, "hi\n", say("nothing was allowed"))
        world.answer(allow: true)
        XCTAssertTrue(world.reach(.review), say("let go, then answered in OpenCode: never finished; \(world.trace)"))
        XCTAssertEqual(world.readme, "hello\n", say("allowed in OpenCode"))
    }

    /// Answered in OpenCode's own dialog first: the plugin closes its request, which
    /// is how the card goes (not Evlat letting it go).
    func cardAnsweredInOpenCode() {
        world.resetReadme()
        world.begin("editx please")
        guard world.reach(.waiting), let card = world.waitCard() else { return fail("no card") }
        world.answer(allow: true)
        XCTAssertTrue(world.pump(10) { self.world.cards.isEmpty }, say("the card is still there; \(world.trace)"))
        XCTAssertTrue(world.abandoned.contains(card.id), say("the plugin closed the request"))
        XCTAssertTrue(world.reach(.review), say("answered in OpenCode: never finished; \(world.trace)"))
        XCTAssertEqual(world.readme, "hello\n", say("allowed in OpenCode"))
    }

    /// One reply, two tool calls, two permissions at once: one card at a time, the
    /// second after the first is answered, and the row waits through both.
    func twoCards() {
        world.begin("two please")
        guard world.reach(.waiting), let first = world.waitCard() else { return fail("no card") }
        world.pump(2)
        XCTAssertEqual(world.cards.count, 1, say("the second waits behind the first"))
        XCTAssertTrue(world.press(allow: true), say("first pressed"))
        let second = world.waitCard(other: first.id)
        XCTAssertNotNil(second, say("the second card never came; \(world.trace)"))
        XCTAssertEqual(Set([first.command, second?.command]), ["echo evlat-one", "echo evlat-two"], say("both commands"))
        XCTAssertEqual(world.row?.phase, .waiting, say("one answered, one still asked"))
        XCTAssertTrue(world.press(allow: true), say("second pressed"))
        XCTAssertTrue(world.reach(.review), say("two cards: never finished; \(world.trace)"))
        XCTAssertEqual(world.moves, ["working", "waiting", "working", "review"], say("two cards"))
        XCTAssertTrue(world.cards.isEmpty && world.driver.pending().isEmpty, say("nothing left to answer"))
    }

    /// A subagent's permission is on the root's card, answered to the subagent's
    /// own session.
    func subagentCard() {
        world.begin("task please")
        guard world.reach(.waiting), let card = world.waitCard() else { return fail("no card") }
        XCTAssertEqual(card.sessionID, world.session, say("the root's row"))
        XCTAssertNotNil(card.subagent, say("the subagent is the actor"))
        XCTAssertEqual(card.tool, "Bash", say("the subagent's tool"))
        XCTAssertTrue(world.press(allow: true), say("pressed"))
        XCTAssertTrue(world.reach(.review), say("subagent card: never finished; \(world.trace)"))
        XCTAssertTrue(world.driver.pending().isEmpty, say("the subagent's dialog is closed"))
    }

    /// 2.x's service boots a plugin instance per folder and only the one that owns
    /// a session's folder can answer it: a session in a second folder is answered
    /// whichever instance heard the ask first. (1.x answers from the instance of
    /// the folder it heard it in: nothing to choose, and nothing to run.)
    func otherFolder() {
        guard world.driver.isSharedService else { return }
        world.resetReadme()
        let other = world.otherFolder()
        world.begin("editx please", in: other)
        guard world.reach(.waiting), world.waitCard() != nil else { return fail("no card in the second folder") }
        XCTAssertTrue(world.press(allow: true), say("pressed"))
        XCTAssertTrue(world.reach(.review), say("second folder: never finished; \(world.trace)"))
        XCTAssertEqual(world.readme(in: other), "hello\n", say("the instance that owns the folder answered"))
        XCTAssertEqual(world.readme, "hi\n", say("and the first folder's file is as it was"))
    }

    /// Evlat closed: the plugin's requests fail at once, and OpenCode's own dialog
    /// is not kept waiting for a card that cannot come. Last, because the
    /// listener stays stopped.
    func evlatClosed() {
        world.resetReadme()
        world.stopListener()
        world.begin("editx please")
        let began = Date()
        XCTAssertTrue(world.pump(15) { !self.world.driver.pending().isEmpty }, say("OpenCode never asked"))
        XCTAssertLessThan(Date().timeIntervalSince(began), 12, say("the dialog came without delay"))
        world.answer(allow: true)
        XCTAssertTrue(world.pump(30) { self.world.readme == "hello\n" }, say("answered in OpenCode: the edit was made"))
    }

    private func fail(_ text: String) {
        XCTFail(say("\(text); trace \(world.trace)"))
    }
}

// MARK: - A home, a model, a server

private final class World {
    let target: Target
    let root: URL
    let home: URL
    let work: URL
    private(set) var driver: Driver!
    private var processes: [Process] = []
    private var listener: HookListener?
    private let approvals = MainActor.assumeIsolated { ApprovalStore(agents: Agents.all) }
    private(set) var abandoned: [String] = []
    private var provider = World.makeProvider()
    private var pid: Int32 = 0
    private var versionHeard: String?
    private(set) var session = ""
    private(set) var trace: [String] = []
    private(set) var mostRows = 0

    var socket: String { home.appendingPathComponent(EvlatSocket.relativePath).path }
    var row: Signal? { provider.currentSignals().first }

    /// The phases the row went through, without the idle a `session.created`
    /// gives and a service's first session in a folder does not.
    var moves: [String] { trace.filter { $0 != "idle" } }

    private static func makeProvider() -> HooksProvider {
        HooksProvider(platform: Platform(isAlive: { _ in true }, processStartedAt: { _ in Date() }, now: Date.init),
                      isQuestion: Agents.isQuestion)
    }

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// Short: the socket under the home must fit an address.
    init(target: Target) throws {
        self.target = target
        root = URL(fileURLWithPath: "/private/tmp/evlat-oc-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        home = root.appendingPathComponent("h", isDirectory: true)
        work = home.appendingPathComponent("work", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        try "hi\n".write(to: work.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    /// Shared between runs: the first use of a model downloads its adapter.
    private var cache: URL { URL(fileURLWithPath: "/private/tmp/evlat-opencode-cache", isDirectory: true) }

    var environment: [String: String] {
        ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
         "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
         "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path, "XDG_CACHE_HOME": cache.path,
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
         "TMPDIR": root.appendingPathComponent("tmp").path, "LANG": "en_US.UTF-8", "NO_COLOR": "1"]
    }

    func start() throws {
        let model = try startModel()
        try writeConfig(modelPort: model)
        try AgentIntegration.install(home: home, for: OpenCode())
        let installed = home.appendingPathComponent(OpenCodePlugin.path)
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), OpenCodePlugin.file.contents,
                       "the installer wrote the plugin")

        // The app's own wiring for a held request: the store holds it for the card, a
        // press writes the answer to the listener, a closed connection abandons it.
        let listener = HookListener(
            transport: .unix(socket),
            onAbandoned: { [weak self] id in
                MainActor.assumeIsolated {
                    self?.abandoned.append(id)
                    self?.approvals.abandoned(id)
                }
            },
            onDelivery: { [weak self] delivery in
                switch delivery {
                case .hook(let event): self?.heard(event)
                case .approval(let request): MainActor.assumeIsolated { self?.approvals.asked(request) }
                default: break
                }
            })
        listener.start()
        guard case .listeningAt = listener.awaitSettled(timeout: 5) else {
            throw XCTSkip("the listener did not come up: \(listener.status.text)")
        }
        self.listener = listener
        MainActor.assumeIsolated {
            approvals.respond = { [weak listener] request, response in listener?.answer(request.id, with: response) }
        }

        switch target {
        case .cli(let binary):
            if try isSecondLine(binary) {
                driver = try ServiceDriver(world: self, binary: binary)
            } else {
                driver = try HTTPDriver(world: self, command: binary, arguments: [], password: nil)
            }
        case .desktop(let app):
            let electron = app + "/Contents/MacOS/OpenCode"
            let serve = Self.fixtures.appendingPathComponent("opencode-desktop-serve.mjs").path
            var extra = environment
            extra["ELECTRON_RUN_AS_NODE"] = "1"
            driver = try HTTPDriver(world: self, command: electron, arguments: [serve, app + "/Contents/Resources/app.asar"],
                                    password: "pw", environment: extra)
        }
        try driver.start()
        pid = driver.serverPID
    }

    func tearDown() {
        driver?.stopServer()
        for process in processes where process.isRunning { process.terminate() }
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        listener?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The fake model and the config

    private func startModel() throws -> Int {
        let output = root.appendingPathComponent("model.out")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        _ = try spawn(Self.fixtures.appendingPathComponent("fake-opencode-model").path, ["0"], output: output)
        var port: Int?
        _ = pump(10) {
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            port = text.split(separator: " ").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return port != nil
        }
        return try XCTUnwrap(port, "the fake model did not say its port")
    }

    private func writeConfig(modelPort: Int) throws {
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "provider": ["fake": ["npm": "@ai-sdk/openai-compatible", "name": "Fake",
                                  "options": ["baseURL": "http://127.0.0.1:\(modelPort)/v1", "apiKey": "x"],
                                  "models": ["m1": ["name": "m1"]]]],
            "model": "fake/m1", "small_model": "fake/m1", "permission": ["bash": "ask", "edit": "ask"],
            "autoupdate": false, "share": "disabled",
        ]
        let folder = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: config).write(to: folder.appendingPathComponent("opencode.json"))
    }

    private func isSecondLine(_ binary: String) throws -> Bool {
        let result = run(binary, ["--version"], timeout: 20)
        let version = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(OpenCode().hasMeasured(version: version.replacingOccurrences(of: "opencode v", with: "")),
                      "\(binary) is \(version): add its line to `OpenCode.measuredVersions` once it is measured here")
        return version.hasPrefix("opencode v2.")
    }

    // MARK: A scenario

    /// A new session and its prompt, with a provider that has heard nothing.
    func begin(_ prompt: String, in directory: URL? = nil) {
        pump(1)
        MainActor.assumeIsolated { approvals.release(where: { _ in true }) }
        provider = Self.makeProvider()
        trace = []
        mostRows = 0
        session = driver.createSession(in: directory ?? work) ?? ""
        XCTAssertFalse(session.isEmpty, "[\(target.name)] a session was created")
        driver.prompt(session, prompt)
    }

    private func heard(_ event: HookEvent) {
        MainActor.assumeIsolated { approvals.heard(event, machine: nil) }
        provider.handle(event)
        if let version = event.agentVersion { versionHeard = version }
        let rows = provider.currentSignals()
        mostRows = max(mostRows, rows.count)
        if let phase = rows.first?.phase.rawValue, trace.last != phase { trace.append(phase) }
    }

    /// Waits for the row to read `phase`.
    func reach(_ phase: Phase, timeout: TimeInterval = 30) -> Bool {
        pump(timeout) { self.row?.phase == phase }
    }

    /// Answers everything that is asked, until nothing is.
    func answer(allow: Bool) {
        for _ in 0..<4 {
            let pending = driver.pending()
            if pending.isEmpty { return }
            for ask in pending { driver.reply(ask, allow: allow) }
            pump(0.5)
        }
    }

    // MARK: The card and the file it is about

    var cards: [HeldRequest] { MainActor.assumeIsolated { approvals.pending } }

    /// Waits for a card (another than `other`, when it is given).
    func waitCard(other: String? = nil, timeout: TimeInterval = 20) -> HeldRequest? {
        var found: HeldRequest?
        pump(timeout) {
            found = self.cards.first { $0.id != other }
            return found != nil
        }
        return found
    }

    /// The press on the oldest card.
    func press(allow: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard let first = approvals.pending.first else { return false }
            return approvals.answer(first.id, allow: allow)
        }
    }

    /// Evlat lets every held request go: `{}`.
    func letGo() {
        MainActor.assumeIsolated { approvals.release(where: { _ in true }) }
    }

    func stopListener() {
        listener?.stop()
    }

    private var readmeURL: URL { work.appendingPathComponent("README.md") }
    var readme: String { readme(in: work) }
    func readme(in folder: URL) -> String {
        (try? String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
    }
    func resetReadme() { try? "hi\n".write(to: readmeURL, atomically: true, encoding: .utf8) }

    /// A second folder of the same home, with a file of its own to edit.
    func otherFolder() -> URL {
        let folder = home.appendingPathComponent("other", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "hi\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return folder
    }

    /// 1.x and the desktop send the pid of the process the plugin runs in,
    /// which is the server; 2.x's shared service sends none of the agent's
    /// own, since it belongs to no terminal, and says its own as the
    /// service's (`Signal.Activity.pid`, `servicePid`).
    func checkProcessAndVersion() {
        let pidSaid = row?.activity?.pid
        let serviceSaid = row?.activity?.servicePid
        if driver.isSharedService {
            XCTAssertNil(pidSaid, "[\(target.name)] the shared service belongs to no terminal")
            XCTAssertNotNil(serviceSaid, "[\(target.name)] and says which process it is")
            XCTAssertEqual(serviceSaid, pid, "[\(target.name)] the service's pid is the process the plugin runs in")
        } else {
            XCTAssertEqual(pidSaid, pid, "[\(target.name)] the pid is the process the plugin runs in")
            XCTAssertNil(serviceSaid, "[\(target.name)] no service is shared here")
        }
        XCTAssertNotNil(versionHeard, "[\(target.name)] a version was said")
        XCTAssertTrue(OpenCode().hasMeasured(version: versionHeard), "[\(target.name)] \(versionHeard ?? "nil")")
    }

    // MARK: Pumping and processes

    @discardableResult
    func pump(_ seconds: TimeInterval, until condition: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    @discardableResult
    func spawn(_ path: String, _ arguments: [String], environment extra: [String: String]? = nil, output: URL? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = extra ?? environment
        process.currentDirectoryURL = work
        process.standardInput = FileHandle.nullDevice
        if let output, let handle = try? FileHandle(forWritingTo: output) {
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        processes.append(process)
        return process
    }

    /// To the end, pumping the main queue so the listener's deliveries land.
    func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 30) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = work
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var data = Data()
        let reading = DispatchQueue(label: "opencode-live-read")
        let done = DispatchSemaphore(value: 0)
        reading.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        do { try process.run() } catch { return (-1, "\(error)") }
        let finished = pump(timeout) { !process.isRunning }
        if !finished { process.terminate() }
        _ = done.wait(timeout: .now() + 5)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Driving a server

private struct Ask {
    let session: String
    let id: String
}

private protocol Driver: AnyObject {
    var serverPID: Int32 { get }
    var isSharedService: Bool { get }
    func start() throws
    func stopServer()
    func createSession(in directory: URL) -> String?
    func prompt(_ session: String, _ text: String)
    func pending() -> [Ask]
    func reply(_ ask: Ask, allow: Bool)
    func stop(_ session: String)
}

/// 1.x's `opencode serve`, and the desktop app's server module: one HTTP API.
private final class HTTPDriver: Driver {
    private unowned let world: World
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let authorization: String?
    private var port = 0
    private var process: Process?

    var serverPID: Int32 { process?.processIdentifier ?? 0 }
    let isSharedService = false

    init(world: World, command: String, arguments: [String], password: String?, environment: [String: String]? = nil) throws {
        self.world = world
        self.command = command
        self.arguments = arguments
        self.environment = environment ?? world.environment
        authorization = password.map { "Basic " + Data("opencode:\($0)".utf8).base64EncodedString() }
    }

    func start() throws {
        port = try Ports.free()
        let arguments = self.arguments.isEmpty ? ["serve", "--port", String(port)]
            : self.arguments + [String(port)]
        process = try world.spawn(command, arguments, environment: environment,
                                  output: world.root.appendingPathComponent("server.out"))
        // `/global/health` answers before the routes that need a login do.
        let up = world.pump(40) { self.request("GET", "/session").status == 200 }
        XCTAssertTrue(up, "the server did not come up")
    }

    func stopServer() { process?.terminate() }

    func createSession(in directory: URL) -> String? {
        let (_, data) = request("POST", "/session", body: Data("{}".utf8))
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }

    func prompt(_ session: String, _ text: String) {
        let body: [String: Any] = ["parts": [["type": "text", "text": text]],
                                   "model": ["providerID": "fake", "modelID": "m1"]]
        _ = request("POST", "/session/\(session)/prompt_async", body: try? JSONSerialization.data(withJSONObject: body))
    }

    func pending() -> [Ask] {
        let (_, data) = request("GET", "/permission")
        let list = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String, let session = item["sessionID"] as? String else { return nil }
            return Ask(session: session, id: id)
        }
    }

    func reply(_ ask: Ask, allow: Bool) {
        let body = try? JSONSerialization.data(withJSONObject: ["reply": allow ? "once" : "reject"])
        _ = request("POST", "/permission/\(ask.id)/reply", body: body)
    }

    func stop(_ session: String) {
        _ = request("POST", "/session/\(session)/abort")
    }

    /// Every route names the folder the session is in.
    func request(_ method: String, _ path: String, body: Data? = nil) -> (status: Int, data: Data) {
        var components = URLComponents(string: "http://127.0.0.1:\(port)\(path)")!
        components.queryItems = [URLQueryItem(name: "directory", value: world.work.path)]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        var result: (Int, Data)?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
        }
        task.resume()
        _ = world.pump(25) { result != nil }
        return result ?? (0, Data())
    }
}

/// 2.x's background service, one for the user: started on a port of its own
/// in the test's home, driven by `opencode api`, stopped when it is done.
private final class ServiceDriver: Driver {
    private unowned let world: World
    private let binary: String

    /// The service's own record in the test's home: the process the plugin
    /// runs in, and what the row's liveness hangs on.
    var serverPID: Int32 {
        let record = world.home.appendingPathComponent(".local/state/opencode/service.json")
        guard let data = try? Data(contentsOf: record),
              let pid = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["pid"] as? Int else { return 0 }
        return Int32(pid)
    }
    let isSharedService = true

    init(world: World, binary: String) throws {
        self.world = world
        self.binary = binary
    }

    func start() throws {
        // The default port is the user's own, and the real service holds it.
        let port = try Ports.free()
        _ = world.run(binary, ["service", "set", "port", String(port)])
        let started = world.run(binary, ["service", "start"], timeout: 60)
        XCTAssertEqual(started.status, 0, "service start: \(started.out)")
    }

    func stopServer() {
        _ = world.run(binary, ["service", "stop"], timeout: 20)
        // Whatever is left of it, by the pid it wrote in the test's own home.
        if serverPID > 1 { kill(serverPID, SIGTERM) }
    }

    func createSession(in directory: URL) -> String? {
        let body = "{\"location\":{\"directory\":\"\(directory.path)\"}}"
        return id(of: api(["session.create", "-d", body]))
    }

    func prompt(_ session: String, _ text: String) {
        _ = api(["session.prompt", "--param", "sessionID=\(session)", "-d", "{\"text\":\"\(text)\"}"])
    }

    /// Every session's open permissions (a subagent's is its own session's).
    func pending() -> [Ask] {
        var asks: [Ask] = []
        for session in sessions() {
            for item in list(api(["session.permission.list", "--param", "sessionID=\(session)"])) {
                if let id = item["id"] as? String { asks.append(Ask(session: session, id: id)) }
            }
        }
        return asks
    }

    func reply(_ ask: Ask, allow: Bool) {
        _ = api(["session.permission.reply", "--param", "sessionID=\(ask.session)", "--param", "requestID=\(ask.id)",
                 "-d", "{\"decision\":\"\(allow ? "once" : "reject")\"}"])
    }

    func stop(_ session: String) {
        _ = api(["session.interrupt", "--param", "sessionID=\(session)"])
    }

    private func sessions() -> [String] {
        list(api(["session.list"])).compactMap { $0["id"] as? String }
    }

    private func api(_ arguments: [String]) -> String {
        world.run(binary, ["api"] + arguments, timeout: 40).out
    }

    private func id(of output: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        return object["id"] as? String ?? (object["data"] as? [String: Any])?["id"] as? String
    }

    private func list(_ output: String) -> [[String: Any]] {
        let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        return object?["data"] as? [[String: Any]] ?? []
    }
}

private enum Ports {
    /// A port nothing holds, for a server of the test's own.
    static func free() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw XCTSkip("no free port") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
