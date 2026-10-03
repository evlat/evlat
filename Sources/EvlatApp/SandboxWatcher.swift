import Foundation
import EvlatCore
import EvlatAgents

/// Sets Docker sandboxes up as they run: hears the `sbx` daemon's lifecycle
/// events (`SandboxDaemonLink`) and puts Evlat's file and rule into each
/// running sandbox of the sandbox agent's (`SandboxInstall`, run by
/// `SandboxRunner`).
///
/// - On every connection, the list is read once and every running sandbox
///   of the agent's is set up. A sandbox not running has its rows dropped
///   (one may have stopped while the stream was down).
/// - `started` → the list again (the event names no agent), and it is set
///   up. `created` → the list, to show it. `stopped`/`deleted` → its rows go
///   (`forget`).
/// - The connection lost: rows stay; it is opened again.
/// - `stop(removing: true)`, the switch turned off: the list once more, and
///   Evlat's file and rule come out of every running sandbox of the agent's.
///   A stopped one is never touched — `sbx exec` would start it — and keeps
///   a file that speaks to a closed port.
///
/// Installs are idempotent, so a `started` the daemon repeats on connect
/// costs one more run and changes nothing.
@MainActor
final class SandboxWatcher {
    /// Where the watcher's two outside things are: `sbx` (`nil`: looked up
    /// on the login `PATH`) and the daemon's socket.
    struct Source: Equatable {
        let sbx: String?
        let socket: String
    }

    enum Daemon: Equatable {
        case off, connecting, connected
        /// Lost; tried again on the core's schedule. Rows stay.
        case disconnected
        /// `sbx` answered, but not with the stream measured; tried again
        /// like `disconnected`.
        case refused
    }

    /// One sandbox's setup, as Settings will say it.
    enum Setup: Equatable {
        /// "Setting up…"
        case installing
        /// "Ready"
        case ready
        /// "Couldn't set up": the first line `sbx` wrote. Tried again by
        /// the user (`retry`) or at the next `started`.
        case failed(String)
        /// Not running: set up when it starts.
        case stopped
        /// Another agent's; not set up.
        case otherAgent
        /// The switch went off: Evlat's parts are coming out.
        case removing
        /// Evlat's parts are out.
        case removed
        /// The switch went off and taking them out failed: the first line
        /// `sbx` wrote. They may still be in the sandbox.
        case removalFailed(String)
    }

    struct Entry: Equatable {
        var agent: String?
        var running: Bool
        var setup: Setup
        /// The folder it was made in, as the list said it.
        var folder: String? = nil
    }

    struct Status: Equatable {
        var daemon: Daemon = .off
        /// The daemon's socket path does not fit a unix socket's address
        /// (`socketPathLimit`): no stream is opened, and the sandboxes
        /// running now are set up once.
        var socketTooLong = false
        /// The last `sbx ls --json` failed or could not be read.
        var listFailed = false
        /// `sbx version`'s, once read; `nil` until then or when it said none.
        var version: String?
        /// The sandboxes on this Mac, by name, as the last list said them.
        var sandboxes: [String: Entry] = [:]
    }

    private(set) var status = Status()

    private let runner: SandboxRunner
    private let plan: SandboxInstall
    private let agent: String
    private let forget: (String) -> Void
    private let onChange: () -> Void
    private var link: SandboxDaemonLink?
    /// Set up at the next list whatever their state: every running one on a
    /// connection (`everything`), one that just started (`started`).
    private var everything = false
    private var started: Set<String> = []
    /// A list was asked for while one ran: one more follows it.
    private var listAgain = false
    private var listing = false
    private var stopped = false
    private var removing = false
    private var removalTries = 0
    /// Running sandboxes whose removal waits for their job (an install)
    /// to end, asked again after `retryDelay`.
    private var removalWaiting: [String: SandboxInstall.Sandbox] = [:]
    /// A newer watcher took over (`abandon`): no removal is started or
    /// asked again from here.
    private var abandoned = false
    /// Sandboxes whose install was refused, asked again after `retryDelay`.
    private var refused: Set<String> = []
    static let retryDelay: TimeInterval = 1
    static let removalAttempts = 3

    /// `runner` may be shared with an earlier watcher, so a removal still
    /// running holds its sandbox against this one's install. `delay` is the
    /// test's reconnect schedule.
    init(runner: SandboxRunner, socketPath: String, plan: SandboxInstall,
         agent: String = Agents.sandboxAgent.rawValue,
         delay: @escaping (Int) -> TimeInterval = SandboxDaemon.delay(afterFailures:),
         forget: @escaping (String) -> Void, onChange: @escaping () -> Void) {
        self.runner = runner
        self.plan = plan
        self.agent = agent
        self.forget = forget
        self.onChange = onChange
        link = SandboxDaemonLink(
            socketPath: socketPath, delay: delay,
            onState: { [weak self] state in MainActor.assumeIsolated { self?.daemonChanged(state) } },
            onEvent: { [weak self] event in MainActor.assumeIsolated { self?.heard(event) } })
    }

