import Foundation

/// An agent on this Mac as one thing to install: its hooks (with the
/// approval hook where the agent has one, `LocalHooks`) and its usage relay
/// (`StatusLineRelay`) where the agent has a status line here. One state,
/// one press, one removal — the user does not set up an agent in parts.
///
/// The parts' own writers stay as they are; this only decides which parts
/// apply, how their states make one, and that parts in the same file are
/// written together. Nothing here has a default path: `home` is the
/// caller's, a temporary one in tests.
public enum AgentIntegration {
    /// A part a write can fail in, named on the card.
    public enum Part: Equatable { case hooks, usage }

    /// A refused write and the part it was refused in. Parts in another file
    /// written before it stay written: the unit then reads outdated, which
    /// offers the press that completes it.
    public struct Failure: Error, Equatable {
        public let part: Part
        public let reason: SettingsFile.Failure

        public init(part: Part, reason: SettingsFile.Failure) {
            self.part = part
            self.reason = reason
        }
    }

    /// The unit at a glance.
    public enum Status: Equatable { case current, outdated, missing }

    public struct State: Equatable {
        public let hooks: LocalHooks.State
        /// `nil`: the relay is not a part here — no status line to wrap
        /// (Codex; the Antigravity app or IDE without its CLI).
        public let relay: StatusLineRelay.State?

        public init(hooks: LocalHooks.State, relay: StatusLineRelay.State?) {
            self.hooks = hooks
            self.relay = relay
        }

        /// Every part that applies current → current; none there → missing;
        /// anything between → outdated. A relay changed by hand is not a
        /// part: it is never written over, so it can neither complete the
        /// unit nor hold it back.
        public var status: Status {
            var parts: [Status] = [Self.status(hooks)]
            switch relay {
            case .current?: parts.append(.current)
            case .missing?: parts.append(.missing)
            case .modified?, nil: break
            }
            if parts.allSatisfy({ $0 == .current }) { return .current }
            if parts.allSatisfy({ $0 == .missing }) { return .missing }
            return .outdated
        }

        /// Whether a press would write the relay.
        public var installsRelay: Bool { relay == .missing }

        private static func status(_ hooks: LocalHooks.State) -> Status {
            switch hooks {
            case .current: return .current
            case .outdated: return .outdated
            case .missing: return .missing
            }
        }
    }

    // MARK: - Files

    /// The status line file, when the relay is a part here.
    public static func relayFile(home: URL, for source: AgentSource) -> URL? {
        source.hasStatusLine(home: home) ? source.statusLineFile(home: home) : nil
    }

    /// The files a press writes, the hooks file first; one entry when both
    /// parts live in the same file (Claude's `settings.json`).
    public static func files(home: URL, for source: AgentSource) -> [URL] {
        let hooks = source.settingsFile(home: home)
        guard let relay = relayFile(home: home, for: source), !sameFile(relay, hooks) else { return [hooks] }
        return [hooks, relay]
    }

    /// Both parts read fresh. A hooks folder the install would make
    /// (`AgentSource.opensHooksDirectory`) reads as missing rather than
    /// unreadable, so the card has its Install to press; any other refusal
    /// to read is thrown.
    public static func state(home: URL, for source: AgentSource) throws -> State {
        let hooks: LocalHooks.State
        do {
            hooks = try LocalHooks.state(at: source.settingsFile(home: home), for: source)
        } catch SettingsFile.Failure.noDirectory where source.opensHooksDirectory {
            hooks = .missing
        }
        let relay = try relayFile(home: home, for: source).map { try StatusLineRelay.state(at: $0, source: source) }
        return State(hooks: hooks, relay: relay)
    }

    /// Every part that applies, installed. Parts in one file are one
    /// write, so that file is never left with half of them; a relay changed
    /// by hand is left as it is.
    public static func install(home: URL, for source: AgentSource) throws {
        let hooksFile = source.settingsFile(home: home)
        guard let relayFile = relayFile(home: home, for: source) else {
            try write(.hooks) { try LocalHooks.install(at: hooksFile, for: source) }
            return
        }
        if sameFile(relayFile, hooksFile) {
            try installTogether(at: hooksFile, for: source)
            return
        }
        try write(.hooks) { try LocalHooks.install(at: hooksFile, for: source) }
        try write(.usage) {
            guard try StatusLineRelay.state(at: relayFile, source: source) != .modified else { return }
            try StatusLineRelay.install(at: relayFile, source: source)
        }
    }

    /// Every part taken out, the relay wherever Evlat's is found — also
    /// one left from when the agent's status line was here. A relay changed
    /// by hand stays.
    public static func remove(home: URL, for source: AgentSource) throws {
        let hooksFile = source.settingsFile(home: home)
        guard let relayFile = source.statusLineFile(home: home) else {
            try write(.hooks) { try LocalHooks.remove(at: hooksFile, for: source) }
            return
        }
        if sameFile(relayFile, hooksFile) {
            try write(.hooks) {
                try SettingsFile.apply(at: hooksFile) { settings in
                    let hooks = LocalHooks.removing(from: settings, for: source, approvals: true)
                    return StatusLineRelay.removing(from: hooks, source: source) ?? hooks
                }
            }
            return
        }
        try write(.hooks) { try LocalHooks.remove(at: hooksFile, for: source) }
        // No folder, no relay: the CLI was never here.
        guard (try? StatusLineRelay.state(at: relayFile, source: source)) == .current else { return }
        try write(.usage) { try StatusLineRelay.remove(at: relayFile, source: source) }
    }

    /// The usage line alone, taken out: the card's way to keep the hooks
    /// and not the relay.
    public static func removeRelay(home: URL, for source: AgentSource) throws {
        guard let file = source.statusLineFile(home: home) else { return }
        try write(.usage) { try StatusLineRelay.remove(at: file, source: source) }
    }

    /// Hooks and relay in one `settings.json`: one transform, one write.
    /// The relay's own backup (`StatusLineRelay.install`) is taken only when
    /// this write wraps the `statusLine` — a write that only updates the
    /// hooks must not replace the kept original with the wrapper.
    private static func installTogether(at file: URL, for source: AgentSource) throws {
        let backup = file.appendingPathExtension(StatusLineRelay.backupExtension)
        do {
            _ = try SettingsFile.apply(at: file, backUp: { settings, mode in
                guard StatusLineRelay.state(of: settings, source: source) == .missing else { return }
                try SettingsFile.replace(backup, with: try StatusLineRelay.backupContents(of: settings), mode: mode)
            }) { settings in
                let hooks = LocalHooks.installing(into: settings, for: source, approvals: true)
                return StatusLineRelay.installing(into: hooks, source: source) ?? hooks
            }
        } catch {
            throw Failure(part: .hooks, reason: error as? SettingsFile.Failure ?? .unwritable)
        }
        // The writers' own check, part by part: what should now be there
        // and is not was refused — a shape not ours to overwrite.
        let settings = (try? SettingsFile.read(file)) ?? [:]
        if LocalHooks.state(of: settings, for: source, approvals: true) != .current {
            throw Failure(part: .hooks, reason: .malformed)
        }
        if StatusLineRelay.state(of: settings, source: source) == .missing {
            throw Failure(part: .usage, reason: .malformed)
        }
    }

    private static func write(_ part: Part, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(part: part, reason: error as? SettingsFile.Failure ?? .unwritable)
        }
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}
