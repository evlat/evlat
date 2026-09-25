import AppKit
import EvlatCore

/// The remote machines' transport: per machine, a loopback listener and the
/// `ssh` process that carries the server's `127.0.0.1:48151` onto it.
///
/// Everything with a rule in it is `EvlatCore.RemoteTunnel` — arguments,
/// schedule, failure classes, the state machine. What is left here is what
/// the core must not touch: the socket, the process, the pipes and the
/// workspace's sleep notifications.
///
/// **Main queue only**, like the providers it feeds: the listener delivers on
/// the main queue, the process's exit is hopped there, and the notifications
/// are observed there.
final class RemoteTunnels {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

    /// The app's deferred call: a cancellable block on the main queue.
    static let mainQueueSchedule: Schedule = { delay, run in
        let item = DispatchWorkItem(block: run)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    /// One machine's parts. The listener and the tunnel hold it weakly, so
    /// dropping it from `links` ends it.
    private final class Link {
        let machine: RemoteMachine
        let hooks: HooksProvider
        let usage: ClaudeUsageProvider
        /// The machine's outside rows (`013`), namespaced by its id.
        let signals: SignalsProvider
        /// What the machine's `/signal` asks for; fixed for the link's life.
        let signalKey: String
        var listener: HookListener?
        var tunnel: RemoteTunnel?
        var process: SSHProcess?
        /// The listener's bound port, once it has one; `ssh` is not started
        /// before, since the port is in its arguments.
        var port: UInt16?

        init(machine: RemoteMachine, hooks: HooksProvider, usage: ClaudeUsageProvider,
             signals: SignalsProvider, signalKey: String) {
            self.machine = machine
            self.hooks = hooks
            self.usage = usage
            self.signals = signals
            self.signalKey = signalKey
        }
    }

    private let registry: Registry
    private let sshPath: String
    private let platform: Platform
    private let now: () -> Date
    private let confirmAfter: TimeInterval
    private let schedule: Schedule
    private let onChange: () -> Void
    private var links: [String: Link] = [:]
    private var order: [String] = []
    private var observers: [NSObjectProtocol] = []
    private let workspace: NotificationCenter

    /// `sshPath` is handed in, never looked up here: a test gives the fake's
    /// path, and only `AppController` reads `EVLAT_SSH`. `onChange` is called
    /// whenever a row may read differently — an arrival or a link change.
    init(registry: Registry, sshPath: String, platform: Platform, now: @escaping () -> Date,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         confirmAfter: TimeInterval = RemoteTunnel.defaultConfirmAfter,
         schedule: @escaping Schedule = RemoteTunnels.mainQueueSchedule,
         onChange: @escaping () -> Void) {
        self.registry = registry
        self.sshPath = sshPath
        self.platform = platform
        self.now = now
        self.workspace = workspace
        self.confirmAfter = confirmAfter
        self.schedule = schedule
        self.onChange = onChange
        // Closed before sleep so the server lets go of the remote port at
        // once; reopened on wake without waiting out a pending retry.
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.sleep()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.wake()
        })
    }

    deinit {
        observers.forEach(workspace.removeObserver)
    }

    var machines: [RemoteMachine] { order.compactMap { links[$0]?.machine } }

    func state(of id: String) -> RemoteTunnel.State? { links[id]?.tunnel?.state }

    func listenerStatus(of id: String) -> HookListener.Status? { links[id]?.listener?.status }

    /// `nil` when there is no such machine or no process has been started.
    func isProcessRunning(of id: String) -> Bool? { links[id]?.process?.isRunning }

    func processIdentifier(of id: String) -> Int32? { links[id]?.process?.processIdentifier }

    /// The key the machine's `/signal` asks for; what its server's command
    /// is installed with.
    func signalKey(of id: String) -> String? { links[id]?.signalKey }

    /// Registers the machine's providers and opens its tunnel as soon as its
    /// listener is bound. A machine already present is left as it is.
    ///
    /// `key` is the machine's own (`RemoteMachine.signalKeys`): its listener
    /// answers `/signal` with it and with no other — not this Mac's, not
    /// another machine's. Required, so no machine's listener is left with a
    /// `/signal` that silently answers `404`.
    func add(_ machine: RemoteMachine, key: String) {
        guard links[machine.id] == nil else { return }
        let link = Link(machine: machine,
                        hooks: HooksProvider(platform: platform, machine: machine.identity),
                        usage: ClaudeUsageProvider(now: now, machine: machine.identity),
                        signals: SignalsProvider(now: now, machine: machine.identity),
                        signalKey: key)
        let tunnel = RemoteTunnel(effects: RemoteTunnel.Effects(
            launch: { [weak self, weak link] generation in
                guard let self, let link else { return }
                self.launch(link, generation: generation)
            },
            terminate: { [weak link] in link?.process?.terminate() },
            now: now,
            schedule: schedule), confirmAfter: confirmAfter)
        let onChange = self.onChange
        tunnel.onChange = { [weak link] state in
            guard let link else { return }
            link.hooks.setLink(connected: state.isConnected)
            link.signals.setLink(connected: state.isConnected)
            // The tunnel's trace on stderr, like the rows' (`refresh`).
            NSLog("Evlat: tunnel %@ %@", link.machine.name, state.text)
            onChange()
        }
        link.tunnel = tunnel
        link.listener = HookListener(
            port: 0,
            origin: .tunneled,
            signalKey: { _ in key },
            onStatus: { [weak link] status in
                guard let link else { return }
                switch status {
                case .listening(let port) where link.port == nil:
                    link.port = port
                    NSLog("Evlat: machine %@ listening on 127.0.0.1:%d", link.machine.name, Int(port))
                    link.tunnel?.start()
                case .unavailable:
                    NSLog("Evlat: machine %@ listener %@", link.machine.name, status.text)
                default:
                    break
                }
            },
            onDelivery: { [weak link] delivery in
                guard let link else { return }
                // Before the delivery: the row the event lands on is stamped
                // after the link's mark, so it is not dimmed as "not heard
                // since the tunnel came up" (`HooksProvider.dim`).
                link.tunnel?.heard()
                switch delivery {
                case .hook(let event): link.hooks.handle(event)
                case .usage(let report): link.usage.handle(report)
                // A tunnel answers `/permission` with `404` (`LocalAPI`):
                // a remote machine never puts a card in front of this user.
                case .permission: break
                // The machine's own outside row (`013`): the listener has
                // already checked the machine's key. A dropped row is said on
                // stderr like a local one, with the machine's name.
                case .signal(let report):
                    if case .dropped(let limit) = link.signals.apply(report) {
                        FileHandle.standardError.write(Data(AppController.droppedSignalLine(
                            id: report.id, limit: limit, machine: link.machine.name).utf8))
                    }
                }
                onChange()
            })
        links[machine.id] = link
        order.append(machine.id)
        registry.register(link.hooks)
        registry.register(link.usage)
        registry.register(link.signals)
        link.listener?.start()
    }

    /// Closes the machine's tunnel and listener and takes its rows away.
    func remove(id: String) {
        guard let link = links.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        close(link)
        registry.unregister(link.hooks)
        registry.unregister(link.usage)
        registry.unregister(link.signals)
        onChange()
    }

    /// Every tunnel closed: the app is quitting. The pipe would end them
    /// anyway when this process goes; this is the orderly half.
    func stopAll() {
        links.values.forEach(close)
    }

    func sleep() {
        links.values.forEach { $0.tunnel?.sleep() }
    }

    func wake() {
        links.values.forEach { $0.tunnel?.wake() }
    }

    private func close(_ link: Link) {
        link.tunnel?.stop()
        link.listener?.stop()
    }

    private func launch(_ link: Link, generation: Int) {
        guard let port = link.port, let tunnel = link.tunnel else { return }
        let process = SSHProcess(path: sshPath,
                                 arguments: RemoteTunnel.arguments(target: link.machine.target, localPort: port)) {
            [weak tunnel] stderr in
            tunnel?.exited(generation: generation, stderr: stderr)
        }
        link.process = process
        if let failure = process.run() {
            tunnel.exited(generation: generation, stderr: failure)
        }
    }
}

