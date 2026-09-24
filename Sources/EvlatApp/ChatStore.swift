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
final class ChatStore {
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

    /// The chats' state, and their rows.
    let provider = ChatsProvider()
    private var runners: [String: ClaudeRunner] = [:]
    private var streams: [String: ChatStream] = [:]
    private var index = ChatIndex(entries: [])
    /// Why the index file could not be read. While set, it is never
    /// written: someone's history is not replaced with an empty list.
    private(set) var indexError: ChatIndex.DecodeError?

    init(root: URL?, platform: Platform, locator: ClaudeLocator, now: @escaping () -> Date = Date.init,
         signal: @escaping (Int32, Int32) -> Void = { _ = kill($0, $1) },
         environment: [String: String] = ProcessInfo.processInfo.environment,
         onChange: @escaping () -> Void = {}) {
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
    @discardableResult
    func newChat(folder: String? = nil) -> String {
        let id = UUID().uuidString
        let workspace = (root ?? FileManager.default.temporaryDirectory.appendingPathComponent("evlat-chats"))
            .appendingPathComponent("chats/\(id)", isDirectory: true)
        provider[id] = ChatSession(id: id, sessionID: UUID().uuidString.lowercased(),
                                folder: folder ?? workspace.path, isWorkspace: folder == nil)
        return id
    }

    func perform(_ action: Action) {
        switch action {
        case .send(let id, let text, let attachments):
            send(id, text: text, attachments: attachments)
        case .stop(let id):
            guard provider[id]?.requestStop() == true else { return }
            runners[id]?.interrupt()
            onChange()
        case .answer:
            // Permission requests arrive with `phase-3`.
            break
        }
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
        guard !orphans.interrupted.isEmpty else { return }
        for i in index.entries.indices where orphans.interrupted.contains(index.entries[i].id) {
            let entry = index.entries[i]
            var chat = ChatSession(id: entry.id, sessionID: entry.sessionID, folder: entry.folder,
                                   isWorkspace: entry.isWorkspace, title: entry.title,
                                   hasStarted: entry.started)
            chat.fail(.interrupted, at: entry.lastActivity)
            provider[entry.id] = chat
            index.entries[i].run = nil
        }
        save()
    }

    /// The chat's entry, created with its first turn, updated after.
    private func record(_ chat: ChatSession, run: ChatIndex.Run? = nil) {
        let stamp = now()
        if let i = index.entries.firstIndex(where: { $0.id == chat.id }) {
            index.entries[i].lastActivity = stamp
            index.entries[i].title = chat.title
            index.entries[i].started = chat.hasStarted
            index.entries[i].run = chat.isRunning ? (run ?? index.entries[i].run) : nil
            if let reply = chat.lastReply { index.entries[i].lastReply = reply }
        } else {
            index.entries.append(ChatIndex.Entry(
                id: chat.id, sessionID: chat.sessionID, title: chat.title, folder: chat.folder,
                isWorkspace: chat.isWorkspace, createdAt: stamp, lastActivity: stamp,
                lastReply: chat.lastReply, run: chat.isRunning ? run : nil, started: chat.hasStarted))
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
