import Foundation

/// An agent's wire identity: the word in its route (`/hook/{id}`), in its
/// stored switch (`agents.enabled`, a machine's `agents`) and in its name
/// key (`source.{id}`). Opaque to the core — nothing here knows which words
/// exist; the catalog does (`EvlatAgents`).
public struct AgentID: RawRepresentable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// One agent, as everything outside its own module sees it. Capabilities are
/// **values**, and a missing one is `nil`: the core asks "does this agent
/// have it", never "which agent is this". A rule that branches on an id is
/// the finding the boundary exists to prevent; anything particular to one
/// agent lives in that agent's values.
///
/// **The canonical vocabulary is Claude Code's**: event names, field names
/// and tool names. Every rule downstream reads only that; each agent's
/// translation into it is its `HookChannel.canonical`.
public protocol Agent {
    var id: AgentID { get }
    /// The directories, relative to a home, whose existence says the agent
    /// is installed; any one is enough. A server's shell asks the same
    /// question (`RemoteSettings`).
    var presence: [String] { get }
    var hooks: HookChannel { get }
    var integration: AgentIntegration.Parts { get }
    /// Where the agent's status line posts its windows, and how they are
    /// read; `nil` when it has none to relay.
    var statusLineUsage: StatusLineUsage? { get }
    /// The agent's permission requests, held on the bar's card; `nil` when
    /// it has no such event.
    var approvals: (any ApprovalChannel)? { get }
    var display: AgentDisplay { get }
    /// The agent's own providers beside its hooks: what it reads from its
    /// own files. Registered while the agent is switched on.
    func providers(_ context: ProviderContext) -> [Provider]
}

extension Agent {
    /// Whether the agent is on this Mac: one of its `presence` directories.
    public func isPresent(home: URL) -> Bool {
        presence.contains { AgentIntegration.isDirectory(home.appendingPathComponent($0)) }
    }

    /// The path its installed command posts to (`HookChannel.paths`).
    public var hookPath: String { hooks.paths[0] }

    /// The file the agent reads its hooks from. `home` has no default: a
    /// caller that forgets to pass one must not land on the user's real
    /// settings.
    public func hooksFile(home: URL) -> URL {
        home.appendingPathComponent(integration.hooksFile)
    }

    /// The file the agent reads its `statusLine` from, where Evlat's usage
    /// relay goes (`StatusLineRelay`); `nil` without one.
    public func statusLineFile(home: URL) -> URL? {
        integration.relay.map { home.appendingPathComponent($0.file) }
    }

    /// Whether the agent's status line can be relayed on this Mac: it has
    /// one, and the program that reads it is here when that is not the
    /// agent's every form (`Relay.requires`).
    public func hasStatusLine(home: URL) -> Bool {
        guard let relay = integration.relay else { return false }
        return relay.requires.map { AgentIntegration.isDirectory(home.appendingPathComponent($0)) } ?? true
    }
}

extension Array where Element == any Agent {
    /// The catalog's agent with that id; `nil` for an id this build does
    /// not know (a newer copy's, stored).
    public subscript(id id: AgentID) -> (any Agent)? {
        first { $0.id == id }
    }

    public var ids: [AgentID] { map(\.id) }
}

/// How an agent's hook events reach the server and become canonical.
public struct HookChannel {
    /// The routes its events are posted to. The first is the one its
    /// installed command carries; any other is a synonym the server keeps
    /// accepting because an older install may spell it that way.
    public let paths: [String]
    /// The events Evlat's command is installed on.
    public let events: [String]
    /// The body names no event, so the command sends it as `X-Evlat-Event`
    /// and is installed once per event (`LocalAPI.installedHookCommand`).
    public let eventInHeader: Bool
    /// Translates a body into the canonical vocabulary. An event the
    /// translation does not know passes **unchanged** rather than dropped:
    /// an unrecognised name stays visible downstream. `HookEvent.taskKey`
    /// and `HookEvent.pidKey` are already in the body when this runs — the
    /// server writes them first — so it must carry them through.
    public let canonical: ([String: Any]) -> [String: Any]
    /// For an agent whose finish carries no reply: the reply read in its
    /// place, from this Mac's files under `roots` (the listener's). Asked
    /// only of a request from this Mac. With a hook here, the body's own
    /// `last_assistant_message` is never taken.
    public let finish: ((_ json: [String: Any], _ roots: [URL]) -> String?)?
    /// The folders under a home that `finish` may read from: the listener's
    /// `roots`, never a constant. Empty without a `finish`.
    public let finishRoots: (_ home: URL) -> [URL]

    public init(paths: [String], events: [String], eventInHeader: Bool = false,
                canonical: @escaping ([String: Any]) -> [String: Any] = { $0 },
                finish: ((_ json: [String: Any], _ roots: [URL]) -> String?)? = nil,
                finishRoots: @escaping (_ home: URL) -> [URL] = { _ in [] }) {
        self.paths = paths
        self.events = events
        self.eventInHeader = eventInHeader
        self.canonical = canonical
        self.finish = finish
        self.finishRoots = finishRoots
    }
}

/// A hooks file's shape: how Evlat's entries are found, written and taken
/// out. The three-level `hooks` block Claude Code and Codex share is
/// `HookSettings.Format`; an agent with a shape of its own brings its own.
public protocol HooksFormat {
    func state(of settings: [String: Any], hooks: HookChannel) -> HookSettings.State
    func installing(into settings: [String: Any], hooks: HookChannel) -> [String: Any]
    func removing(from settings: [String: Any], hooks: HookChannel) -> [String: Any]
}

