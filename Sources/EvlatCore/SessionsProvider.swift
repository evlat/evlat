import Foundation

/// Reads Claude Code's own session records: `~/.claude/sessions/<pid>.json`.
///
/// **This provider does not replace hooks, it completes them.** State comes
/// from hooks (it did in v1 and it still does); the `status` here is coarse and
/// carries no "waiting for you" distinction. What this file removes is v1's
/// three workarounds:
///   - hooks only fire for sessions started *after* installation, so existing
///     sessions were invisible; here every session shows up at once,
///   - a `kill -9`'d session never sends `Stop`, so hooks left it `working`
///     forever; pid liveness drops the dead ones,
///   - the session name needed a subprocess (`claude agents --json`); `name` is
///     right here.
///
/// **The format is undocumented** (`peerProtocol: 1` implies something
/// versioned), so `Fidelity` is `.derived` and unrecognised `status` values
/// stay visible in `unrecognizedStatuses`.
public final class SessionsProvider: Provider {
    public static let id = "claude-sessions"
    public var id: String { Self.id }

    private let directory: URL
    private let platform: Platform
    /// Unrecognised `status` values seen in the **last** scan. Collected so
    /// they cannot drop silently into `idle`; diagnostics read them from here
    /// (`proje.md` → tuzaklar).
    ///
    /// Reset on every scan, like the counters below. It used to accumulate, so
    /// one session that briefly reported `shell` kept being reported for the
    /// rest of the process — a historical gap was indistinguishable from a live
    /// one, and the key comes straight out of an untrusted file, so a churning
    /// status grew the set without bound.
    public private(set) var unrecognizedStatuses: Set<String> = []
    /// Records that could not be parsed at all in the last scan.
    ///
    /// This is the drift that would otherwise be **invisible**: if `pid` or
    /// `sessionId` were renamed, every record would fail to parse, the list
    /// would come back empty, and the diagnostics would report a healthy idle
    /// machine. The file's contract is that an unrecognised value is never
    /// invisible; that has to hold for the worst case too.
    public private(set) var recordsUnparseable = 0
    /// How many records had an unreadable `updatedAt`. A non-zero count may
    /// mean the format drifted, so like an unrecognised `status` it stays
    /// **visible**.
    public private(set) var recordsMissingUpdatedAt = 0
    /// How many records had an unreadable `statusUpdatedAt`. Counted
    /// separately from the field above because the two are different facts and
    /// the row's stamp is this one: a silent fallback to `updatedAt` would
    /// bring back exactly the skew that moved the stamp here.
    public private(set) var recordsMissingStatusUpdatedAt = 0

    public init(directory: URL, platform: Platform) {
        self.directory = directory
        self.platform = platform
    }

    /// The default location. Never hard-coded at the call site: the caller's
    /// path wins, so tests can hand over a temporary directory.
    public static func defaultDirectory(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(".claude/sessions")
    }

    public func currentSignals() -> [Signal] {
        // A missing directory is not an error: Claude Code may never have run.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        recordsMissingUpdatedAt = 0
        recordsMissingStatusUpdatedAt = 0
        recordsUnparseable = 0
        unrecognizedStatuses = []
        var best: [String: Record] = [:]
        for file in files where file.pathExtension == "json" {
            // A broken record drops alone — but it is counted, not swallowed.
            guard let record = Record(file: file) else { recordsUnparseable += 1; continue }
            // The record's own `startedAt` is what this source contributes to
            // the shared check: a claim, measured against the running process.
            guard platform.sameProcess(pid: record.pid, startedAt: record.startedAt) else { continue }
            if record.updatedAtWasMissing { recordsMissingUpdatedAt += 1 }
            if record.statusUpdatedAtWasMissing { recordsMissingStatusUpdatedAt += 1 }
            // `claude --resume` changes the pid, so one sessionId can survive in
            // two files. Both are live here, so the newer one wins. (The dead
            // one was already dropped above: "the live pid wins".)
            if let existing = best[record.sessionId], existing.updatedAt >= record.updatedAt { continue }
            best[record.sessionId] = record
        }

        return best.values.map { record in
            // A **missing** field and an **unrecognised value** are different
            // things. The first version conflated them and reported a record
            // without the field as an unknown vocabulary word.
            let phase = record.status.flatMap(Self.phase(for:))
            if let status = record.status, phase == nil { unrecognizedStatuses.insert(status) }
            return Signal(
                provider: Self.id,
                entity: record.sessionId,
                kind: .session,
                // An unrecognised state draws as `idle`, but its word survives
                // in `rawStatus` and lands in `unrecognizedStatuses`: never invisible.
                phase: phase ?? .idle,
                label: record.label,
                detail: record.cwd,
                // The session files are Claude Code's own.
                source: .claude,
                fidelity: .derived,
                rawStatus: record.status,
                // The **status** stamp, not the record's. Measured in
                // `phase-3`: the two disagree on 2 of 22 live records, by up
                // to 188 690 ms. `updatedAt` moves when anything in the file
                // is written — a session being renamed, for one — so with that
                // stamp a rename reads three minutes fresher than a live state.
                updatedAt: record.statusUpdatedAt,
                // The record's only fact for the card is the process: it knows
                // no tool, no count and no reply.
                activity: Signal.Activity(pid: record.pid)
            )
        }
        .sorted { $0.entity < $1.entity }  // deterministic; display order is the Registry's job
    }