    /// A unix socket's address holds 104 bytes, the last a NUL
    /// (`sockaddr_un.sun_path`). The real one measured 97.
    static let socketPathLimit = 103

    func start() {
        guard let link else { return }
        if link.socketPath.utf8.count > Self.socketPathLimit {
            // `NWConnection` would fail on every try, and the line would say
            // `sbx` is not running. Said as it is; what runs now is set up.
            self.link = nil
            status.socketTooLong = true
            everything = true
            askVersion()
            list()
            onChange()
            return
        }
        link.start()
    }

    /// Stops hearing the daemon. `removing`: the switch went off, and
    /// Evlat's parts come out of the running sandboxes, from a list read
    /// now — the runner's jobs keep the watcher alive until they are done.
    func stop(removing: Bool) {
        stopped = true
        self.removing = removing
        link?.stop()
        link = nil
        status.daemon = .off
        onChange()
        if removing { list() }
    }

    /// The switch went on again and a newer watcher sets the sandboxes
    /// up: this one's removal, waiting or to be read again, is let go —
    /// it would undo the newer one's install. A job already running ends,
    /// and the shared runner holds its sandbox against the newer install
    /// until it does.
    func abandon() {
        abandoned = true
        removing = false
        removalWaiting = [:]
    }

    private func remove(_ sandboxes: [SandboxInstall.Sandbox]) {
        guard !abandoned else { return }
        for sandbox in sandboxes where sandbox.isRunning && sandbox.agent == agent {
            let name = sandbox.name
            guard let commands = plan.uninstall(sandbox: name) else { continue }
            let began = runner.run(commands, sandbox: name) { [self] result in
                switch result {
                case .success:
                    status.sandboxes[name]?.setup = .removed
                case .failure(let failure) where failure.notRunning:
                    // Stopped before its turn: never `exec`ed, it keeps its parts.
                    status.sandboxes[name]?.setup = .stopped
                case .failure(let failure):
                    NSLog("Evlat: sandbox %@ not cleaned: %@", name, failure.reason)
                    status.sandboxes[name]?.setup = .removalFailed(failure.reason)
                }
                onChange()
            }
            if !began {
                // Its install is still running: the removal follows it, or
                // the file and the rule would stay in a running sandbox.
                waitForRemoval(sandbox)
            }
            status.sandboxes[name]?.setup = .removing
        }
        onChange()
    }

