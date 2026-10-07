import Foundation
import EvlatCore
import EvlatAgents

/// Docker sandboxes' own listener: the hooks of agents in local `sbx`
/// sandboxes, sent by the command Evlat writes into each (`SandboxInstall`) to
/// `host.docker.internal`, which the sandbox's proxy turns into this Mac's
/// loopback. A remote machine's sibling with no tunnel: `.sandbox`, so the
/// VM's pid and task are thrown away, every route but a hook is `404`, and
/// it is the one listener that believes the sandbox's header.
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

    /// What Settings shows: whether it listens, and which sandboxes it heard.
    struct Status: Equatable {
        var listener: HookListener.Status = .stopped
        /// The sandboxes' names, as their hooks said them.
        var heard: Set<String> = []
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
            origin: .sandbox,
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

    /// Hooks only: `.sandbox` answers every other route with `404`
    /// (`LocalAPI.Origin.role`).
    private func deliver(_ delivery: LocalAPI.Delivery) {
        guard case .hook(let event) = delivery else { return }
        if let name = event.sandboxName { status.heard.insert(name) }
        hooks.handle(event)
        onChange()
    }

    // MARK: - Which port

    /// The port this process listens on for sandboxes, or `nil` for none.
    /// `EVLAT_SANDBOX_PORT` when given (a number that is no port: none);
    /// otherwise none in an isolated process (`EVLAT_PORT`) — the port is
    /// fixed, and a second Evlat must not take the user's sandboxes — else
    /// the fixed one (`SandboxInstall.defaultPort`).
    nonisolated static func port(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16? {
        let value = { (name: String) -> String? in
            let raw = environment[name]?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? nil : raw
        }
        if let raw = value("EVLAT_SANDBOX_PORT") {
            guard let port = UInt16(raw), port > 0 else { return nil }
            return port
        }
        return value("EVLAT_PORT") == nil ? SandboxInstall.defaultPort : nil
    }
}
