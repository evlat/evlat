import Foundation
import EvlatCore

/// Where an incoming event lands in `phase-3`, and the whole of what happens to
/// it: a counter and the last few lines.
///
/// It deliberately feeds **nothing** into `Registry`. The provider that turns
/// events into phases is `phase-4`'s single line of wiring, and it is also that
/// set's undo switch; registering anything here would put a second row next to
/// the file record's in the bar before the merge rule has ever been exercised
/// against a real event.
///
/// Not thread-safe by design: it is written from the main queue (where
/// `HookListener` delivers) and read from the main queue.
public final class HookDiagnostics {
    /// One event, reduced to what the measurements ask. Nothing is stored that
    /// a later phase would have to be told to stop storing: no body, no tool
    /// name, no message.
    public struct Line: Equatable {
        public let at: Date
        public let source: String
        public let name: String
        public let sessionID: String?
        public let agentID: String?
        public let pid: Int32?
        public let taskID: String?
        public let stopHookActive: Bool

        /// One line, one event, in the order the measurements read them:
        /// when · where from · what · which session · which subagent · which
        /// process. The stamp is epoch milliseconds so it lines up with the
        /// `updatedAt` in `~/.claude/sessions/<pid>.json`, which is the other
        /// half of measurements 1 and 4.
        public var text: String {
            let stamp = Int((at.timeIntervalSince1970 * 1000).rounded())
            return "\(stamp) \(source) \(name)"
                + " session=\(sessionID ?? "-")"
                + " agent=\(agentID ?? "-")"
                + " pid=\(pid.map(String.init) ?? "-")"
                + " task=\(taskID ?? "-")"
                + (stopHookActive ? " stop_hook_active=true" : "")
        }
    }

    public private(set) var total = 0
    public private(set) var byName: [String: Int] = [:]
    /// How many events carried an `agent_id` — the subagent question
    /// (`discussion.md` → Karar 8) counted rather than eyeballed.
    public private(set) var fromSubagents = 0
    public private(set) var recent: [Line] = []

    private let recentLimit: Int

    public init(recentLimit: Int = 40) {
        self.recentLimit = recentLimit
    }

    @discardableResult
    public func record(_ event: HookEvent, at now: Date = Date()) -> Line {
        let line = Line(at: now, source: event.source.rawValue, name: event.name,
                        sessionID: event.sessionID, agentID: event.agentID,
                        pid: event.pid, taskID: event.taskID,
                        stopHookActive: event.stopHookActive)
        total += 1
        // The name is written as the source spelled it, `""` included: an event
        // this version does not know must not be counted as one it does.
        byName[event.name, default: 0] += 1
        if event.agentID != nil { fromSubagents += 1 }
        recent.append(line)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        return line
    }

    /// The summary `--list` prints. Counts first, because a capture under a
    /// real session produces more lines than fit on a screen.
    public var summary: [String] {
        var out = ["hook events: \(total)  ·  with agent_id: \(fromSubagents)"]
        for (name, count) in byName.sorted(by: { $0.key < $1.key }) {
            out.append("  \(count)  \(name.isEmpty ? "(unnamed)" : name)")
        }
        return out
    }
}