    private func waitForRemoval(_ sandbox: SandboxInstall.Sandbox) {
        let first = removalWaiting.isEmpty
        removalWaiting[sandbox.name] = sandbox
        guard first else { return }
        // Strong: the runner's jobs and this wait keep a retired watcher
        // alive until its removal is done. No process runs while it waits.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in
            // Those still busy come back here through `remove`.
            let waiting = Array(removalWaiting.values)
            removalWaiting = [:]
            guard !abandoned else { return }
            remove(waiting)
        }
    }

    /// The user's "Try Again" on a sandbox that could not be set up.
    func retry(_ name: String) {
        guard !stopped else { return }
        started.insert(name)
        list()
    }

    /// `sbx version`, once a watcher, before its first list: Settings says
    /// a version other than the one measured.
    private var versionAsked = false

    private func askVersion() {
        guard !versionAsked else { return }
        versionAsked = true
        runner.version { [weak self] version in
            guard let self, !self.stopped, version != self.status.version else { return }
            self.status.version = version
            self.onChange()
        }
    }

    // MARK: - The daemon

    private func daemonChanged(_ state: SandboxDaemonLink.State) {
        guard !stopped else { return }
        switch state {
        case .connecting: status.daemon = .connecting
        case .connected:
            status.daemon = .connected
            everything = true
            askVersion()
            list()
        case .disconnected: status.daemon = .disconnected
        case .refused: status.daemon = .refused
        }
        onChange()
    }

    private func heard(_ event: SandboxEvent) {
        guard !stopped else { return }
        switch event.action {
        case .started:
            started.insert(event.name)
            list()
        case .created:
            list()
        case .stopped:
            forget(event.name)
            if status.sandboxes[event.name] != nil {
                status.sandboxes[event.name]?.running = false
                if status.sandboxes[event.name]?.setup != .otherAgent {
                    status.sandboxes[event.name]?.setup = .stopped
                }
            }
            onChange()
        case .deleted:
            forget(event.name)
            status.sandboxes[event.name] = nil
            onChange()
        case .unknown:
            break
        }
    }

    // MARK: - The list

    /// One list at a time; one asked for meanwhile follows it.
    private func list() {
        guard !listing else {
            listAgain = true
            return
        }
        listing = true
        runner.list { [self] sandboxes in
            listing = false
            listed(sandboxes)
        }
    }

    private func listed(_ sandboxes: [SandboxInstall.Sandbox]?) {
        if stopped {
            guard removing else { return }
            if let sandboxes {
                removing = false
                remove(sandboxes)
            } else if removalTries < Self.removalAttempts {
                // A failed list must not leave Evlat's parts behind
                // unasked: it is read again, a few times.
                removalTries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in list() }
            } else {
                removing = false
                status.listFailed = true
                NSLog("Evlat: sandboxes not cleaned, sbx ls failed")
                onChange()
            }
            return
        }
        defer {
            if listAgain {
                listAgain = false
                list()
            }
            onChange()
        }
        guard let sandboxes else {
            status.listFailed = true
            return
        }
        status.listFailed = false
        let named = sandboxes.filter { SandboxInstall.isSandboxName($0.name) }
        let present = Set(named.map(\.name))
        for gone in status.sandboxes.keys where !present.contains(gone) {
            forget(gone)
            status.sandboxes[gone] = nil
        }
        let everything = self.everything
        self.everything = false
        for sandbox in named {
            let name = sandbox.name
            let previous = status.sandboxes[name]?.setup
            let wanted = everything || started.contains(name)
            started.remove(name)
            var entry = Entry(agent: sandbox.agent, running: sandbox.isRunning, setup: previous ?? .stopped,
                              folder: sandbox.workspace)
            if sandbox.agent != agent {
                entry.setup = .otherAgent
            } else if !sandbox.isRunning {
                forget(name)
                entry.setup = .stopped
            } else if previous == .installing {
                // Its run is on the way.
            } else if wanted || previous == nil || previous == .stopped {
                if install(name) {
                    entry.setup = .installing
                } else {
                    // Its sandbox has a job running (a removal, an earlier
                    // install): asked again once that is likely done.
                    retryLater(name)
                }
            }
            status.sandboxes[name] = entry
        }
    }

    private func retryLater(_ name: String) {
        guard refused.insert(name).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.refused.remove(name)
            self.started.insert(name)
            self.list()
        }
    }

    /// Starts `name`'s install; `false` when it has a job running.
    private func install(_ name: String) -> Bool {
        guard let commands = plan.install(sandbox: name) else { return false }
        return runner.run(commands, sandbox: name) { [weak self] result in
            guard let self, !self.stopped, self.status.sandboxes[name]?.setup == .installing else { return }
            switch result {
            case .success: self.status.sandboxes[name]?.setup = .ready
            case .failure(let failure) where failure.notRunning:
                // Stopped before its turn: nothing was run, set up when it starts.
                self.forget(name)
                self.status.sandboxes[name]?.running = false
                self.status.sandboxes[name]?.setup = .stopped
            case .failure(let failure): self.status.sandboxes[name]?.setup = .failed(failure.reason)
            }
            self.onChange()
        }
    }

    // MARK: - Where

    /// The daemon's socket under `home`, where `sbx daemon status` says it
    /// is (0.46.0).
    nonisolated static func defaultSocket(home: URL) -> String {
        home.appendingPathComponent("Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/sandboxd.sock").path
    }

    /// Where `sbx` and the daemon are, or `nil` for none: `EVLAT_SBX` and
    /// `EVLAT_SBX_SOCKET` when given. An isolated process (`EVLAT_PORT`)
    /// gets them only when both are given — it must never change the
    /// user's sandboxes by accident — and a controller with no home (every
    /// test) never falls through to the real socket.
    nonisolated static func source(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL?) -> Source? {
        let value = { (name: String) -> String? in
            let raw = environment[name]?.trimmingCharacters(in: .whitespaces) ?? ""
            return raw.isEmpty ? nil : (raw as NSString).expandingTildeInPath
        }
        let sbx = value("EVLAT_SBX"), socket = value("EVLAT_SBX_SOCKET")
        if value("EVLAT_PORT") != nil {
            guard let sbx, let socket else { return nil }
            return Source(sbx: sbx, socket: socket)
        }
        guard let socket = socket ?? home.map(defaultSocket) else { return nil }
        return Source(sbx: sbx, socket: socket)
    }
}
