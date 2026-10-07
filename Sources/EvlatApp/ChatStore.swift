import Foundation
import EvlatCore
import EvlatAgents

/// The chats: each one's running turn's process and the index files.
/// Their state machines live in `provider` (`ChatsProvider`, the core's),
/// which is what the registry holds.
///
/// The core decides (`ChatSession`, `ChatIndex`), the backend words it
/// (`ChatBackend`), this carries it out: a process started, stopped, its
/// output fed back; the files written. Which agent a backend is, it never
/// asks.
///
/// Every chat runs on one backend: the one selected when it was made, for
/// good — its session is that agent's. Each backend keeps its own index file
/// (`ChatBackend.indexFile`); the history is all of them.
///
/// **Main queue only**, like the provider it writes: actions arrive from the UI,
/// the runner hops its output and exit here.
///
/// Permission requests are matched to a running turn by their token, and
/// are answered at their reply target when the user presses a card's
/// button: the listener's held connection (`permissions`), or the turn's
/// own stdin.
final class ChatStore {
    /// Where a one-way turn's permission requests post and how they are
    /// answered: the hook listener, or a test's stand-in. Weak: the
    /// controller owns it.
    weak var permissions: PermissionDesk?

    /// Where the index and the workspaces live; `nil` keeps everything in
    /// memory and workspaces in a temporary directory.
    private let root: URL?
    private let platform: Platform
    /// A backend chats can run on, and where its program is found.
    struct Lane {
        let backend: any ChatBackend
        let locator: AgentLocator
    }

    /// The backends, in the catalogue's order.
    let lanes: [Lane]
    /// The backend a new chat is made on: the user's choice, else the first
    /// found (`firstFoundLane`), read when one is made. An id among no
    /// lane's is the first lane's.
    private let selected: () -> AgentID
    private let now: () -> Date
    /// Sends a signal to a pid; `kill`, handed in so the orphan rule's
    /// effect stays one line.
    private let signal: (Int32, Int32) -> Void
    private let onChange: () -> Void
    /// What a turn inherits; handed in so a test gives the fake its own
    /// scenario rather than through the process's environment.
    private let environment: [String: String]

    /// Moves a pruned workspace to the Trash — recoverable, never
    /// `removeItem`. Handed in so a test watches it instead of filling the
    /// user's Trash; the default never reaches the real one
    /// (`ChatStore.trash(environment:)` is the app's choice).
    private let trash: (URL) throws -> Void
    /// The mode a chat on a backend gets when it has none of its own: a new
    /// one, or one read back from before chats had modes. The user's choice,
    /// read when it is needed (`UserDefaults`, the app's).
    private let defaultMode: (any ChatBackend) -> ChatMode

    /// The chats' state, and their rows. Read against the store's clock.
    let provider: ChatsProvider
    private var runners: [String: TurnRunner] = [:]
    private var streams: [String: any ChatParser] = [:]
    /// The running turns' permission tokens → their chat. A turn's token is
    /// made when it starts and forgotten when it ends, so a request from a
    /// turn that is over matches nothing.
    private var tokens: [String: String] = [:]
    /// Each backend's index, by its id.
    private var indexes: [AgentID: ChatIndex] = [:]
    /// Why a backend's index file could not be read. While set, that file is
    /// never written: someone's history is not replaced with an empty list.
    private(set) var indexErrors: [AgentID: ChatIndex.DecodeError] = [:]
    /// Each chat's backend, from when it is made.
    private var owners: [String: AgentID] = [:]
    /// The version each backend's last turn reported (`ChatParser.version`).
    private(set) var versions: [AgentID: String] = [:]

    /// `selected` names the backend new chats are made on; `defaultMode`
    /// is a backend's mode for a new chat.
    init(root: URL?, platform: Platform, lanes: [Lane], selected: @escaping () -> AgentID,
         now: @escaping () -> Date = Date.init,
         signal: @escaping (Int32, Int32) -> Void = { _ = kill($0, $1) },
         environment: [String: String] = ProcessInfo.processInfo.environment,
         trash: @escaping (URL) throws -> Void = ChatStore.setAside,
         defaultMode: @escaping (any ChatBackend) -> ChatMode = { $0.standardMode },
         onChange: @escaping () -> Void = {}) {
        precondition(!lanes.isEmpty, "a chat store needs a backend")
        provider = ChatsProvider(now: now)
        self.lanes = lanes
        self.selected = selected
        self.defaultMode = defaultMode
        self.trash = trash
        self.environment = environment
        self.root = root
        self.platform = platform
        self.now = now
        self.signal = signal
        self.onChange = onChange
        lanes.forEach(load)
        prune()
    }

