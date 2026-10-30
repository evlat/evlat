import AppKit
import UniformTypeIdentifiers
import EvlatCore
import EvlatAgents

/// A session an agent runs under a daemon of its own, in no terminal
/// (`BackgroundAttach`, the agent's values): the walk to an app ends in
/// `.notFound`. It can still be looked into: the agent's attach command
/// opens it in any terminal. The card's button opens it where the user's
/// other sessions run (`place(among:)`): in a new herdr tab when they are
/// in herdr, in their app when they are in one that opens `.command`
/// files, and otherwise in the app macOS opens those with — the user's
/// default, Terminal unless they changed it. An installed herdr, or one
/// left open, decides nothing on its own.
enum BackgroundSession {
    /// What the button runs: the attach command for one session, and where.
    struct Attach: Equatable {
        let arguments: [String]
        /// Found when the card comes up, for its words; found again on the click.
        var place: Place = .commandFile(app: "Terminal")
        /// The other local sessions' pids, most recent first: where they
        /// run is where this one opens.
        var others: [Int32] = []
    }

    /// Where the attach command is opened.
    enum Place: Equatable {
        /// A new tab in the herdr server a client is attached to: `cli` is
        /// that client's executable, `session` its named session (`nil` for
        /// the default), `app` the terminal it runs in.
        case herdr(app: SessionHost.App, cli: String, session: String?)
        /// A `.command` file, in that running app.
        case app(SessionHost.App)
        /// A `.command` file, in its default app (`terminalName`).
        case commandFile(app: String)

        /// The button's "Open in …": the app the user will see it in.
        var name: String {
            switch self {
            case .herdr(let app, _, _), .app(let app): return app.name
            case .commandFile(let app): return app
            }
        }
    }

    /// Where one other session runs, as far as the choice goes: herdr's
    /// panes are one place whatever app shows them.
    enum Where: Hashable {
        case herdr
        case app(bundleID: String)
    }

    /// The command when one of the pid's ancestors is an agent's daemon
    /// host; `nil` for anything in a terminal, or with no pid.
    static func attach(pid: Int32?, sessionID: String,
                       among attaches: [BackgroundAttach] = Agents.backgroundAttaches,
                       parent: (Int32) -> Int32? = SessionHost.parentPID,
                       arguments: (Int32) -> [String] = SessionHost.arguments) -> Attach? {
        guard var pid else { return nil }
        for _ in 0..<SessionHost.maxSteps {
            let args = arguments(pid)
            if let found = attaches.first(where: { !$0.hostArguments.isDisjoint(with: args) }) {
                guard sessionID.count >= found.idLength else { return nil }
                return Attach(arguments: found.command(String(sessionID.prefix(found.idLength))))
            }
            guard let up = parent(pid), up > 1, up != pid else { return nil }
            pid = up
        }
        return nil
    }

    /// The live lookup, nothing under XCTest: a test's pids are not sessions.
    static func live(pid: Int32?, sessionID: String, others: [Int32]) -> Attach? {
        guard NSClassFromString("XCTestCase") == nil,
              var found = attach(pid: pid, sessionID: sessionID) else { return nil }
        found.others = others
        found.place = place(among: others)
        return found
    }

    /// How many of the other sessions are asked: the most recent.
    static let othersAsked = 8

    /// Where each session runs, cheaply: a herdr server among its ancestors
    /// is herdr (its pane is not asked for); otherwise the shallow walk's
    /// app, which spends no multiplexer's deadline. `nil` for none found.
    static func whereRuns(_ pid: Int32, _ probe: SessionHost.Probe) -> (Where, SessionHost.App?)? {
        var step: Int32? = pid
        for _ in 0..<SessionHost.maxSteps {
            guard let current = step, current > 1 else { break }
            if let path = probe.executablePath(current), Herdr.isServer(current, path: path, probe) {
                return (.herdr, nil)
            }
            step = probe.parent(current)
        }
        guard case .app(let app) = SessionHost.resolve(pid: pid, throughServers: false, probe) else { return nil }
        return (.app(bundleID: app.bundleID), app)
    }

    /// Where most of the other sessions run, a tie to the most recent's,
    /// and how that is opened: herdr's newest client, or the app when it
    /// opens `.command` files. A place that cannot be opened gives way to
    /// the next; with none left, the default app.
    static func place(among others: [Int32], _ probe: SessionHost.Probe = SessionHost.live,
                      opensCommandFiles: (SessionHost.App) -> Bool = opensCommandFiles) -> Place {
        let found = others.prefix(othersAsked).compactMap { whereRuns($0, probe) }
        var counts: [Where: Int] = [:]
        for (place, _) in found { counts[place, default: 0] += 1 }
        // Each place once, at its most recent session; the sort is stable,
        // so equals keep that order.
        var seen = Set<Where>()
        let ranked = found.filter { seen.insert($0.0).inserted }.sorted { counts[$0.0]! > counts[$1.0]! }
        for (place, app) in ranked {
            switch place {
            case .herdr:
                if let herdr = herdrPlace(probe) { return herdr }
            case .app:
                if let app, opensCommandFiles(app) { return .app(app) }
            }
        }
        return .commandFile(app: terminalName)
    }

