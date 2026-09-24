import Foundation
import EvlatCore

/// The chats (`011`): each one's running turn's process and the index file.
/// Their state machines live in `provider` (`ChatsProvider`, the core's),
/// which is what the registry holds.
///
/// The core decides (`ChatSession`, `ChatIndex`), this carries it out: a
/// process started, signalled, its output fed back; the file written.
///
/// **Main queue only**, like the provider it writes: actions arrive from the UI,
/// the runner hops its output and exit here.
///
/// Permission requests (`phase-3`) arrive from the listener's held
/// connections, are matched to a running turn by their token, and are
/// answered through `permissions` when the user presses a card's button.
final class ChatStore {
    /// Where a turn's permission hook posts and how it is answered: the
    /// hook listener, or a test's stand-in. Weak: the controller owns it.
    weak var permissions: PermissionDesk?
    /// The index's file name under the root.
    static let indexName = "chats.json"

    /// Where the index and the workspaces live; `nil` keeps everything in
    /// memory and workspaces in a temporary directory.
    private let root: URL?
    private let platform: Platform
    private let locator: ClaudeLocator
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
    /// The mode a chat gets when it has none of its own: a new one, or one
    /// read back from before chats had modes. The user's choice, read when
    /// it is needed (`UserDefaults`, the app's).
    private let defaultMode: () -> PermissionMode

    /// The chats' state, and their rows. Read against the store's clock.
    let provider: ChatsProvider
    private var runners: [String: ClaudeRunner] = [:]
    private var streams: [String: ChatStream] = [:]
    /// The running turns' permission tokens → their chat. A turn's token is
    /// made when it starts and forgotten when it ends, so a request from a
    /// turn that is over matches nothing.
    private var tokens: [String: String] = [:]
    private var index = ChatIndex(entries: [])
    /// Why the index file could not be read. While set, it is never
    /// written: someone's history is not replaced with an empty list.
    private(set) var indexError: ChatIndex.DecodeError?

    init(root: URL?, platform: Platform, locator: ClaudeLocator, now: @escaping () -> Date = Date.init,
         signal: @escaping (Int32, Int32) -> Void = { _ = kill($0, $1) },
         environment: [String: String] = ProcessInfo.processInfo.environment,
         trash: @escaping (URL) throws -> Void = ChatStore.setAside,
         defaultMode: @escaping () -> PermissionMode = { .standard },
         onChange: @escaping () -> Void = {}) {
        provider = ChatsProvider(now: now)
        self.defaultMode = defaultMode
        self.trash = trash
        self.environment = environment
        self.root = root
        self.platform = platform
        self.locator = locator
        self.now = now
        self.signal = signal
        self.onChange = onChange
        load()
    }

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
    /// own root, and the real Trash is never touched (`011` kapı: a look by
    /// eye had left a `chats/<UUID>` there).
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

    /// Is there a `claude` to send to? For the balloon's empty state; the
    /// same lookup a turn makes, so the two never disagree. Main queue.
    func locateClaude(_ completion: @escaping (Bool) -> Void) {
        locator.locate { completion($0.executable != nil) }
    }

    // MARK: - Acting

    /// A new, empty chat in `folder`, or in its own workspace
    /// (`chats/<id>/`, created with the first turn). It has no row until
    /// something is sent.
    /// `mode` is the balloon's pick, else the default.
    @discardableResult
    func newChat(folder: String? = nil, mode: PermissionMode? = nil) -> String {
        let id = UUID().uuidString
        let workspace = ChatIndex.workspace(of: id, under: workspaceBase)
            ?? workspaceBase.appendingPathComponent("chats/\(id)", isDirectory: true)
        provider[id] = ChatSession(id: id, sessionID: UUID().uuidString.lowercased(),
                                folder: folder ?? workspace.path, isWorkspace: folder == nil,
                                mode: mode ?? defaultMode())
        return id
    }