    /// One backend: the catalogue's first unless one is handed in.
    /// `defaultMode` falls back to its standard mode.
    convenience init(root: URL?, platform: Platform, backend: any ChatBackend = Agents.chatBackends[0],
                     locator: AgentLocator, now: @escaping () -> Date = Date.init,
                     signal: @escaping (Int32, Int32) -> Void = { _ = kill($0, $1) },
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     trash: @escaping (URL) throws -> Void = ChatStore.setAside,
                     defaultMode: (() -> ChatMode)? = nil,
                     onChange: @escaping () -> Void = {}) {
        self.init(root: root, platform: platform, lanes: [Lane(backend: backend, locator: locator)],
                  selected: { [id = backend.id] in id }, now: now, signal: signal, environment: environment,
                  trash: trash, defaultMode: { defaultMode?() ?? $0.standardMode }, onChange: onChange)
    }

    // MARK: - Backends

    /// The lane new chats are made on.
    var selectedLane: Lane {
        let id = selected()
        return lanes.first { $0.backend.id == id } ?? lanes[0]
    }

    /// The chat's lane: the one it was made on.
    private func lane(of chat: String) -> Lane? {
        guard let id = owners[chat] else { return nil }
        return lanes.first { $0.backend.id == id }
    }

    /// The chat's backend; `nil` for a chat this store does not hold.
    func backend(of chat: String) -> (any ChatBackend)? { lane(of: chat)?.backend }

