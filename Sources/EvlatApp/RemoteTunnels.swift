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
        /// The machine's outside rows, namespaced by its id.
        let signals: SignalsProvider
        /// What the machine's `/signal` asks for; fixed for the link's life.
        let signalKey: String
        var listener: HookListener?
        var tunnel: RemoteTunnel?
        var process: SSHProcess?
        /// The listener's bound port, once it has one; `ssh` is not started
        /// before, since the port is in its arguments.
        var port: UInt16?
        /// The socket the running process is master on; `nil` when it runs
        /// without one.
        var controlPath: String?
        /// The first try asks the user: the machine was just added.
        var startInteractive = false
        /// The tunnel was started: once, when both listeners were ready.
        var started = false
        /// A password is in the store for the machine, as last read or
        /// written: what a quiet try's refused prompt is weighed against.
        var hasStoredPassword = false
        /// The running try's launch.
        var generation = 0
        /// The stored password was looked up for this try's first password
        /// prompt; never for a second.
        var usedStoredPassword = false
        /// The stored password went: a password typed on the same try is
        /// another host's (a jump host's), never the machine's to keep.
        var sentStoredPassword = false
        /// What the user typed at this try's password prompt, the prompt, and
        /// whether to keep it: in memory for the try alone, stored once connected.
        var typed: (password: String, prompt: String, remember: Bool)?

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
    private let socketDirectory: String
    private let environment: [String: String]
    private let platform: Platform
    private let now: () -> Date
    private let confirmAfter: TimeInterval
    private let schedule: Schedule
    private let onChange: () -> Void
    private var links: [String: Link] = [:]
    private var order: [String] = []
    private var observers: [NSObjectProtocol] = []
    private let workspace: NotificationCenter
    private let askpass: AskpassRoute?
    private let store: SSHPasswordStore
    /// Askpass token → the try it was made for.
    private var tokens: [String: (id: String, generation: Int)] = [:]

    /// An `ssh` question for the user, held until it is answered
    /// (`answer(_:with:remember:)`). The text is `ssh`'s, verbatim.
    struct Prompt: Equatable {
        /// The held request's id (`Askpass.Request.id`).
        let id: String
        let machineID: String
        let machine: String
        let text: String
        let generation: Int

        var isPassword: Bool { Askpass.isPassword(text) }
        var isYesNo: Bool { Askpass.isYesNo(text) }
    }

    /// The questions waiting for the user, oldest first; the window shows
    /// the first.
    private(set) var prompts: [Prompt] = []
    /// Called when `prompts` changes.
    var onPromptsChanged: () -> Void = {}
    /// Answers a held `/askpass` request (`HookListener.answer`).
    var respond: (String, LocalAPI.Response) -> Void = { _, _ in }

    /// What `ssh` needs to ask Evlat: the helper (this binary) and the port
    /// of the listener that holds `/askpass`. Without a port, no askpass.
    struct AskpassRoute {
        let binary: String
        let port: () -> UInt16?
        /// Whether that listener is done binding — bound, or refused its
        /// port. Until then no try starts: one started now would run
        /// without askpass, and a password server would fail it for
        /// nothing. `askpassSettled()` is the call that says it changed.
        var settled: () -> Bool = { true }
    }

    /// `sshPath` is handed in, never looked up here: a test gives the fake's
    /// path, and only `AppController` reads `EVLAT_SSH`. `socketDirectory`
    /// holds the masters' sockets, one per machine; a path, never a constant
    /// here, and short (`RemoteTunnel.socketPathLimit`). `environment` is
    /// what `ssh` is started with, the tunnel's own variables added.
    /// `onChange` is called whenever a row may read differently — an arrival
    /// or a link change.
    init(registry: Registry, sshPath: String, platform: Platform, now: @escaping () -> Date,
         socketDirectory: String,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         confirmAfter: TimeInterval = RemoteTunnel.defaultConfirmAfter,
         schedule: @escaping Schedule = RemoteTunnels.mainQueueSchedule,
         askpass: AskpassRoute? = nil,
         store: SSHPasswordStore = MemoryPasswordStore(),
         onChange: @escaping () -> Void) {
        self.registry = registry
        self.askpass = askpass
        self.store = store
        self.sshPath = sshPath
        self.socketDirectory = socketDirectory
        self.environment = environment
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

    /// The socket of the machine's running master: what its installs and
    /// reads ride (`RemoteInstaller`). `nil` while no process runs or it runs
    /// without one.
    func controlPath(of id: String) -> String? {
        guard let link = links[id], link.process?.isRunning == true else { return nil }
        return link.controlPath
    }

    /// The key the machine's `/signal` asks for; what its server's command
    /// is installed with.
    func signalKey(of id: String) -> String? { links[id]?.signalKey }

    /// The machine is known to want a password (`RemoteTunnel.asksForPassword`).
    func asksForPassword(of id: String) -> Bool { links[id]?.tunnel?.asksForPassword ?? false }

    /// "Enter Password…": an interactive try now (`RemoteTunnel.retryByUser`).
    func retryByUser(id: String) { links[id]?.tunnel?.retryByUser() }

    /// Registers the machine's providers and opens its tunnel as soon as its
    /// listener is bound. A machine already present is left as it is.
    ///
    /// `key` is the machine's own (`RemoteMachine.signalKeys`): its listener
    /// answers `/signal` with it and with no other — not this Mac's, not
    /// another machine's. Required, so no machine's listener is left with a
    /// `/signal` that silently answers `404`.
    ///
    /// `interactive`: the first try asks the user (a machine just added);
    /// one restored at launch tries quietly.
    func add(_ machine: RemoteMachine, key: String, interactive: Bool = false) {
        guard links[machine.id] == nil else { return }
        let link = Link(machine: machine,
                        hooks: HooksProvider(platform: platform, machine: machine.identity),
                        usage: ClaudeUsageProvider(now: now, machine: machine.identity),
                        signals: SignalsProvider(now: now, machine: machine.identity),
                        signalKey: key)
        link.startInteractive = interactive
        let tunnel = RemoteTunnel(effects: RemoteTunnel.Effects(
            launch: { [weak self, weak link] generation in
                guard let self, let link else { return }
                self.launch(link, generation: generation)
            },
            terminate: { [weak link] in link?.process?.terminate() },
            now: now,
            schedule: schedule,
            hasStoredPassword: { [weak link] in link?.hasStoredPassword ?? false }), confirmAfter: confirmAfter)
        let onChange = self.onChange
        tunnel.onChange = { [weak self, weak link] state in
            guard let link else { return }
            if state.isConnected { self?.keepTypedPassword(link) }
            // The one password a try sends was refused: whichever it was
            // — the stored one, or a typed one kept by a too-early
            // "connected" — it is not kept, so "Enter Password…" asks.
            if state == .needsUser(rejected: true) { self?.forgetPassword(link) }
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
            onStatus: { [weak self, weak link] status in
                guard let link else { return }
                switch status {
                case .listening(let port) where link.port == nil:
                    link.port = port
                    NSLog("Evlat: machine %@ listening on 127.0.0.1:%d", link.machine.name, Int(port))
                    self?.startIfReady(link)
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
                // A tunnel answers `/permission` and `/askpass` with `404`
                // (`LocalAPI`): a remote machine never puts a card in front
                // of this user, nor asks for a password.
                case .permission, .approval, .askpass: break
                // The machine's own outside row: the listener has
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
        store.password(for: machine.id) { [weak link] password in link?.hasStoredPassword = password != nil }
        link.listener?.start()
    }

    /// Closes the machine's tunnel and listener and takes its rows away.
    func remove(id: String) {
        guard let link = links.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        endAttempt(of: link, generation: nil)
        close(link)
        // Its password goes with it; an id is never reused.
        store.delete(for: id)
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

    /// This Mac's listener is done binding (`AskpassRoute.settled`): the
    /// tries that waited for it start.
    func askpassSettled() {
        order.compactMap { links[$0] }.forEach(startIfReady)
    }

    /// The first try, once the machine's listener has its port and this
    /// Mac's listener is settled — whichever comes last starts it.
    private func startIfReady(_ link: Link) {
        guard !link.started, link.port != nil, askpass?.settled() ?? true else { return }
        link.started = true
        link.tunnel?.start(interactive: link.startInteractive)
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
        let controlPath = masterSocket(for: link.machine)
        link.controlPath = controlPath
        link.generation = generation
        link.usedStoredPassword = false
        link.sentStoredPassword = false
        link.typed = nil
        let asking = askpassEnvironment(for: link, generation: generation)
        let process = SSHProcess(path: sshPath,
                                 arguments: RemoteTunnel.arguments(target: link.machine.target, localPort: port,
                                                                   controlPath: controlPath, askpass: asking != nil),
                                 environment: RemoteTunnel.environment(base: environment, askpass: asking)) {
            [weak self, weak link, weak tunnel] stderr in
            // The try's questions go with it, before the tunnel hears why.
            if let self, let link { self.endAttempt(of: link, generation: generation) }
            tunnel?.exited(generation: generation, stderr: stderr)
        }
        link.process = process
        if let failure = process.run() {
            endAttempt(of: link, generation: generation)
            tunnel.exited(generation: generation, stderr: failure)
        }
    }

    /// The tunnel's askpass variables, with a token new to this try; `nil`
    /// — and `BatchMode=yes` — while this Mac's listener has no port.
    private func askpassEnvironment(for link: Link, generation: Int) -> [String: String]? {
        guard let askpass, let port = askpass.port() else { return nil }
        let token = SignalKey.generate()
        tokens[token] = (link.machine.id, generation)
        return ["SSH_ASKPASS": askpass.binary,
                "SSH_ASKPASS_REQUIRE": "force",
                Askpass.environmentKey: Askpass.value(Askpass.Mark(port: port, token: token))]
    }

    /// The try `generation` (every try: `nil`) is over: its token answers
    /// nothing more, and its held questions are let go — the window drops
    /// them. The tunnel is told nothing here; its own exit report follows.
    private func endAttempt(of link: Link, generation: Int?) {
        tokens = tokens.filter { !($0.value.id == link.machine.id && (generation == nil || $0.value.generation == generation)) }
        let dropped = prompts.filter { $0.machineID == link.machine.id && (generation == nil || $0.generation == generation) }
        guard !dropped.isEmpty else { return }
        prompts.removeAll { prompt in dropped.contains(prompt) }
        dropped.forEach { respond($0.id, LocalAPI.noAnswer) }
        onPromptsChanged()
    }

    private func forgetPassword(_ link: Link) {
        link.typed = nil
        link.hasStoredPassword = false
        store.delete(for: link.machine.id)
    }

    /// A password typed on this try, with "Remember" on, is stored once the
    /// try connected — never before: a refused one is never kept. With
    /// "Remember" off, the one stored before goes: the user chose not to
    /// keep a password for the machine. A try that also sent the stored one
    /// logged in with two passwords; the stored one stays as it is.
    private func keepTypedPassword(_ link: Link) {
        guard let typed = link.typed else { return }
        link.typed = nil
        guard !link.sentStoredPassword else { return }
        guard typed.remember else {
            link.hasStoredPassword = false
            store.delete(for: link.machine.id)
            return
        }
        store.save(StoredPassword(password: typed.password, prompt: typed.prompt),
                   for: link.machine.id, target: link.machine.target)
        link.hasStoredPassword = true
    }
}

// MARK: - Askpass

extension RemoteTunnels {
    /// A helper's prompt (`/askpass`, already held by the listener). A token
    /// no running try has is refused. The prompt the stored password was
    /// typed at takes it, once per try; on a quiet try every other prompt is refused;
    /// on an interactive one it waits for the user (`prompts`).
    func ask(_ request: Askpass.Request) {
        // A try halted by a sleep keeps its token until its exit is
        // reported; its questions are no longer anyone's.
        guard let owner = tokens[request.token], let link = links[owner.id], let tunnel = link.tunnel,
              link.generation == owner.generation, tunnel.state == .connecting else {
            return respond(request.id, LocalAPI.noAnswer)
        }
        let generation = owner.generation
        tunnel.promptOpened()
        let password = Askpass.isPassword(request.prompt)
        // The store is asked, not `hasStoredPassword`: at launch its
        // answer may not have come back yet.
        guard password, !link.usedStoredPassword else {
            return route(request, link: link, generation: generation, password: password)
        }
        link.usedStoredPassword = true
        store.password(for: link.machine.id) { [weak self, weak link] stored in
            guard let self, let link, link.generation == generation, self.tokens[request.token] != nil else {
                self?.respond(request.id, LocalAPI.noAnswer)
                return
            }
            guard let stored, stored.answers(request.prompt) else {
                // Another host's prompt (a jump host's) is asked as if
                // nothing were stored; the machine's own may still follow.
                link.hasStoredPassword = stored != nil
                link.usedStoredPassword = false
                return self.route(request, link: link, generation: generation, password: true)
            }
            link.hasStoredPassword = true
            link.sentStoredPassword = true
            self.respond(request.id, LocalAPI.Response(status: .ok, body: stored.password))
            link.tunnel?.promptAnswered(sentPassword: true)
        }
    }

    private func route(_ request: Askpass.Request, link: Link, generation: Int, password: Bool) {
        guard link.tunnel?.mode == .interactive else {
            respond(request.id, LocalAPI.noAnswer)
            link.tunnel?.promptRefused(password: password)
            return
        }
        prompts.append(Prompt(id: request.id, machineID: link.machine.id, machine: link.machine.name,
                              text: request.prompt, generation: generation))
        onPromptsChanged()
    }

    /// The user's answer to a held question; `nil` is a refusal (Cancel,
    /// Esc, the window closed). `remember` is the password's box.
    func answer(_ id: String, with text: String?, remember: Bool = false) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        let prompt = prompts.remove(at: index)
        onPromptsChanged()
        guard let link = links[prompt.machineID], link.generation == prompt.generation else {
            return respond(id, LocalAPI.noAnswer)
        }
        guard let text else {
            respond(id, LocalAPI.noAnswer)
            link.tunnel?.promptRefused(password: prompt.isPassword)
            return
        }
        respond(id, LocalAPI.Response(status: .ok, body: text))
        if prompt.isPassword { link.typed = (text, prompt.text, remember) }
        link.tunnel?.promptAnswered(sentPassword: prompt.isPassword)
    }

    /// The helper went away before an answer (`ssh` gave up): its
    /// question leaves the window.
    func abandoned(_ id: String) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        let prompt = prompts.remove(at: index)
        onPromptsChanged()
        guard let link = links[prompt.machineID], link.generation == prompt.generation else { return }
        link.tunnel?.promptRefused(password: prompt.isPassword)
    }
}

extension RemoteTunnels {
    /// The path the machine's next master listens on, made ready: the
    /// directory there and the user's alone, a file a dead master left
    /// cleared. `nil` — run without a master — when no path fits, the
    /// directory cannot be made, or the socket answers: a live master there
    /// is another process's (a second Evlat), and is not touched.
    private func masterSocket(for machine: RemoteMachine) -> String? {
        guard let path = RemoteTunnel.controlPath(directory: socketDirectory, machineID: machine.id) else {
            NSLog("Evlat: machine %@ runs without a master: %@ is too long for a socket",
                  machine.name, socketDirectory)
            return nil
        }
        do {
            // Every launch: `$TMPDIR` is swept, and the mode is only set on
            // creation.
            try FileManager.default.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory)
        } catch {
            NSLog("Evlat: machine %@ runs without a master: %@", machine.name, error.localizedDescription)
            return nil
        }
        switch Self.probe(socket: path) {
        case .absent:
            return path
        case .stale:
            unlink(path)
            return path
        case .live:
            NSLog("Evlat: machine %@ runs without a master: %@ is in use", machine.name, path)
            return nil
        case .unknown(let code):
            NSLog("Evlat: machine %@ runs without a master: %@: %@",
                  machine.name, path, String(cString: strerror(code)))
            return nil
        }
    }

    enum SocketState: Equatable {
        case absent
        /// A file nobody listens on: its master was killed.
        case stale
        case live
        /// Anything else: left alone.
        case unknown(Int32)
    }

    /// Whether something answers at `path`, by connecting to it. Only
    /// `ENOENT` and `ECONNREFUSED` say the file may go.
    static func probe(socket path: String) -> SocketState {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown(errno) }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return .unknown(ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { return .live }
        switch errno {
        case ENOENT: return .absent
        case ECONNREFUSED: return .stale
        case let code: return .unknown(code)
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
    /// `environment` `nil` is this process's own.
    init(path: String, arguments: [String], environment: [String: String]? = nil,
         onExit: @escaping (String) -> Void) {
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
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