    /// The chat's mode from its next turn on; a running turn keeps the one
    /// it started with. Kept in its entry once it has one.
    func setMode(_ id: String, _ mode: PermissionMode) {
        guard var chat = provider[id], chat.mode != mode else { return }
        chat.mode = mode
        provider[id] = chat
        if let i = index.entries.firstIndex(where: { $0.id == id }) {
            index.entries[i].permissionMode = mode.rawValue
            save()
        }
        onChange()
    }

    func perform(_ action: Action) {
        switch action {
        case .send(let id, let text, let attachments):
            send(id, text: text, attachments: attachments)
        case .stop(let id):
            guard let open = provider[id]?.requestStop(at: now()) else { return }
            // Each open card is denied with `interrupt`, so Claude ends the
            // turn too rather than trying something else.
            for request in open {
                requests[request] = nil
                permissions?.answer(request, with: Self.response(.deny(interrupt: true)))
            }
            runners[id]?.interrupt()
            onChange()
        case .answer(let request, let decision):
            answer(request, decision)
        }
    }

    // MARK: - Permission

    /// A permission request held by the listener: a card on its turn's
    /// chat, or a refusal — an unknown token, a turn not running.
    func permissionAsked(_ request: PermissionHook.Request) {
        guard let token = request.token, let id = tokens[token], var chat = provider[id] else {
            permissions?.answer(request.id, with: LocalAPI.unknownToken)
            return
        }
        guard chat.ask(request, at: now()) else {
            // After Stop, a request that slipped in ends the turn too, like
            // the cards Stop denied.
            permissions?.answer(request.id, with: Self.response(.deny(interrupt: chat.stopRequested)))
            return
        }
        requests[request.id] = id
        provider[id] = chat
        onChange()
    }

    /// The request's connection closed unanswered: the card goes.
    func permissionAbandoned(_ requestID: String) {
        guard let id = requests.removeValue(forKey: requestID), var chat = provider[id] else { return }
        chat.expire(requestID, at: now())
        provider[id] = chat
        onChange()
    }

    /// Held requests → their chat: open, or answered but not known to have
    /// reached Claude. An answer is written on the listener's queue; one
    /// that finds the connection already closed is followed by
    /// `permissionAbandoned`, which needs the chat to expire the card.
    /// Forgotten when the turn ends.
    private var requests: [String: String] = [:]

    private func answer(_ requestID: String, _ decision: Action.Decision) {
        guard let id = requests[requestID], var chat = provider[id],
              let sent = chat.answer(requestID, decision, at: now()) else { return }
        provider[id] = chat
        permissions?.answer(requestID, with: Self.response(sent))
        // What "always" granted is the chat's from now on: its later turns
        // start with it (`--allowedTools`, `--add-dir`).
        if case .allow(let rules, let directories) = sent, !rules.isEmpty || !directories.isEmpty,
           let i = index.entries.firstIndex(where: { $0.id == id }) {
            for rule in rules.map(\.text) where !index.entries[i].allowedRules.contains(rule) {
                index.entries[i].allowedRules.append(rule)
            }
            for directory in directories where !index.entries[i].addedDirectories.contains(directory) {
                index.entries[i].addedDirectories.append(directory)
            }
            save()
        }
        onChange()
    }

    static func response(_ decision: PermissionHook.Decision) -> LocalAPI.Response {
        LocalAPI.Response(status: .ok, body: PermissionHook.body(decision))
    }

    /// Evlat is quitting: every turn gets SIGTERM. Its record stays in the
    /// index, so the next launch marks the chat interrupted.
    func stopAll() {
        runners.values.forEach { $0.terminate() }
    }

    private func send(_ id: String, text: String, attachments: [String]) {
        guard var chat = provider[id], !chat.isRunning else { return }
        let entry = index.entries.first { $0.id == id }
        guard let invocation = chat.begin(prompt: text, attachments: attachments, at: now(),
                                          addDirectories: entry?.addedDirectories ?? [],
                                          allowedTools: entry?.allowedRules ?? []) else { return }
        provider[id] = chat
        record(chat)
        onChange()
        locator.locate { [weak self] location in
            self?.start(id, invocation: invocation, location: location)
        }
    }