    /// `EVLAT_CHATS` (tilde expanded, blank ignored); else nothing when
    /// `EVLAT_PORT` is set — a measured process keeps no store, the rule
    /// `remote.machines` follows — else `Application Support/Evlat` under
    /// the home; no home, no disk.
    static func root(environment: [String: String], home: URL?) -> URL? {
        if let raw = environment["EVLAT_CHATS"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let port = environment["EVLAT_PORT"], !port.isEmpty { return nil }
        return home?.appendingPathComponent("Library/Application Support/Evlat", isDirectory: true)
    }

    /// How a pruned workspace leaves: the user's Trash, unless the store
    /// is an isolated one (`EVLAT_CHATS` or `EVLAT_PORT` set — a test, a
    /// measurement, a look by eye). Then it is set aside under the store's
    /// own root, and the real Trash is never touched (a look by eye had once
    /// left a `chats/<UUID>` there).
    static func trash(environment: [String: String]) -> (URL) throws -> Void {
        isolated(environment) ? setAside : { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }

    /// Is this a store kept apart from the user's — `EVLAT_CHATS` or
    /// `EVLAT_PORT` set? Then nothing of the user's is touched: not the
    /// Trash, not the chats' default mode.
    static func isolated(_ environment: [String: String]) -> Bool {
        [environment["EVLAT_CHATS"], environment["EVLAT_PORT"]]
            .contains { !($0?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
    }

    /// `<root>/chats/<UUID>` → `<root>/trash/<UUID>[-n]`: recoverable like
    /// the Trash, and inside the store that made it.
    static func setAside(_ folder: URL) throws {
        let bin = folder.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var target = bin.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = bin.appendingPathComponent("\(folder.lastPathComponent)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.moveItem(at: folder, to: target)
    }

    // MARK: - Reading

    func chat(_ id: String) -> ChatSession? { provider[id] }

    func processIdentifier(of chat: String) -> Int32? { runners[chat]?.processIdentifier }

    var sessionIDs: Set<String> { provider.sessionIDs }

    /// The first lane, in the catalogue's order, whose program was found and
    /// kept (`AgentLocator.isFound`): the new chats' backend when none is
    /// stored. Else the one the last search answered `.ready` for, whose
    /// find was not kept (the inherited `PATH` alone): the balloon must not
    /// send to the catalogue's first after calling another's program ready.
    /// Asks nothing.
    var firstFoundLane: Lane? {
        lanes.first { $0.locator.isFound } ?? lanes.first { $0.backend.id == unkeptHit }
    }

    /// The lane the last search for the new chats' backend hit without
    /// keeping it; `nil` when it hit none, or a kept one.
    private var unkeptHit: AgentID?

    /// Whether the balloon has a program to send to.
    enum Availability: Equatable {
        case ready
        /// Nothing stored and no program known yet: the search decides the
        /// backend, so nothing is sent until it has.
        case looking
        /// The chat's backend — or the stored one, while another's program
        /// is there — has no program.
        case missing
        /// No backend's program was found.
        case nothingFound
    }

    /// Is there a program to send to — the chat's backend's, the stored
    /// one's (`stored`), or with neither the first found? The same lookups a
    /// turn makes, so the two never disagree. A lookup runs only where the
    /// answer depends on it: nothing stored and a lane ahead of the first
    /// found one not found yet (in order, stopping at the first hit), or a
    /// backend that missed (the others, to tell `missing` from
    /// `nothingFound`). Calls back once with the answer, and before that
    /// with `.looking` when the answer decides the backend. Main queue.
    func locateBackend(for chat: String? = nil, stored: AgentID? = nil,
                       _ completion: @escaping (Availability) -> Void) {
        if let chat, let lane = lane(of: chat) {
            // A chat is its backend's for good: another's program is no help.
            return lane.locator.locate { completion($0.executable != nil ? .ready : .missing) }
        }
        if let stored, let lane = lanes.first(where: { $0.backend.id == stored }) {
            let others = lanes.filter { $0.backend.id != stored }
            return lane.locator.locate { location in
                guard location.executable == nil else { return completion(.ready) }
                Self.firstFound(in: others[...]) { completion($0 == nil ? .nothingFound : .missing) }
            }
        }
        let known = lanes.firstIndex { $0.locator.isFound }
        let ahead = lanes[..<(known ?? lanes.count)]
        guard !ahead.isEmpty else { return completion(.ready) }
        // With one known the line can send now, whatever the search ahead
        // of it finds: no `.looking`, and an earlier answer is not left up.
        completion(known == nil ? .looking : .ready)
        Self.firstFound(in: ahead) { [weak self] hit in
            // Set before the answer: the caller reads the derived backend.
            self?.unkeptHit = hit.flatMap { $0.locator.isFound ? nil : $0.backend.id }
            completion(hit != nil || known != nil ? .ready : .nothingFound)
        }
    }

    /// The first of `lanes` whose program is there, looked up one after
    /// another — one login shell at a time (`AgentLocator.SharedLoginPath`) —
    /// and no further once one is.
    private static func firstFound(in lanes: ArraySlice<Lane>, _ completion: @escaping (Lane?) -> Void) {
        guard let lane = lanes.first else { return completion(nil) }
        lane.locator.locate { location in
            if location.executable != nil { return completion(lane) }
            firstFound(in: lanes.dropFirst(), completion)
        }
    }

    /// Why the first backend's index (`indexFile`) could not be read.
    var indexError: ChatIndex.DecodeError? { indexErrors[lanes[0].backend.id] }

    // MARK: - Acting

    /// A new, empty chat in `folder`, or in its own workspace
    /// (`chats/<id>/`, created with the first turn), on the selected
    /// backend for good. It has no row until something is sent.
    /// `mode` is the balloon's pick, else the default; a mode the backend
    /// does not have is not taken.
    @discardableResult
    func newChat(folder: String? = nil, mode: ChatMode? = nil) -> String {
        let id = UUID().uuidString
        let backend = selectedLane.backend
        let workspace = ChatIndex.workspace(of: id, under: workspaceBase)
            ?? workspaceBase.appendingPathComponent("chats/\(id)", isDirectory: true)
        owners[id] = backend.id
        provider[id] = ChatSession(id: id, sessionID: UUID().uuidString.lowercased(),
                                folder: folder ?? workspace.path, isWorkspace: folder == nil,
                                mode: mode.flatMap { backend.modes.contains($0) ? $0 : nil } ?? defaultMode(backend))
        return id
    }

    /// The chat's mode from its next turn on; a running turn keeps the one
    /// it started with. Kept in its entry once it has one.
    func setMode(_ id: String, _ mode: ChatMode) {
        guard var chat = provider[id], chat.mode != mode, let owner = owners[id],
              backend(of: id)?.modes.contains(mode) == true else { return }
        chat.mode = mode
        provider[id] = chat
        if let i = indexes[owner]?.entries.firstIndex(where: { $0.id == id }) {
            indexes[owner]?.entries[i].permissionMode = mode.id
            save(owner)
        }
        onChange()
    }

    func perform(_ action: Action) {
        switch action {
        case .send(let id, let text, let attachments):
            send(id, text: text, attachments: attachments)
        case .stop(let id):
            guard let open = provider[id]?.requestStop(at: now()) else { return }
            // Each open card is denied with `interrupt`, at its own target,
            // so the agent ends the turn too rather than trying something
            // else.
            for requestID in open {
                guard let held = requests.removeValue(forKey: requestID) else { continue }
                reply(held.request, .deny(interrupt: true), chat: id)
            }
            if let backend = backend(of: id) {
                runners[id]?.stop(backend.stopPlan, line: streams[id]?.stopLine())
            }
            onChange()
        case .answer(let request, let decision):
            answer(request, decision)
        }
    }

    // MARK: - Permission

    /// A permission request of a running turn: a card on its chat, or a
    /// refusal — an unknown token, a turn not running.
    func permissionAsked(_ request: ChatRequest) {
        guard let token = request.token, let id = tokens[token], provider[id] != nil else {
            // Nobody to word an answer for: the listener's own refusal.
            permissions?.answer(request.id, with: LocalAPI.unknownToken)
            return
        }
        ask(request, chat: id)
    }

    /// A request of chat `id`'s running turn — through the listener, or on
    /// its own channel (`ChatEvent.asked`).
    private func ask(_ request: ChatRequest, chat id: String) {
        guard var chat = provider[id], let backend = backend(of: id) else { return }
        guard chat.ask(request, always: backend.caps.alwaysOption, at: now()) else {
            // After Stop, a request that slipped in ends the turn too, like
            // the cards Stop denied.
            reply(request, .deny(interrupt: chat.stopRequested), chat: id)
            return
        }
        requests[request.id] = (id, request)
        provider[id] = chat
        onChange()
    }

    /// The request's connection closed unanswered: the card goes.
    func permissionAbandoned(_ requestID: String) {
        guard let id = requests.removeValue(forKey: requestID)?.chat, var chat = provider[id] else { return }
        chat.expire(requestID, at: now())
        provider[id] = chat
        onChange()
    }

    /// Held requests → their chat, and the request (its reply target): open,
    /// or answered but not known to have reached the agent. An answer is
    /// written on the listener's queue; one that finds the connection
    /// already closed is followed by `permissionAbandoned`, which needs the
    /// chat to expire the card. Forgotten when the turn ends.
    private var requests: [String: (chat: String, request: ChatRequest)] = [:]

    private func answer(_ requestID: String, _ decision: Action.Decision) {
        guard let held = requests[requestID], var chat = provider[held.chat],
              let sent = chat.answer(requestID, decision, at: now()) else { return }
        let id = held.chat
        provider[id] = chat
        reply(held.request, sent, chat: id)
        // What "always" granted is the chat's from now on: its later turns
        // start with it (`TurnSpec.allowedTools`, `addDirectories`).
        if case .allow(let rules, let directories) = sent, !rules.isEmpty || !directories.isEmpty,
           let owner = owners[id], var index = indexes[owner],
           let i = index.entries.firstIndex(where: { $0.id == id }) {
            for rule in rules.map(\.text) where !index.entries[i].allowedRules.contains(rule) {
                index.entries[i].allowedRules.append(rule)
            }
            for directory in directories where !index.entries[i].addedDirectories.contains(directory) {
                index.entries[i].addedDirectories.append(directory)
            }
            indexes[owner] = index
            save(owner)
        }
        onChange()
    }

    /// The decision, in the backend's words, at the request's target.
    private func reply(_ request: ChatRequest, _ decision: ChatDecision, chat id: String) {
        guard let backend = backend(of: id) else { return }
        switch backend.encode(decision, for: request) {
        case .http(let body):
            permissions?.answer(request.id, with: LocalAPI.Response(status: .ok,
                                                                    body: String(decoding: body, as: UTF8.self)))
        case .line(let line):
            runners[id]?.write(line)
        }
    }

    /// The chat switched off: every running turn is stopped as its Stop
    /// would be — its open cards denied at their own targets, then the
    /// backend's `stopPlan` — so it ends as a stopped turn and its row
    /// stays. Not `stopAll`'s SIGTERM, which is for quitting.
    func stopRunning() {
        for id in provider.chats.values.filter(\.isRunning).map(\.id) {
            perform(.stop(chat: id))
        }
    }

    /// Evlat is quitting: every turn gets SIGTERM. Its record stays in the
    /// index, so the next launch marks the chat interrupted.
    func stopAll() {
        runners.values.forEach { $0.terminate() }
    }

    private func send(_ id: String, text: String, attachments: [String]) {
        guard var chat = provider[id], !chat.isRunning, let lane = lane(of: id) else { return }
        let entry = indexes[lane.backend.id]?.entries.first { $0.id == id }
        guard let spec = chat.begin(prompt: text, attachments: attachments, at: now(),
                                    addDirectories: entry?.addedDirectories ?? [],
                                    allowedTools: entry?.allowedRules ?? []) else { return }
        provider[id] = chat
        record(chat)
        onChange()
        lane.locator.locate { [weak self] location in
            self?.start(id, spec: spec, location: location)
        }
    }

    private func start(_ id: String, spec: TurnSpec, location: AgentLocator.Location) {
        guard var chat = provider[id], chat.isRunning, runners[id] == nil,
              let backend = backend(of: id) else { return }
        // Stopped while the program was still being looked for: nothing to
        // start, and the turn ends as stopped.
        guard !chat.stopRequested else {
            chat.ended(status: 0, stderr: "", at: now())
            return finish(id, chat)
        }
        guard let executable = location.executable else {
            chat.fail(.noBinary, at: now())
            return finish(id, chat)
        }
        // No bound listener, no one-way turn: every request it made would be
        // denied without a card — the silent failure when another Evlat
        // holds the socket. A duplex turn asks on its own channel.
        let bound = permissions?.boundPath
        if bound == nil, backend.caps.transport == .oneWay {
            chat.fail(.noListener(permissions?.status.text ?? HookListener.Status.stopped.text), at: now())
            return finish(id, chat)
        }
        let token = UUID().uuidString
        // A workspace chat remembers in Evlat's one memory folder; a chat in
        // the user's folder keeps that folder's own (the agent's default).
        let memory = chat.isWorkspace && backend.caps.memory ? memoryDirectory.path : nil
        let launch = backend.turn(spec, ctx: TurnContext(socket: bound ?? "", token: token, memoryDirectory: memory))
        if chat.isWorkspace {
            try? FileManager.default.createDirectory(atPath: chat.folder, withIntermediateDirectories: true)
        }
        streams[id] = backend.parser(for: spec)
        let runner = TurnRunner(
            executable: executable, launch: launch, path: location.path,
            environment: environment,
            onOutput: { [weak self] data in self?.output(id, data) },
            onExit: { [weak self] status, stderr in self?.exited(id, status: status, stderr: stderr) })
        if let failure = runner.run() {
            chat.fail(.launch(failure), at: now())
            return finish(id, chat)
        }
        runners[id] = runner
        tokens[token] = id
        let pid = runner.processIdentifier
        record(chat, run: ChatIndex.Run(pid: pid, startedAt: platform.processStartedAt(pid)))
    }

    private func output(_ id: String, _ data: Data) {
        guard var stream = streams[id], var chat = provider[id] else { return }
        let (events, replies) = stream.feed(data)
        streams[id] = stream
        replies.forEach { runners[id]?.write($0) }
        if let version = stream.version, let owner = owners[id], versions[owner] != version {
            versions[owner] = version
            provider.diagnostics = versionNotes
        }
        apply(events, to: &chat, id: id)
    }

    /// A backend whose turn reported another version than its chat was
    /// checked against: the chats' provider says so (`Provider.diagnostics`),
    /// beside Settings' warning.
    private var versionNotes: [String] {
        lanes.compactMap { lane in
            guard let measured = lane.backend.measuredVersion, let seen = versions[lane.backend.id],
                  seen != measured else { return nil }
            return "chat \(lane.backend.id): version \(seen) answered, checked against \(measured)"
        }
    }

    private func exited(_ id: String, status: Int32, stderr: String) {
        guard var chat = provider[id] else { return }
        if var stream = streams[id] {
            apply(stream.finish(), to: &chat, id: id)
            if !stream.unrecognized.isEmpty {
                // Counted, not swallowed: the one trace a renamed stream
                // type leaves while no view shows it.
                NSLog("Evlat: chat stream words not recognised: %@", stream.unrecognized.description)
            }
        }
        streams[id] = nil
        runners[id] = nil
        tokens = tokens.filter { $0.value != id }
        // Its held requests go unanswered: the listener's connections close
        // with the process, and the cards are expired below.
        requests = requests.filter { $0.value.chat != id }
        chat.ended(status: status, stderr: stderr, at: now())
        finish(id, chat)
    }

    private func apply(_ events: [ChatEvent], to chat: inout ChatSession, id: String) {
        guard !events.isEmpty else { return }
        for event in events {
            if case .asked(let request) = event {
                // Its card is opened on the chat as it stands, then read back.
                provider[id] = chat
                ask(request, chat: id)
                chat = provider[id] ?? chat
                continue
            }
            chat.apply(event, at: now())
            // The agent's own name for the session is kept at once, not at
            // the turn's end: a turn cut off after it must resume it.
            if case .started = event { record(chat) }
            // The result is the turn's end: stdin closes and the process
            // exits by itself; nothing is answered on it after.
            if case .result = event, let backend = backend(of: id) {
                runners[id]?.resultIn(duplex: backend.caps.transport == .duplex)
            }
        }
        provider[id] = chat
        onChange()
    }

    private func finish(_ id: String, _ chat: ChatSession) {
        provider[id] = chat
        record(chat)
        onChange()
    }

    // MARK: - Seen, history, pruning

    /// Where workspaces are made: the root, or a temporary directory for a
    /// store kept in memory.
    private var workspaceBase: URL {
        root ?? FileManager.default.temporaryDirectory.appendingPathComponent("evlat-chats", isDirectory: true)
    }

    // MARK: - Memory

    /// Where workspace chats remember (`TurnContext.memoryDirectory`): one
    /// folder beside `chats/`, shared by all of them. The agent makes it
    /// with its first note. Not a workspace: the week's pruning never reaches it
    /// (`removableWorkspace` takes only `chats/<UUID>`), it is kept until
    /// the user clears it.
    var memoryDirectory: URL {
        workspaceBase.appendingPathComponent(Self.memoryName, isDirectory: true)
    }

    static let memoryName = "memory"

    /// What the memory folder holds, hidden files included: `nil` when it
    /// is not a folder Evlat may clear (missing, a link, not a folder, not
    /// directly under the root).
    func memoryContents() -> [URL]? {
        guard let folder = clearableMemory() else { return nil }
        return try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }

    /// The menu's "Clear": everything **in** the memory folder goes, the
    /// folder stays. Nothing when the folder is not Evlat's own (a link to
    /// somewhere else is never followed). A link inside it goes as a link:
    /// `removeItem` removes the link, not what it points at. `false` when
    /// something could not be removed.
    @discardableResult
    func clearMemory() -> Bool {
        guard let children = memoryContents() else { return false }
        var cleared = true
        for child in children {
            do { try FileManager.default.removeItem(at: child) } catch {
                cleared = false
                NSLog("Evlat: memory file not removed (%@)", error.localizedDescription)
            }
        }
        return cleared
    }

    /// The memory folder, if it is a real folder directly under the root —
    /// checked without following links, on the folder and on the way to it.
    private func clearableMemory() -> URL? {
        let folder = memoryDirectory.standardizedFileURL
        guard let type = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType,
              type == .typeDirectory else { return nil }
        let base = workspaceBase.standardizedFileURL
        guard folder.deletingLastPathComponent().path == base.path,
              folder.resolvingSymlinksInPath().deletingLastPathComponent().path
                == base.resolvingSymlinksInPath().path else { return nil }
        return folder
    }

    /// Lets a seen chat's row go: the shell calls it at the close of the bar
    /// after the chat's end was seen (by the bar or the balloon), not the
    /// moment it was drawn. Its row goes, and the index forgets that it was
    /// unseen. Its activity is not moved: looking is
    /// not using, and the history's week counts from the last turn.
    func markSeen(_ id: String) {
        guard var chat = provider[id], chat.markSeen() else { return }
        provider[id] = chat
        if let owner = owners[id], let i = indexes[owner]?.entries.firstIndex(where: { $0.id == id }),
           indexes[owner]?.entries[i].unseen != nil {
            indexes[owner]?.entries[i].unseen = nil
            save(owner)
        }
        onChange()
    }

    /// Every backend's entries, in the lanes' order.
    private var entries: [ChatIndex.Entry] {
        lanes.flatMap { indexes[$0.backend.id]?.entries ?? [] }
    }

    /// The history: chats with no row — neither running nor waiting to be
    /// seen — pinned first, then the latest first, whatever their backend.
    var history: [ChatIndex.Entry] {
        let now = now()
        return entries.filter { entry in
            entry.run == nil && provider[entry.id].map { $0.signal(at: now) == nil && !$0.isRunning } ?? true
        }.sorted(by: ChatIndex.historyOrder)
    }

    /// A chat from the history, ready to go on: already here, or read
    /// back from its entry (its last reply as its one line). `false` for
    /// an id the index does not hold.
    @discardableResult
    func open(_ id: String) -> Bool {
        if provider[id] != nil { return true }
        guard let lane = lane(of: id),
              let entry = indexes[lane.backend.id]?.entries.first(where: { $0.id == id }) else { return false }
        provider[id] = restored(entry, on: lane.backend)
        return true
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard let owner = owners[id], let i = indexes[owner]?.entries.firstIndex(where: { $0.id == id }),
              indexes[owner]?.entries[i].pinned != pinned else { return }
        indexes[owner]?.entries[i].pinned = pinned
        save(owner)
        onChange()
    }

    /// The history's ×: the chat goes, its workspace to the Trash. Not
    /// while a turn runs.
    func remove(_ id: String) {
        guard provider[id]?.isRunning != true,
              let entry = entries.first(where: { $0.id == id }), entry.run == nil else { return }
        discard([entry])
    }

    /// "Clear history": every chat in it but the pinned ones.
    func clearHistory() {
        discard(history.filter { !$0.pinned })
    }

    /// The week's rule, at launch and whenever the balloon opens.
    func prune() {
        discard(lanes.flatMap { indexes[$0.backend.id]?.expired(at: now()) ?? [] })
    }

    /// Entries out of their index and the provider; a workspace's folder to
    /// the Trash. Nothing of a backend whose file could not be read: its
    /// entries are not known, and neither is what is safe to remove.
    private func discard(_ entries: [ChatIndex.Entry]) {
        let entries = entries.filter { owners[$0.id].map { indexErrors[$0] == nil } ?? false }
        guard !entries.isEmpty else { return }
        let ids = Set(entries.map(\.id))
        for entry in entries where entry.isWorkspace {
            guard let folder = removableWorkspace(entry.id) else { continue }
            do { try trash(folder) } catch {
                NSLog("Evlat: chat workspace not moved to the Trash (%@)", error.localizedDescription)
            }
        }
        let touched = Set(ids.compactMap { owners[$0] })
        for owner in touched { indexes[owner]?.entries.removeAll { ids.contains($0.id) } }
        for id in ids where provider[id]?.isRunning != true {
            provider[id] = nil
            owners[id] = nil
        }
        for id in ids { walked[id] = nil }
        touched.forEach(save)
        onChange()
    }

    /// A chat's workspace, if it may be removed: the id's own
    /// `chats/<UUID>` (`ChatIndex.workspace`), a direct child of the
    /// store's `chats/`, and there. Never the entry's `folder`.
    func removableWorkspace(_ id: String) -> URL? {
        let chats = workspaceBase.appendingPathComponent("chats", isDirectory: true).standardizedFileURL
        guard let folder = ChatIndex.workspace(of: id, under: workspaceBase)?.standardizedFileURL,
              folder.deletingLastPathComponent().path == chats.path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return folder
    }

    /// Files a workspace chat made, once its turn is over: what is in its
    /// own folder, hidden ones aside, newest first. A chat in the user's
    /// folder lists none — what is there is the user's already.
    ///
    /// Walked once per finished turn, not per refresh: an open balloon
    /// refreshes every poll, and a turn's files are made while it runs.
    func workspaceFiles(_ id: String, limit: Int = 8) -> [URL] {
        guard let chat = provider[id], chat.isWorkspace, !chat.isRunning else { return [] }
        if let cached = walked[id], cached.since == chat.since, cached.limit == limit { return cached.files }
        let files = walk(chat.folder, limit: limit)
        walked[id] = (chat.since, limit, files)
        return files
    }

    /// `workspaceFiles`' last walk per chat, keyed by the turn's end.
    private var walked: [String: (since: Date?, limit: Int, files: [URL])] = [:]

    private func walk(_ path: String, limit: Int) -> [URL] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
            if files.count >= 200 { break }
        }
        return files.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }.prefix(limit).map(\.0)
    }

    // MARK: - Index

    /// An entry read back as a chat, its stored mode among its backend's.
    private func restored(_ entry: ChatIndex.Entry, on backend: any ChatBackend) -> ChatSession {
        ChatSession.restored(entry, modes: backend.modes, mode: defaultMode(backend))
    }

    /// The first backend's own file: another backend's is never read or
    /// written as it (`ChatIndex.fileName`).
    var indexFile: String { lanes[0].backend.indexFile }

    private func load(_ lane: Lane) {
        let backend = lane.backend
        guard let root else { return }
        let file = root.appendingPathComponent(backend.indexFile)
        guard let data = try? Data(contentsOf: file) else { return }
        var index: ChatIndex
        do {
            index = try ChatIndex.decode(data)
        } catch {
            indexErrors[backend.id] = error as? ChatIndex.DecodeError ?? .unreadable
            NSLog("Evlat: %@ left as it is, not readable (%@)", file.path, String(describing: error))
            return
        }
        for entry in index.entries where owners[entry.id] == nil { owners[entry.id] = backend.id }
        let orphans = index.orphans(platform: platform)
        orphans.terminate.forEach { signal($0, SIGTERM) }
        for i in index.entries.indices where orphans.interrupted.contains(index.entries[i].id) {
            let entry = index.entries[i]
            var chat = restored(entry, on: backend)
            chat.fail(.interrupted, at: entry.lastActivity)
            provider[entry.id] = chat
            index.entries[i].run = nil
            index.entries[i].unseen = .failed
        }
        // An end the balloon never showed keeps its row across a relaunch,
        // until its time is up (`ChatSession.unseenLifetime`).
        for entry in index.entries where entry.unseen != nil && provider[entry.id] == nil {
            provider[entry.id] = restored(entry, on: backend)
        }
        indexes[backend.id] = index
        if !orphans.interrupted.isEmpty { save(backend.id) }
    }

    /// The chat's entry, created with its first turn, updated after — in
    /// its backend's index.
    private func record(_ chat: ChatSession, run: ChatIndex.Run? = nil) {
        guard let owner = owners[chat.id] else { return }
        let stamp = now()
        var index = indexes[owner] ?? ChatIndex(entries: [])
        if let i = index.entries.firstIndex(where: { $0.id == chat.id }) {
            index.entries[i].lastActivity = stamp
            // The agent's own name for the session, once its first turn
            // gave one (`ChatSession.sessionID`).
            index.entries[i].sessionID = chat.sessionID
            index.entries[i].title = chat.title ?? chat.promptLabel ?? index.entries[i].title
            index.entries[i].started = chat.hasStarted
            index.entries[i].run = chat.isRunning ? (run ?? index.entries[i].run) : nil
            index.entries[i].unseen = chat.unseenPhase
            index.entries[i].permissionMode = chat.mode.id
            if let reply = chat.lastReply { index.entries[i].lastReply = reply }
        } else {
            index.entries.append(ChatIndex.Entry(
                id: chat.id, sessionID: chat.sessionID, title: chat.title ?? chat.promptLabel, folder: chat.folder,
                isWorkspace: chat.isWorkspace, createdAt: stamp, lastActivity: stamp,
                lastReply: chat.lastReply, run: chat.isRunning ? run : nil, started: chat.hasStarted,
                unseen: chat.unseenPhase, permissionMode: chat.mode.id))
        }
        indexes[owner] = index
        save(owner)
    }

    /// A backend's file: atomic, and never over one that could not be read.
    private func save(_ owner: AgentID) {
        guard let root, indexErrors[owner] == nil,
              let backend = lanes.first(where: { $0.backend.id == owner })?.backend else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try (indexes[owner] ?? ChatIndex(entries: [])).encoded()
                .write(to: root.appendingPathComponent(backend.indexFile), options: .atomic)
        } catch {
            NSLog("Evlat: chat index not written (%@)", error.localizedDescription)
        }
    }
}

/// What a chat needs from the hook listener: is it bound, and a way to
/// answer a held request. `HookListener` is the one in the app, on Evlat's
/// socket.
protocol PermissionDesk: AnyObject {
    var status: HookListener.Status { get }
    var boundPath: String? { get }
    func answer(_ id: String, with response: LocalAPI.Response)
}

extension HookListener: PermissionDesk {}
