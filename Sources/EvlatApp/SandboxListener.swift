import Foundation
import EvlatCore
import EvlatAgents

/// Docker sandboxes' own listener: the hooks of agents in local `sbx`
/// sandboxes, sent by the kit's command (`SandboxKit`) to
/// `host.docker.internal`, which the sandbox's proxy turns into this Mac's
/// loopback. A remote machine's sibling with no tunnel: `.tunneled`, so the
/// VM's pid and task are thrown away and nothing is held for an answer, and
/// the one listener that believes the sandbox's two headers.
///
/// Its rows are one machine's (`identity`): namespaced apart from this Mac's
/// and every remote machine's, each drawn with its own sandbox's name. The
/// agents run on this Mac, so they answer to this Mac's switches
/// (`AppController.machineSources`).
@MainActor
final class SandboxListener {
    /// The rows' machine. The id is one no remote machine can have: a
    /// target with a leading `-` is refused (`RemoteMachine.validate`), and
    /// an `EVLAT_MACHINES` target is its machine's id, so a plain word could
    /// be a server's alias and merge two namespaces. The name is drawn only
    /// when a hook named no sandbox.
    nonisolated static let identity = Signal.Machine.Identity(id: "-sandbox", name: "sbx")

    /// What Settings shows: whether it listens, and which sandboxes it heard
    /// with which kit.
    struct Status: Equatable {
        var listener: HookListener.Status = .stopped
        /// Sandbox name → the kit version its last hook carried (`nil`:
        /// none said).
        var heard: [String: Int?] = [:]
    }

    let port: UInt16
    let hooks: HooksProvider
    private(set) var status = Status()
    private var listener: HookListener?
    private let onChange: () -> Void

    init(port: UInt16, platform: Platform, onChange: @escaping () -> Void) {
        self.port = port
        self.hooks = HooksProvider(platform: platform, machine: Self.identity, isQuestion: Agents.isQuestion)
        self.onChange = onChange
    }

    /// Binds the port. While it listens a row is not drawn dimmed: there is
    /// no tunnel to lose, only the port (`HooksProvider.setLink`).
    func start() {
        let listener = HookListener(
            port: port,
            origin: .tunneled,
            trustsSandboxHeaders: true,
            onStatus: { [weak self] status in
                MainActor.assumeIsolated { self?.listenerChanged(status) }
            },
            onDelivery: { [weak self] delivery in
                MainActor.assumeIsolated { self?.deliver(delivery) }
            })
        self.listener = listener
        listener.start()
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    /// The bound port, while it listens.
    var boundPort: UInt16? { listener?.boundPort }

    private func listenerChanged(_ status: HookListener.Status) {
        if case .unavailable = status { NSLog("Evlat: sandbox endpoint %@", status.text) }
        if case .listening = status { hooks.setLink(connected: true) } else { hooks.setLink(connected: false) }
        self.status.listener = status
        onChange()
    }

    /// Hooks only. A sandbox has no status line relayed, no `/signal` key,
    /// and `.tunneled` answers the held routes with `404`.
    private func deliver(_ delivery: LocalAPI.Delivery) {
        guard case .hook(let event) = delivery else { return }
        if let name = event.sandboxName { status.heard[name] = .some(event.kitVersion) }
        hooks.handle(event)
        onChange()
    }

    // MARK: - Which port

    /// The port this process listens on for sandboxes, or `nil` for none.
    /// `EVLAT_SANDBOX_PORT` when given (a number that is no port: none);
    /// otherwise none in an isolated process (`EVLAT_PORT`) — the kit's
    /// port is fixed, and a second Evlat must not take the user's
    /// sandboxes — else the kit's (`SandboxKit.defaultPort`).
    nonisolated static func port(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16? {
        let value = { (name: String) -> String? in
            let raw = environment[name]?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? nil : raw
        }
        if let raw = value("EVLAT_SANDBOX_PORT") {
            guard let port = UInt16(raw), port > 0 else { return nil }
            return port
        }
        return value("EVLAT_PORT") == nil ? SandboxKit.defaultPort : nil
    }
}

/// Writes the kit's folder (`SandboxKit.files`) where the user can point
/// `sbx` at it. Never at launch: only when Settings shows it or a command
/// naming it is copied. The same bytes twice are no write.
///
/// The folder is Evlat's own, under Application Support, and the kit is
/// made again from Swift constants whenever it is asked for: `sbx` reads it
/// once, when a sandbox is made or a kit added, and never after.
enum SandboxKitWriter {
    /// `<home>/Library/Application Support/Evlat/sandbox-kit`, or `nil`: an
    /// isolated process (`EVLAT_PORT`) writes nothing unless it was given a
    /// home of its own (`EVLAT_HOME`) — the `/signal` key's rule.
    static func location(home: URL?,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let set = { (name: String) in !(environment[name]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
        if set("EVLAT_PORT") && !set("EVLAT_HOME") { return nil }
        return home?.appendingPathComponent("Library/Application Support/Evlat", isDirectory: true)
            .appendingPathComponent("sandbox-kit", isDirectory: true)
    }

    /// Writes each of the kit's files into `folder` whole, leaving one that
    /// already holds the same bytes alone. Returns the folder.
    @discardableResult
    static func write(_ kit: SandboxKit, to folder: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in kit.files {
            let url = folder.appendingPathComponent(file.path)
            let data = Data(file.content.utf8)
            if (try? Data(contentsOf: url)) == data { continue }
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return folder
    }

    /// The command that makes a sandbox with the kit, for `agent`'s word in
    /// `sbx`. The path is quoted: Application Support has a space.
    static func runCommand(folder: URL, agent: String) -> String {
        "sbx run --kit \(quoted(folder.path)) \(agent)"
    }

    /// The command that adds the kit to the sandbox `sandbox`, which `sbx`
    /// then makes again.
    static func addCommand(folder: URL, sandbox: String) -> String {
        "sbx kit add \(sandbox) \(quoted(folder.path))"
    }

    /// A single-quoted shell word: each `'` closes, is escaped and reopens.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