    /// Maps the source's word to a canonical phase. `nil` means "not known to
    /// us". Values measured on this machine: `busy`, `idle`, and once `shell`.
    /// `waiting` never appeared — that distinction comes from hooks.
    static func phase(for status: String) -> Phase? {
        switch status {
        case "busy": return .working
        case "idle": return .idle
        case "waiting": return .waiting
        default: return nil
        }
    }

    /// A typed view of the file. Only the fields we need are read, so the
    /// format can grow without touching this.
    private struct Record {
        let pid: Int32
        let sessionId: String
        /// `nil` when absent — not an empty string; the two mean different things.
        let status: String?
        let cwd: String
        let name: String?
        /// When the record was last written, for any reason. It answers "which
        /// of two files for one session is current", and only that.
        let updatedAt: Date
        /// When the `status` above was last written. This is the row's stamp:
        /// the two fields are different facts and only this one is about the
        /// state being reported.
        let statusUpdatedAt: Date
        /// When the session (that is, the process) started; separates a
        /// recycled pid from the real one.
        let startedAt: Date?
        /// `updatedAt` could not be read and a fallback was used. A sign the
        /// format may have drifted.
        let updatedAtWasMissing: Bool
        /// The same, for `statusUpdatedAt`.
        let statusUpdatedAtWasMissing: Bool

        var label: String {
            if let name, !name.isEmpty { return name }
            let last = (cwd as NSString).lastPathComponent
            return last.isEmpty ? sessionId : last
        }

        init?(file: URL) {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  let sessionId = json["sessionId"] as? String, !sessionId.isEmpty
            else { return nil }
            self.pid = pid
            self.sessionId = sessionId
            let rawStatus = (json["status"] as? String)?.trimmingCharacters(in: .whitespaces)
            self.status = (rawStatus?.isEmpty ?? true) ? nil : rawStatus
            self.cwd = json["cwd"] as? String ?? ""
            self.name = json["name"] as? String
            let startedAt = (json["startedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            self.startedAt = startedAt
            // Millisecond epoch. A missing field must **not** fall back to 1970:
            // such a record would lose every dedup contest, sink to the bottom
            // of the list, and be wiped by `002`'s stale-record pruning — so a
            // renamed field in this undocumented format would fail invisibly.
            // Order: updatedAt → startedAt → the file's own modification date.
            if let ms = (json["updatedAt"] as? NSNumber)?.doubleValue, ms > 0 {
                self.updatedAt = Date(timeIntervalSince1970: ms / 1000)
                self.updatedAtWasMissing = false
            } else {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                self.updatedAt = startedAt ?? mtime ?? Date(timeIntervalSince1970: 0)
                self.updatedAtWasMissing = true
            }
            // The row's stamp falls back to the record's own, which has
            // already been through the chain above. That chain ends at epoch 0
            // when **every** step fails (no `updatedAt`, no `startedAt`, an
            // unreadable mtime), and this copies it: such a row loses every
            // freshness contest and sinks to the bottom of the list. Rare, but
            // it is a fallback, not an invariant.
            if let ms = (json["statusUpdatedAt"] as? NSNumber)?.doubleValue, ms > 0 {
                self.statusUpdatedAt = Date(timeIntervalSince1970: ms / 1000)
                self.statusUpdatedAtWasMissing = false
            } else {
                self.statusUpdatedAt = self.updatedAt
                self.statusUpdatedAtWasMissing = true
            }
        }
    }
}
