import Foundation

/// The chats' one small file (`011`, Karar 5): what the history lists and
/// what a resumed chat needs, never the conversation — the full text stays
/// in Claude's own record, which has no documented reader.
///
/// Encoding and decoding are pure. **A file that cannot be read is an error
/// and is never overwritten**: the caller keeps it as it found it rather than
/// replacing someone's history with an empty list.
public struct ChatIndex: Equatable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var entries: [Entry]

    public init(entries: [Entry]) {
        version = Self.currentVersion
        self.entries = entries
    }

    public struct Entry: Equatable, Codable {
        /// A UUID: later a path under `chats/` is built from it (`decode`).
        public var id: String
        /// Claude's session id (`--session-id`, then `--resume`).
        public var sessionID: String
        public var title: String?
        public var folder: String
        /// Is `folder` Evlat's own `chats/<id>/`, removed with the entry?
        public var isWorkspace: Bool
        public var createdAt: Date
        public var lastActivity: Date
        public var pinned: Bool
        /// The last reply, already cut (`HookEvent.firstParagraph`).
        public var lastReply: String?
        /// "Always for this folder" rules, handed back as `--allowedTools`.
        public var allowedRules: [String]
        /// Directories granted from a card, handed back as `--add-dir`.
        public var addedDirectories: [String]
        /// The running turn's process, while one runs.
        public var run: Run?
        /// Has a turn reached Claude, so the next one resumes rather than
        /// naming the session again? A chat cut off after `system/init`
        /// would otherwise be refused for ever ("session id in use").
        public var started: Bool
        /// The last turn's end — `review` or `failed` — while the balloon has
        /// not shown it (`phase-5`): a relaunch brings its row back until
        /// `ChatSession.unseenLifetime`. Optional, so a file written before
        /// it existed still reads (a missing key is `nil`, "seen").
        public var unseen: Phase?
        /// The chat's `PermissionMode`, by its CLI value. A string, not the
        /// enum: a value this build does not know (or none, from a file
        /// written before modes) reads as `nil` rather than making the whole
        /// file unreadable; `PermissionMode(stored:)` falls back.
        public var permissionMode: String?

        public init(id: String, sessionID: String, title: String? = nil, folder: String,
                    isWorkspace: Bool, createdAt: Date, lastActivity: Date, pinned: Bool = false,
                    lastReply: String? = nil, allowedRules: [String] = [],
                    addedDirectories: [String] = [], run: Run? = nil, started: Bool = false,
                    unseen: Phase? = nil, permissionMode: String? = nil) {
            self.id = id
            self.sessionID = sessionID
            self.title = title
            self.folder = folder
            self.isWorkspace = isWorkspace
            self.createdAt = createdAt
            self.lastActivity = lastActivity
            self.pinned = pinned
            self.lastReply = lastReply
            self.allowedRules = allowedRules
            self.addedDirectories = addedDirectories
            self.run = run
            self.started = started
            self.unseen = unseen
            self.permissionMode = permissionMode
        }
    }

    /// A turn's process: its pid and the start time read when it began, the
    /// pair `Platform.sameProcess` compares against pid recycling.
    public struct Run: Equatable, Codable {
        public var pid: Int32
        public var startedAt: Date?

        public init(pid: Int32, startedAt: Date?) {
            self.pid = pid
            self.startedAt = startedAt
        }
    }

    public enum DecodeError: Error, Equatable {
        case unreadable
        case unsupportedVersion(Int)
        case badID(String)
    }

    public static func decode(_ data: Data) throws -> ChatIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // The version first, alone: a newer file's entries may not decode
        // here, and that must read as "newer", not "broken".
        struct Header: Decodable { let version: Int }
        guard let header = try? decoder.decode(Header.self, from: data) else { throw DecodeError.unreadable }
        guard header.version == currentVersion else { throw DecodeError.unsupportedVersion(header.version) }
        guard let index = try? decoder.decode(ChatIndex.self, from: data) else { throw DecodeError.unreadable }
        if let bad = index.entries.first(where: { UUID(uuidString: $0.id) == nil }) {
            throw DecodeError.badID(bad.id)
        }
        return index
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // Strings, numbers, dates and arrays of them always encode.
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Turns recorded as running when Evlat starts. Evlat was gone while
    /// they ran — quit, crashed or `kill -9` — so each chat is `interrupted`;
    /// a process that is still the same process is also to be ended
    /// (`terminate`); a recycled pid, or one recorded without a start time,
    /// may be someone else's and is left alone.
    ///
    /// Measured (`011/phase-1`): `claude -p` whose parent is killed finishes
    /// the turn in flight and exits by itself (5.5 s on a short reply), so
    /// this is a safety net for a turn that hangs, not the usual path.
    public func orphans(platform: Platform) -> (terminate: [Int32], interrupted: [String]) {
        let running = entries.filter { $0.run != nil }
        let terminate = running.compactMap { entry -> Int32? in
            // Without a start time the pid cannot be told from a recycled
            // one, and signalling a stranger is worse than a hung turn.
            guard let run = entry.run, run.startedAt != nil,
                  platform.sameProcess(pid: run.pid, startedAt: run.startedAt) else { return nil }
            return run.pid
        }
        return (terminate, running.map(\.id))
    }

    // MARK: - History and pruning (`phase-5`)

    /// How long a chat is kept after its last activity, pinned ones aside:
    /// the history cleans itself, the user never has to.
    public static let lifetime: TimeInterval = 7 * 86_400

    /// Entries past `lifetime` at `now`: neither pinned nor running.
    public func expired(at now: Date) -> [Entry] {
        entries.filter { !$0.pinned && $0.run == nil && now.timeIntervalSince($0.lastActivity) >= Self.lifetime }
    }

    /// The history's order: pinned first, then the latest activity first.
    public static func historyOrder(_ a: Entry, _ b: Entry) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.id < b.id
    }

    /// The one path a chat's workspace may be removed from: `chats/<id>`
    /// directly under `root`, the id a UUID read back in its canonical
    /// form. Built from the id alone, **never from an entry's `folder`**:
    /// that is where a user's own folder would be named. `nil` for an id
    /// that is not a UUID — `..`, empty, a path.
    public static func workspace(of id: String, under root: URL) -> URL? {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id.uppercased() else { return nil }
        return root.appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(uuid.uuidString, isDirectory: true)
    }
}

/// Written into the index as its name (`ChatIndex.Entry.unseen`).
extension Phase: Codable {}