    /// The newest herdr client in a terminal, while a herdr server runs, as
    /// the app it is in. `nil` when there is none, or it is in no app.
    static func herdrPlace(_ probe: SessionHost.Probe) -> Place? {
        var server = false
        var newest: (pid: Int32, start: Date, path: String, session: String?)?
        for pid in probe.processes() {
            guard let path = probe.executablePath(pid), Herdr.isExecutable(path) else { continue }
            if Herdr.isServer(pid, path: path, probe) { server = true; continue }
            // A client, not one of the CLI's own subcommands.
            guard probe.hasTerminal(pid) != false,
                  case .some(let session) = Herdr.clientSession(arguments: probe.arguments(pid)) else { continue }
            let start = probe.startedAt(pid) ?? .distantPast
            if newest.map({ start > $0.start }) ?? true { newest = (pid, start, path, session) }
        }
        guard server, let newest,
              case .app(let app) = SessionHost.resolve(pid: newest.pid, throughServers: false, probe) else { return nil }
        return .herdr(app: app, cli: newest.path, session: newest.session)
    }

    /// Whether the app is one that opens `.command` files: Terminal,
    /// Ghostty and cmux say so (Launch Services, macOS 27).
    static func opensCommandFiles(_ app: SessionHost.App) -> Bool {
        guard let type = UTType(filenameExtension: "command"), let url = bundleURL(app) else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: type).contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    /// The running app's bundle, `nil` once it has quit.
    private static func bundleURL(_ app: SessionHost.App) -> URL? {
        NSRunningApplication(processIdentifier: app.pid)?.bundleURL
    }

    /// The app `.command` files open in, by its name: the button's "Open in …".
    static var terminalName: String {
        guard let type = UTType(filenameExtension: "command"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return "Terminal" }
        return FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// The command where the user's sessions run (`place`, asked again
    /// now: the herdr client or the app may have gone). `label` names
    /// herdr's tab.
    @discardableResult
    static func open(_ attach: Attach, label: String?, folder: String?) -> Bool {
        guard !WindowStage.isOffstage, !attach.arguments.isEmpty,
              attach.arguments.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
        else { return false }
        // Every word is plain, so the line needs no quoting.
        let line = attach.arguments.joined(separator: " ")
        switch place(among: attach.others) {
        case .herdr(let app, let cli, let session):
            openInHerdr(line, app: app, cli: cli, session: session, label: label, folder: folder)
            return true
        case .app(let app):
            return openCommandFile(line, in: bundleURL(app))
        case .commandFile:
            return openCommandFile(line)
        }
    }

    /// A new tab in herdr's focused workspace, the command run in its
    /// pane, then the terminal brought forward on that client. Off the main
    /// queue: two runs of herdr's CLI. If the tab cannot be made, the
    /// `.command` file instead, in herdr's app when it opens one.
    private static func openInHerdr(_ line: String, app: SessionHost.App, cli: String, session: String?,
                                    label: String?, folder: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            var create = ["tab", "create", "--focus", "--cwd", folder ?? NSHomeDirectory()]
            if let label, !label.isEmpty { create += ["--label", label] }
            let pane = run(cli, create, session: session).flatMap(createdPane)
            let ran = pane.map { run(cli, ["pane", "run", $0, line], session: session) != nil } ?? false
            DispatchQueue.main.async {
                if ran { _ = SessionHost.activate(app); return }
                _ = openCommandFile(line, in: opensCommandFiles(app) ? bundleURL(app) : nil)
            }
        }
    }

    /// The new tab's pane, from `tab create`'s reply.
    static func createdPane(_ reply: String) -> String? {
        guard let data = reply.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let root = result["root_pane"] as? [String: Any],
              let pane = root["pane_id"] as? String, HerdrPane.isPaneID(pane) else { return nil }
        return pane
    }

    /// herdr's CLI, its output when it exits 0 within `timeout`, as
    /// `Tmux.run` asks: its replies are a line of JSON, far under a pipe's
    /// buffer, so the exit is waited for before the output is read.
    private static func run(_ cli: String, _ arguments: [String], session: String?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let session { environment["HERDR_SESSION"] = session }
        process.environment = environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A tab's making and a pane's run, each well under a second.
    static let timeout: TimeInterval = 5

    /// The `.command` file's text: the line run by the user's own shell,
    /// login and interactive, so the agent is found on the `PATH` a new
    /// terminal window has (`.zshrc`'s too, not only `.zprofile`'s). If it
    /// fails (the session ended), the window stays up with what it said.
    static func commandFileText(_ line: String) -> String {
        """
        #!/bin/zsh
        clear
        "${SHELL:-/bin/zsh}" -lic '\(line)' || { echo; read -sk1 '?Press any key to close.' }

        """
    }

    /// The command in a `.command` file, in that app, or the default app
    /// for them.
    private static func openCommandFile(_ line: String, in app: URL? = nil) -> Bool {
        let command = FileManager.default.temporaryDirectory.appendingPathComponent("\(line).command")
        guard (try? commandFileText(line).write(to: command, atomically: true, encoding: .utf8)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        guard let app else { return NSWorkspace.shared.open(command) }
        NSWorkspace.shared.open([command], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