    private func start(_ id: String, invocation: ClaudeInvocation, location: ClaudeLocator.Location) {
        guard var chat = provider[id], chat.isRunning, runners[id] == nil else { return }
        // Stopped while `claude` was still being looked for: nothing to
        // start, and the turn ends as stopped.
        guard !chat.stopRequested else {
            chat.ended(status: 0, stderr: "", at: now())
            return finish(id, chat)
        }
        guard let executable = location.executable else {
            chat.fail(.noBinary, at: now())
            return finish(id, chat)
        }
        // No bound listener, no turn: every request it made would be denied
        // without a card — the silent failure when another Evlat holds the
        // port.
        guard let port = permissions?.boundPort else {
            chat.fail(.noListener(permissions?.status.text ?? HookListener.Status.stopped.text), at: now())
            return finish(id, chat)
        }
        let token = UUID().uuidString
        let invocation = invocation.asking(PermissionHook.Endpoint(port: port, token: token))
        if chat.isWorkspace {
            try? FileManager.default.createDirectory(atPath: chat.folder, withIntermediateDirectories: true)
        }
        streams[id] = ChatStream()
        let runner = ClaudeRunner(
            executable: executable, invocation: invocation, path: location.path,
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
        let events = stream.feed(data)
        streams[id] = stream
        apply(events, to: &chat, id: id)
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
        requests = requests.filter { $0.value != id }
        chat.ended(status: status, stderr: stderr, at: now())
        finish(id, chat)
    }

    private func apply(_ events: [ChatStream.Event], to chat: inout ChatSession, id: String) {
        guard !events.isEmpty else { return }
        for event in events {
            chat.apply(event, at: now())
            // The result is the turn's end: stdin closes and the process
            // exits by itself.
            if case .result = event { runners[id]?.closeInput() }
        }
        provider[id] = chat
        onChange()
    }

    private func finish(_ id: String, _ chat: ChatSession) {
        provider[id] = chat
        record(chat)
        onChange()
    }

    // MARK: - Seen, history, pruning (`phase-5`)

    /// Where workspaces are made: the root, or a temporary directory for a
    /// store kept in memory.
    private var workspaceBase: URL {
        root ?? FileManager.default.temporaryDirectory.appendingPathComponent("evlat-chats", isDirectory: true)
    }

    /// The balloon drew the chat's end: its row goes, and the index
    /// forgets that it was unseen. Its activity is not moved: looking is
    /// not using, and the history's week counts from the last turn.
    func markSeen(_ id: String) {
        guard var chat = provider[id], chat.markSeen() else { return }
        provider[id] = chat
        if let i = index.entries.firstIndex(where: { $0.id == id }), index.entries[i].unseen != nil {
            index.entries[i].unseen = nil
            save()
        }
        onChange()
    }

    /// The history: chats with no row — neither running nor waiting to be
    /// seen — pinned first, then the latest first.
    var history: [ChatIndex.Entry] {
        let now = now()
        return index.entries.filter { entry in
            entry.run == nil && provider[entry.id].map { $0.signal(at: now) == nil && !$0.isRunning } ?? true
        }.sorted(by: ChatIndex.historyOrder)
    }

    /// A chat from the history, ready to go on: already here, or read
    /// back from its entry (its last reply as its one line). `false` for
    /// an id the index does not hold.
    @discardableResult
    func open(_ id: String) -> Bool {
        if provider[id] != nil { return true }
        guard let entry = index.entries.first(where: { $0.id == id }) else { return false }
        provider[id] = ChatSession.restored(entry, mode: defaultMode())
        return true
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard let i = index.entries.firstIndex(where: { $0.id == id }), index.entries[i].pinned != pinned else { return }
        index.entries[i].pinned = pinned
        save()
        onChange()
    }

    /// The history's ×: the chat goes, its workspace to the Trash. Not
    /// while a turn runs.
    func remove(_ id: String) {
        guard provider[id]?.isRunning != true,
              let entry = index.entries.first(where: { $0.id == id }), entry.run == nil else { return }
        discard([entry])
    }

    /// "Clear history": every chat in it but the pinned ones.
    func clearHistory() {
        discard(history.filter { !$0.pinned })
    }

    /// The week's rule, at launch and whenever the balloon opens.
    func prune() {
        discard(index.expired(at: now()))
    }

    /// Entries out of the index and the provider; a workspace's folder to
    /// the Trash. Nothing while the file could not be read: the entries
    /// are not known, and neither is what is safe to remove.
    private func discard(_ entries: [ChatIndex.Entry]) {
        guard indexError == nil, !entries.isEmpty else { return }
        let ids = Set(entries.map(\.id))
        for entry in entries where entry.isWorkspace {
            guard let folder = removableWorkspace(entry.id) else { continue }
            do { try trash(folder) } catch {
                NSLog("Evlat: chat workspace not moved to the Trash (%@)", error.localizedDescription)
            }
        }
        index.entries.removeAll { ids.contains($0.id) }
        for id in ids where provider[id]?.isRunning != true { provider[id] = nil }
        for id in ids { walked[id] = nil }
        save()
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

    private func load() {
        guard let root else { return }
        let file = root.appendingPathComponent(Self.indexName)
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            index = try ChatIndex.decode(data)
        } catch {
            indexError = error as? ChatIndex.DecodeError ?? .unreadable
            NSLog("Evlat: %@ left as it is, not readable (%@)", file.path, String(describing: error))
            return
        }
        let orphans = index.orphans(platform: platform)
        orphans.terminate.forEach { signal($0, SIGTERM) }
        for i in index.entries.indices where orphans.interrupted.contains(index.entries[i].id) {
            let entry = index.entries[i]
            var chat = ChatSession.restored(entry, mode: defaultMode())
            chat.fail(.interrupted, at: entry.lastActivity)
            provider[entry.id] = chat
            index.entries[i].run = nil
            index.entries[i].unseen = .failed
        }
        // An end the balloon never showed keeps its row across a relaunch,
        // until its time is up (`ChatSession.unseenLifetime`).
        for entry in index.entries where entry.unseen != nil && provider[entry.id] == nil {
            provider[entry.id] = ChatSession.restored(entry, mode: defaultMode())
        }
        if !orphans.interrupted.isEmpty { save() }
        prune()
    }

    /// The chat's entry, created with its first turn, updated after.
    private func record(_ chat: ChatSession, run: ChatIndex.Run? = nil) {
        let stamp = now()
        if let i = index.entries.firstIndex(where: { $0.id == chat.id }) {
            index.entries[i].lastActivity = stamp
            index.entries[i].title = chat.title ?? chat.promptLabel ?? index.entries[i].title
            index.entries[i].started = chat.hasStarted
            index.entries[i].run = chat.isRunning ? (run ?? index.entries[i].run) : nil
            index.entries[i].unseen = chat.unseenPhase
            index.entries[i].permissionMode = chat.mode.rawValue
            if let reply = chat.lastReply { index.entries[i].lastReply = reply }
        } else {
            index.entries.append(ChatIndex.Entry(
                id: chat.id, sessionID: chat.sessionID, title: chat.title ?? chat.promptLabel, folder: chat.folder,
                isWorkspace: chat.isWorkspace, createdAt: stamp, lastActivity: stamp,
                lastReply: chat.lastReply, run: chat.isRunning ? run : nil, started: chat.hasStarted,
                unseen: chat.unseenPhase, permissionMode: chat.mode.rawValue))
        }
        save()
    }

    /// Atomic, and never over a file that could not be read.
    private func save() {
        guard let root, indexError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try index.encoded().write(to: root.appendingPathComponent(Self.indexName), options: .atomic)
        } catch {
            NSLog("Evlat: chat index not written (%@)", error.localizedDescription)
        }
    }
}

/// What a chat needs from the hook listener: is it bound, and a way to
/// answer a held request. `HookListener` is the one in the app.
protocol PermissionDesk: AnyObject {
    var status: HookListener.Status { get }
    var boundPort: UInt16? { get }
    func answer(_ id: String, with response: LocalAPI.Response)
}

extension HookListener: PermissionDesk {}