/// One `ssh` process: stdin a pipe this process holds open, stdout thrown
/// away, the tail of stderr kept for the failure class.
///
/// The stdin pipe is the tunnel's dead man's switch. Nothing is ever written
/// to it; when this process ends — `kill -9` included — the kernel closes our
/// end, the remote `cat` reads EOF, and `ssh` exits with it.
final class SSHProcess {
    private let process = Process()
    private let input = Pipe()
    private let errors = Pipe()
    private let tail = StderrTail()
    private let onExit: (String) -> Void

    /// `onExit` is called once, on the main queue, with the tail of stderr.
    init(path: String, arguments: [String], onExit: @escaping (String) -> Void) {
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    /// Starts the process: `nil`, or why it could not start (then `onExit`
    /// is never called).
    func run() -> String? {
        let tail = self.tail
        let stderrClosed = DispatchSemaphore(value: 0)
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty else { return tail.append(data) }
            // EOF: the handler would otherwise be called again and again.
            handle.readabilityHandler = nil
            if tail.finish() { stderrClosed.signal() }
        }
        let onExit = self.onExit
        process.terminationHandler = { _ in
            // The exit can be reported before the last of stderr is read;
            // the line that names the failure is usually that last one.
            _ = stderrClosed.wait(timeout: .now() + 1)
            let text = tail.text
            DispatchQueue.main.async { onExit(text) }
        }
        do {
            try process.run()
            return nil
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            return error.localizedDescription
        }
    }

    /// Our end of stdin, closed: what the kernel does when Evlat dies.
    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    /// Closed cleanly: EOF first — `ssh` ends the session and the server
    /// lets go of the port — then a SIGTERM for a network that is already
    /// gone and would keep `ssh` waiting on its keepalive.
    func terminate() {
        closeInput()
        if process.isRunning { process.terminate() }
    }
}

/// The last bytes of a process's stderr. Written from the pipe's reading thread,
/// read from the exit handler's; bounded, because a long-lived process
/// may write a warning now and then for days. Shared by `SSHProcess` and
/// `ClaudeRunner`.
final class StderrTail {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private static let limit = 2048

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > Self.limit { data = Data(data.suffix(Self.limit)) }
        }
    }

    /// `true` the first time only.
    func finish() -> Bool {
        lock.withLock {
            defer { finished = true }
            return !finished
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
