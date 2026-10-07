import AppKit
import EvlatCore
import EvlatAgents

/// The remote machines' transport: per machine, a listener on a socket of
/// its own (`RemoteTunnel.channelPath`), the `ssh` master, and the channel
/// over it that carries the server's socket onto that listener.
///
/// Everything with a rule in it is `EvlatCore.RemoteTunnel` — arguments,
/// schedule, failure classes, the probe, the state machine. What is left here
/// is what the core must not touch: the socket, the process, the pipes, the
/// calls over the master (`RemoteInstaller`) and the workspace's sleep
/// notifications.
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
        /// Its `agents` follow the cards' switches (`setAgents`).
        var machine: RemoteMachine
        let hooks: HooksProvider
        /// One per agent switched on whose usage a status line posts; an
        /// agent switched off has none, so its windows go with it.
        var usage: [AgentID: StatusLineUsageProvider] = [:]
        /// The machine's outside rows, namespaced by its id.
        let signals: SignalsProvider
        var listener: HookListener?
        var tunnel: RemoteTunnel?
        var process: SSHProcess?
        /// The listener's bound socket — the channel's end here — once it
        /// has one; `ssh` is not started before, since the forward names it.
        var endpoint: String?
        /// What the channel's last probe read on the server.
        var reading: RemoteSettings.Reading?
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

        init(machine: RemoteMachine, hooks: HooksProvider, signals: SignalsProvider) {
            self.machine = machine
            self.hooks = hooks
            self.signals = signals
        }
    }

    private let registry: Registry
    private let sshPath: String
    private let socketDirectory: String
    private let environment: [String: String]
    private let platform: Platform
    private let now: () -> Date
    private let channelDeadline: TimeInterval
    private let installer: RemoteInstaller
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
    /// A machine was read by its channel's probe (`reading(of:)`).
    var onReading: (String) -> Void = { _ in }
    /// A server's session asks for approval: the request, stamped with the
    /// machine whose listener holds it. Answered with `answerApproval`.
    var onApproval: (HeldRequest) -> Void = { _ in }
    /// Every hook event a machine's listener heard, with the machine's id,
    /// before its row is moved: what shows a held request answered there.
    var onHeard: (HookEvent, String) -> Void = { _, _ in }
    /// A held approval's connection closed first: Esc on the server, its
    /// hook's time ran out, or the channel went.
    var onAbandoned: (String) -> Void = { _ in }

    /// What `ssh` needs to ask Evlat: the helper (this binary) and the
    /// socket of the listener that holds `/askpass`. Without a socket, no
    /// askpass.
    struct AskpassRoute {
        let binary: String
        let socket: () -> String?
        /// Whether that listener is done binding — bound, or refused its
        /// port. Until then no try starts: one started now would run
        /// without askpass, and a password server would fail it for
        /// nothing. `askpassSettled()` is the call that says it changed.
        var settled: () -> Bool = { true }
    }

    /// `sshPath` is handed in, never looked up here: a test gives the fake's
    /// path, and only `AppController` reads `EVLAT_SSH`. `socketDirectory`
    /// holds the masters' sockets and the channels' ends, two per machine; a
    /// path, never a constant here, and short (`RemoteTunnel.socketPathLimit`).
    /// `environment` is what `ssh` is started with, the tunnel's own
    /// variables added. `installer` runs the calls over a master — the
    /// settings window's own (`RemoteInstaller.channel`, `forward`).
    /// `onChange` is called whenever a row may read differently — an arrival
    /// or a link change.
    init(registry: Registry, sshPath: String, platform: Platform, now: @escaping () -> Date,
         socketDirectory: String,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         channelDeadline: TimeInterval = RemoteTunnel.defaultChannelDeadline,
         schedule: @escaping Schedule = RemoteTunnels.mainQueueSchedule,
         askpass: AskpassRoute? = nil,
         store: SSHPasswordStore = MemoryPasswordStore(),
         installer: RemoteInstaller? = nil,
         onChange: @escaping () -> Void) {
        self.installer = installer ?? RemoteInstaller(sshPath: sshPath)
        self.registry = registry
        self.askpass = askpass
        self.store = store
        self.sshPath = sshPath
        self.socketDirectory = socketDirectory
        self.environment = environment
        self.platform = platform
        self.now = now
        self.workspace = workspace
        self.channelDeadline = channelDeadline
        self.schedule = schedule
        self.onChange = onChange
        // Closed before sleep so the server lets go of the channel at
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

    /// The running tunnel's pid; `nil` once it has exited — its pid may be
    /// another process's by then (`Ssh.candidates` reads its sockets).
    func processIdentifier(of id: String) -> Int32? {
        guard let process = links[id]?.process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    /// The socket of the machine's running master: what its installs and
    /// reads ride (`RemoteInstaller`). `nil` while no process runs or it runs
    /// without one.
    func controlPath(of id: String) -> String? {
        guard let link = links[id], link.process?.isRunning == true else { return nil }
        return link.controlPath
    }

    /// What the machine's channel read on the server when it was last made
    /// (`RemoteSettings.readingScript`, probing); `nil` before.
    func reading(of id: String) -> RemoteSettings.Reading? { links[id]?.reading }

    /// The machine's enabled agents (`RemoteMachine.enabledAgents`); `nil`
    /// for no such machine, or while it follows every agent.
    func enabledAgents(of id: String) -> Set<AgentID>? {
        guard let machine = links[id]?.machine, machine.agents != nil else { return nil }
        return machine.enabledAgents(of: Agents.all.ids)
    }

    /// The machine's switches changed: kept on its entry (what the list
    /// stores) and its usage providers brought in line.
    func setAgents(_ agents: [String]?, of id: String) {
        guard let link = links[id] else { return }
        link.machine.agents = agents
        syncUsage(link)
        onChange()
    }

    /// A usage provider per agent on with a status line, none for the rest.
    /// Which agents a server actually relays is its install's business
    /// (`RemoteSettings.relays`): a provider nothing posts to draws nothing.
    private func syncUsage(_ link: Link) {
        let wanted = link.machine.enabledAgents(of: Agents.all.ids).filter { $0.agent.statusLineUsage != nil }
        for (source, provider) in link.usage where !wanted.contains(source) {
            registry.unregister(provider)
            link.usage[source] = nil
        }
        for agent in Agents.all where wanted.contains(agent.id) && link.usage[agent.id] == nil {
            guard let usage = agent.statusLineUsage else { continue }
            let source = agent.id
            let provider = StatusLineUsageProvider(now: now, machine: link.machine.identity, source: source,
                                                   usage: usage)
            link.usage[source] = provider
            registry.register(provider)
        }
    }

    /// The machine is known to want a password (`RemoteTunnel.asksForPassword`).
    func asksForPassword(of id: String) -> Bool { links[id]?.tunnel?.asksForPassword ?? false }

    /// "Enter Password…": an interactive try now (`RemoteTunnel.retryByUser`).
    func retryByUser(id: String) { links[id]?.tunnel?.retryByUser() }

    /// Registers the machine's providers and opens its tunnel as soon as its
    /// listener is bound. A machine already present is left as it is.
    ///
    /// Its listener is the channel's end, a socket in the masters' folder
    /// that only this user can enter: `/signal` there takes no key, and
    /// what arrives is the machine's — the listener says so, never the body.
    ///
    /// `interactive`: the first try asks the user (a machine just added);
    /// one restored at launch tries quietly.
    func add(_ machine: RemoteMachine, interactive: Bool = false) {
        guard links[machine.id] == nil else { return }
        let link = Link(machine: machine,
                        hooks: HooksProvider(platform: platform, machine: machine.identity,
                                             isQuestion: Agents.isQuestion),
                        signals: SignalsProvider(now: now, machine: machine.identity))
        link.startInteractive = interactive
        let tunnel = RemoteTunnel(effects: RemoteTunnel.Effects(
            launch: { [weak self, weak link] generation in
                guard let self, let link else { return }
                self.launch(link, generation: generation)
            },
            terminate: { [weak link] in link?.process?.terminate() },
            now: now,
            schedule: schedule,
            hasStoredPassword: { [weak link] in link?.hasStoredPassword ?? false },
            probe: { [weak self, weak link] generation in
                guard let self, let link else { return }
                self.probe(link, generation: generation)
            },
            forward: { [weak self, weak link] generation, remote in
                guard let self, let link else { return }
                self.forward(link, generation: generation, remote: remote)
            }), channelDeadline: channelDeadline)
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
        guard let endpoint = RemoteTunnel.channelPath(directory: socketDirectory, machineID: machine.id) else {
            // No end here, no channel: the machine is listed and stays
            // stopped, which `--list` says.
            NSLog("Evlat: machine %@ has no channel: %@ is too long for a socket", machine.name, socketDirectory)
            register(link)
            return
        }
        link.listener = makeListener(for: link, at: endpoint)
        register(link)
        link.listener?.start()
    }

    /// The machine's listener at its channel's end.
    private func makeListener(for link: Link, at endpoint: String) -> HookListener {
        let onChange = self.onChange
        let machineID = link.machine.id
        return HookListener(
            transport: .unix(endpoint),
            origin: .machine,
            onStatus: { [weak self, weak link] status in
                guard let link else { return }
                switch status {
                case .listeningAt(let path) where link.endpoint == nil:
                    link.endpoint = path
                    NSLog("Evlat: machine %@ listening on %@", link.machine.name, path)
                    self?.startIfReady(link)
                case .unavailable, .unavailableAt:
                    NSLog("Evlat: machine %@ listener %@", link.machine.name, status.text)
                default:
                    break
                }
            },
            // Given, so an approval is held rather than refused at once.
            onAbandoned: { [weak self] id in self?.onAbandoned(id) },
            onDelivery: { [weak self, weak link] delivery in
                guard let link else { return }
                // Before the delivery: the row the event lands on is stamped
                // after the link's mark, so it is not dimmed as "not heard
                // since the tunnel came up" (`HooksProvider.dim`).
                link.tunnel?.heard()
                switch delivery {
                case .hook(let event):
                    self?.onHeard(event, machineID)
                    link.hooks.handle(event)
                // To the machine's provider for that agent; none (switched
                // off, or no status line) drops it.
                case .usage(let report): link.usage[report.source]?.handle(report)
                // The machine's name is the listener's: the body never says
                // which computer asked.
                case .approval(var request):
                    request.machine = machineID
                    self?.onApproval(request)
                // A tunnel answers `/permission` and `/askpass` with `404`
                // (`LocalAPI`): a remote machine never puts a chat's card in
                // front of this user, nor asks for a password.
                case .permission, .askpass: break
                // The machine's own outside row: the listener is the
                // machine's. A dropped row is said on stderr like a local
                // one, with the machine's name.
                case .signal(let report):
                    if case .dropped(let limit) = link.signals.apply(report) {
                        FileHandle.standardError.write(Data(AppController.droppedSignalLine(
                            id: report.id, limit: limit, machine: link.machine.name).utf8))
                    }
                }
                onChange()
            })
    }

    /// The channel's end is still there to forward to. `$TMPDIR` is swept,
    /// and a socket file gone takes its listener with it unheard — the
    /// forward is made all the same (`ssh` does not look), and every event
    /// would then fail to land while the row reads connected. A missing
    /// file gets a new listener; this try ends, and the next, on the
    /// schedule, finds it bound.
    private func endpointIsThere(_ link: Link) -> Bool {
        guard let endpoint = link.endpoint else { return false }
        if UnixSocket.identity(of: endpoint) != nil { return true }
        NSLog("Evlat: machine %@ lost its socket %@; listening again", link.machine.name, endpoint)
        link.listener?.stop()
        let listener = makeListener(for: link, at: endpoint)
        link.listener = listener
        listener.start()
        return false
    }

    private func register(_ link: Link) {
        let machine = link.machine
        links[machine.id] = link
        order.append(machine.id)
        registry.register(link.hooks)
        syncUsage(link)
        registry.register(link.signals)
        store.password(for: machine.id) { [weak link] password in link?.hasStoredPassword = password != nil }
    }

    /// Answers a held approval on the listener of the machine that asked.
    /// A machine gone took its connections with it: nothing to write.
    func answerApproval(_ id: String, machine: String, with response: LocalAPI.Response) {
        links[machine]?.listener?.answer(id, with: response)
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
        for provider in link.usage.values { registry.unregister(provider) }
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

    /// The first try, once the machine's listener has its socket and this
    /// Mac's listener is settled — whichever comes last starts it.
    private func startIfReady(_ link: Link) {
        guard !link.started, link.endpoint != nil, askpass?.settled() ?? true else { return }
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
        guard link.endpoint != nil, let tunnel = link.tunnel else { return }
        guard endpointIsThere(link) else {
            link.process = nil
            tunnel.exited(generation: generation, stderr: "")
            return
        }
        let controlPath = masterSocket(for: link.machine)
        link.controlPath = controlPath
        link.generation = generation
        link.usedStoredPassword = false
        link.sentStoredPassword = false
        link.typed = nil
        // No master, no channel: the try ends at once, as `other`, and
        // waits on the schedule — the next may find the socket free.
        guard let controlPath else {
            link.process = nil
            tunnel.exited(generation: generation, stderr: "")
            return
        }
        let asking = askpassEnvironment(for: link, generation: generation)
        let mark = RemoteTunnel.mark(nonce: UUID().uuidString)
        let process = SSHProcess(path: sshPath,
                                 arguments: RemoteTunnel.arguments(target: link.machine.target, controlPath: controlPath,
                                                                   mark: mark, askpass: asking != nil),
                                 environment: RemoteTunnel.environment(base: environment, askpass: asking),
                                 mark: mark,
                                 onMark: { [weak tunnel] in tunnel?.marked(generation: generation) }) {
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

    /// The probe and the machine's reading, in one call over the master;
    /// the reading is kept whatever the probe says.
    private func probe(_ link: Link, generation: Int) {
        guard let controlPath = link.controlPath else {
            link.tunnel?.probed(generation: generation, channel: nil)
            return
        }
        installer.channel(target: link.machine.target, controlPath: controlPath) { [weak self, weak link] result in
            guard let self, let link, self.links[link.machine.id] === link else { return }
            var channel: RemoteTunnel.Channel?
            if case .success(let reading) = result {
                link.reading = reading
                channel = reading.channel
                self.onReading(link.machine.id)
            }
            if let channel {
                NSLog("Evlat: machine %@ channel %@ (curl %@)", link.machine.name, channel.socket.rawValue,
                      channel.curl.rawValue)
            }
            link.tunnel?.probed(generation: generation, channel: channel)
        }
    }

    private func forward(_ link: Link, generation: Int, remote: String) {
        guard let controlPath = link.controlPath, let endpoint = link.endpoint else {
            link.tunnel?.forwarded(generation: generation, made: false)
            return
        }
        installer.forward(target: link.machine.target, controlPath: controlPath, remote: remote, local: endpoint) {
            [weak link] made in
            link?.tunnel?.forwarded(generation: generation, made: made)
        }
    }

    /// The tunnel's askpass variables, with a token new to this try; `nil`
    /// — and `BatchMode=yes` — while this Mac's listener has no socket.
    private func askpassEnvironment(for link: Link, generation: Int) -> [String: String]? {
        guard let askpass, let socket = askpass.socket() else { return nil }
        let token = Askpass.makeToken()
        tokens[token] = (link.machine.id, generation)
        return ["SSH_ASKPASS": askpass.binary,
                "SSH_ASKPASS_REQUIRE": "force",
                Askpass.environmentKey: Askpass.value(Askpass.Mark(socket: socket, token: token))]
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
        // Every launch: `$TMPDIR` is swept.
        if let refusal = UnixSocket.prepareDirectory(socketDirectory) {
            NSLog("Evlat: machine %@ runs without a master: %@", machine.name, refusal.text)
            return nil
        }
        switch UnixSocket.probe(path) {
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
}

/// One `ssh` process: stdin a pipe this process holds open, stdout read for
/// the master's mark, the tail of stderr kept for the failure class.
///
/// The stdin pipe is the tunnel's dead man's switch. Nothing is ever written
/// to it; when this process ends — `kill -9` included — the kernel closes our
/// end, the remote `cat` reads EOF, and `ssh` exits with it.
final class SSHProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let tail = StderrTail()
    private let onExit: (String) -> Void
    private let mark: String?
    private let onMark: () -> Void

    /// `onExit` is called once, on the main queue, with the tail of stderr;
    /// `onMark` once, on the main queue, when a line of stdout is `mark`.
    /// `environment` `nil` is this process's own.
    init(path: String, arguments: [String], environment: [String: String]? = nil,
         mark: String? = nil, onMark: @escaping () -> Void = {},
         onExit: @escaping (String) -> Void) {
        self.onExit = onExit
        self.mark = mark
        self.onMark = onMark
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
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
        // stdout is read to its end, the mark or not: a login script that
        // talks must never fill the pipe and stall the master. Before the
        // mark the lines are looked at, bounded; after it, dropped.
        let scanner = MarkScanner(mark: mark)
        let onMark = self.onMark
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if scanner.feed(data) { DispatchQueue.main.async { onMark() } }
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
            output.fileHandleForReading.readabilityHandler = nil
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

/// Finds a line that is exactly `mark` in a stream fed in chunks, once.
/// Written from the pipe's reading thread only.
final class MarkScanner {
    private let mark: Data?
    private var pending = Data()
    private var found = false
    /// A line longer than this before the mark is not the mark: its start is
    /// let go, so a talking login script costs bounded memory.
    private static let limit = 4096

    init(mark: String?) {
        self.mark = mark.map { Data($0.utf8) }
    }

    /// `true` the one time the mark's line completes.
    func feed(_ chunk: Data) -> Bool {
        guard let mark, !found else { return false }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            pending = Data(pending[pending.index(after: newline)...])
            if line == mark {
                found = true
                pending = Data()
                return true
            }
        }
        if pending.count > Self.limit { pending = Data(pending.suffix(mark.count)) }
        return false
    }
}

/// The last bytes of a process's stderr. Written from the pipe's reading thread,
/// read from the exit handler's; bounded, because a long-lived process
/// may write a warning now and then for days. Shared by `SSHProcess` and
/// `TurnRunner`.
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