/// The part of a status line its windows are read from (`UsageReport`), and
/// what they are called on the bar.
public struct StatusLineUsage: Equatable {
    /// How the JSON carries one window's numbers.
    public enum Reading: Equatable {
        /// `used_percentage` (0–100) and `resets_at` (epoch seconds).
        case usedPercentage
        /// `remaining_fraction` (0–1, what is left) and `reset_time`
        /// (RFC 3339).
        case remainingFraction
    }

    /// A key under `root` and the window's length in minutes.
    public struct Window: Equatable {
        public let key: String
        public let minutes: Int

        public init(_ key: String, minutes: Int) {
            self.key = key
            self.minutes = minutes
        }
    }

    /// The route the relay posts to.
    public let path: String
    /// The local provider's id; a machine's instance derives its own.
    public let providerID: String
    /// The name the windows are grouped under on the bar. A proper name,
    /// not catalogue text (`Signal.Usage.group`).
    public let group: String
    public let fidelity: Signal.Fidelity
    /// The key under which the windows sit.
    public let root: String
    /// The windows drawn. A key under `root` that is not here stays
    /// unrecognized and visible in `--capture`.
    public let windows: [Window]
    public let reading: Reading

    public init(path: String, providerID: String, group: String, fidelity: Signal.Fidelity,
                root: String, windows: [Window], reading: Reading) {
        self.path = path
        self.providerID = providerID
        self.group = group
        self.fidelity = fidelity
        self.root = root
        self.windows = windows
        self.reading = reading
    }
}

/// An agent's permission requests, held until the user answers on the card
/// (`ApprovalHook`'s route). The request and its answer are the agent's
/// wire format; what the card draws is the shared `HeldRequest`.
public protocol ApprovalChannel {
    /// Whether a tool, by its canonical name, asks the user a question
    /// rather than for permission: its wait is an answer.
    func isQuestion(_ tool: String) -> Bool
    /// The request's body; `nil` when it is not one the card can hold.
    func request(json: [String: Any]) -> HeldRequest?
    /// The answer's body.
    func body(_ decision: PermissionHook.Decision) -> String
    /// The hook that sends the requests, beside the command in the same
    /// settings file (`LocalHooks`).
    func state(of settings: [String: Any]) -> HookSettings.State
    func installing(into settings: [String: Any]) -> [String: Any]
    func removing(from settings: [String: Any]) -> [String: Any]
}

/// What the shell draws for an agent, as plain data.
public struct AgentDisplay {
    /// The catalogue key of its name (`source.{id}`).
    public let nameKey: String
    /// Its mark, drawn inside a session's ring: rings of points in a unit
    /// box, filled even-odd. Empty draws no mark.
    public let outline: [[CGPoint]]

    public init(nameKey: String, outline: [[CGPoint]] = []) {
        self.nameKey = nameKey
        self.outline = outline
    }
}

/// What an agent's own providers are made with (`Agent.providers`).
public struct ProviderContext {
    /// The home the agent's files are read under.
    public let home: URL
    public let platform: Platform
    /// Where session records are read instead of the agent's own folder,
    /// when one is set (`EVLAT_SESSIONS`): the empty folder that makes "no
    /// session" measurable.
    public let sessionRecords: URL?
    /// Sessions that are Evlat's own chats: their turns write records too.
    public let excludingSessions: () -> Set<String>

    public init(home: URL, platform: Platform, sessionRecords: URL? = nil,
                excludingSessions: @escaping () -> Set<String> = { [] }) {
        self.home = home
        self.platform = platform
        self.sessionRecords = sessionRecords
        self.excludingSessions = excludingSessions
    }
}

/// The local API's agent routes, as plain data made from the catalog: the
/// listener is handed it and `LocalAPI.dispatch` reads it, so the core holds
/// no agent's path.
public struct RouteTable: Equatable {
    /// Every hook path starts with this, and the first agent's installed
    /// command posts to it bare. It is also how Evlat's command is
    /// recognised in a settings file (`HookSettings`): the prefix of the
    /// command already installed, so it cannot move.
    public static let installedPrefix = "/hook"

    /// Hook path → the agent posting there.
    public let hooks: [String: AgentID]
    /// Usage path → the agent whose status line posts there.
    public let usage: [String: AgentID]
    /// The agent whose permission requests `/approval` holds.
    public let approval: AgentID?

    public init(hooks: [String: AgentID] = [:], usage: [String: AgentID] = [:], approval: AgentID? = nil) {
        self.hooks = hooks
        self.usage = usage
        self.approval = approval
    }

    /// The table for `agents`. A path claimed twice keeps its first agent;
    /// the catalog's test holds that none is.
    public init(_ agents: [any Agent]) {
        var hooks: [String: AgentID] = [:]
        var usage: [String: AgentID] = [:]
        for agent in agents {
            for path in agent.hooks.paths where hooks[path] == nil { hooks[path] = agent.id }
            if let path = agent.statusLineUsage?.path, usage[path] == nil { usage[path] = agent.id }
        }
        self.init(hooks: hooks, usage: usage, approval: agents.first { $0.approvals != nil }?.id)
    }
}
