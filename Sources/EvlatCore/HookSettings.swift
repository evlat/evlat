import Foundation

/// Adds, updates and removes Evlat's hook command in an agent's settings file.
/// Claude Code and Codex share the same three-level shape: event → groups →
/// `{type, command, timeout}`.
///
/// The command written is `LocalAPI.installedHookCommand(for:)` and nothing
/// else, so the golden test that pins it pins what lands in the user's file.
/// No path has a default and nothing is read from the environment: the caller
/// hands in the file, and a test hands in a temporary one.
///
/// The transformations are pure (dictionary in, dictionary out); how the
/// file is read and written is `SettingsFile`'s.
public enum HookSettings {
    public enum State: Equatable { case missing, current, outdated }

    /// The file half is `SettingsFile`'s; its outcome and failures are these.
    public typealias Outcome = SettingsFile.Outcome
    public typealias Failure = SettingsFile.Failure

    /// Ownership prefix. Derived, never spelled: it follows the port and the
    /// route prefix every command is built from (`RouteTable.installedPrefix`).
    /// Each agent has its own file, so a match in a file belongs to that
    /// file's agent.
    static var marker: String { "127.0.0.1:\(LocalAPI.defaultPort)\(RouteTable.installedPrefix)" }

    /// The shared three-level shape, as an agent's `HooksFormat`.
    public struct Format: HooksFormat {
        public init() {}

        public func state(of settings: [String: Any], hooks: HookChannel) -> State {
            HookSettings.state(of: settings, hooks: hooks)
        }

        public func installing(into settings: [String: Any], hooks: HookChannel) -> [String: Any] {
            HookSettings.installing(into: settings, hooks: hooks)
        }

        public func removing(from settings: [String: Any], hooks: HookChannel) -> [String: Any] {
            HookSettings.removing(from: settings, hooks: hooks)
        }
    }

    /// A group is `Any`: another tool may have written something that is not
    /// an object, and a `[[String: Any]]` cast would drop the whole list —
    /// v1's install then deleted that tool's groups.
    private static func isOurs(_ group: Any) -> Bool {
        guard let group = group as? [String: Any],
              let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    // MARK: - Pure

    /// Outdated means one of our commands differs from today's, or an event is
    /// missing one — either way a single install brings it back.
    public static func state(of settings: [String: Any], for agent: some Agent) -> State {
        state(of: settings, hooks: agent.hooks)
    }

    static func state(of settings: [String: Any], hooks channel: HookChannel) -> State {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let ours = channel.events.map { event in
            (hooks[event] as? [Any] ?? [])
                .compactMap { $0 as? [String: Any] }
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
                .filter { $0.contains(marker) }
        }
        guard ours.contains(where: { !$0.isEmpty }) else { return .missing }
        // A duplicate (two installs stacked on one event) fires every hook
        // twice; calling it outdated is what offers the install that folds it.
        guard !ours.contains(where: { $0.count != 1 }) else { return .outdated }
        let command = LocalAPI.installedHookCommand(for: channel)
        return ours.joined().allSatisfy { $0 == command } ? .current : .outdated
    }

    /// Our first group changes in place, any further one is dropped, and an
    /// event without one gets it appended. Other tools' groups keep their
    /// index: Codex keys the trust it records for a hook by that index, and
    /// removing-then-appending shifted every group behind ours.
    public static func installing(into settings: [String: Any], for agent: some Agent) -> [String: Any] {
        installing(into: settings, hooks: agent.hooks)
    }

    static func installing(into settings: [String: Any], hooks channel: HookChannel) -> [String: Any] {
        let ours: [String: Any] = ["hooks": [[
            "type": "command", "command": LocalAPI.installedHookCommand(for: channel), "timeout": 5,
        ]]]
        // A `hooks` that is not an object is someone else's data, same rule
        // as for an event's value below: it is left and nothing is installed.
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { return settings }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in channel.events {
            // A value that is not an array is not ours to overwrite. It is
            // left, the event stays uninstalled and the state says outdated.
            guard hooks[event] == nil || hooks[event] is [Any] else { continue }
            let groups = hooks[event] as? [Any] ?? []
            if let first = groups.firstIndex(where: isOurs) {
                hooks[event] = groups.enumerated().compactMap { index, group -> Any? in
                    index == first ? ours : (isOurs(group) ? nil : group)
                }
            } else {
                hooks[event] = groups + [ours]
            }
        }
        var result = settings
        result["hooks"] = hooks
        return result
    }

    /// Only our groups go; an event key we emptied goes with them. An event
    /// that held none of ours is left exactly as it was.
    public static func removing(from settings: [String: Any], for agent: some Agent) -> [String: Any] {
        removing(from: settings, hooks: agent.hooks)
    }

    static func removing(from settings: [String: Any], hooks channel: HookChannel) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for event in channel.events {
            guard let groups = hooks[event] as? [Any], groups.contains(where: isOurs) else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var result = settings
        result["hooks"] = hooks
        return result
    }

    // MARK: - Files

    public static func state(at url: URL, for source: some Agent) throws -> State {
        state(of: try SettingsFile.read(url), for: source)
    }

    /// An install that changes nothing yet leaves the hooks short of current
    /// met a value that is not ours to overwrite (a `hooks` that is not an
    /// object, an event that is not an array). Returning `unchanged` would
    /// clear the menu's line and offer the same entry forever; it is refused.
    @discardableResult
    public static func install(at url: URL, for source: some Agent) throws -> Outcome {
        let outcome = try apply(at: url) { installing(into: $0, for: source) }
        if outcome == .unchanged, try state(at: url, for: source) != .current { throw Failure.malformed }
        return outcome
    }

    @discardableResult
    public static func remove(at url: URL, for source: some Agent) throws -> Outcome {
        try apply(at: url) { removing(from: $0, for: source) }
    }

    /// `SettingsFile.apply`, kept here so the test that changes the file in
    /// the gap before the write names the writer it is about.
    static func apply(
        at url: URL,
        beforeWrite: () -> Void = {},
        _ transform: ([String: Any]) -> [String: Any]
    ) throws -> Outcome {
        try SettingsFile.apply(at: url, beforeWrite: beforeWrite, transform)
    }
}
