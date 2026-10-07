import Foundation

/// A computer reached over `ssh`, whose sessions reach this Mac through a
/// reverse tunnel. The tunnel's rules — who may be a target, which arguments
/// `ssh` is given, how long to wait after a failure, what a failure was — are
/// all here and pure; the process and the listener are the shell's
/// (`RemoteTunnels`), the same split as `LocalAPI` and `HookListener`.
public struct RemoteMachine: Codable, Equatable {
    /// Stable for the life of the entry: it names the rows' namespace
    /// (`remote:<id>:`), so it must not follow the target when that changes.
    public let id: String
    /// What `ssh` is given after `--`: a `~/.ssh/config` alias or `user@host`.
    public let target: String
    /// The agents followed on this machine (its cards' switches), as
    /// `EnabledAgents` stores them; independent of this Mac's set.
    ///
    /// **`nil` is a live answer, not a value**, as for this Mac: every agent
    /// is on, and one the server does not have is dropped by its reading.
    /// Only a user's change writes it, and the synthesized encoder leaves a
    /// `nil` out, so an entry stored before the field reads back unchanged.
    public var agents: [String]?

    /// `nil` for a target `validate` refuses: an invalid machine cannot be
    /// built, so no later step has to ask again.
    public init?(id: String, target: String, agents: [String]? = nil) {
        guard Self.validate(target: target) == nil, !id.isEmpty else { return nil }
        self.id = id
        self.target = target
        self.agents = agents
    }

    /// A stored entry is re-validated on the way in: the value came from a
    /// file this process does not own (`UserDefaults`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let target = try container.decode(String.self, forKey: .target)
        // A newer copy may store more; an older one never wrote it.
        let agents = try container.decodeIfPresent([String].self, forKey: .agents)
        guard let machine = RemoteMachine(id: id, target: target, agents: agents) else {
            throw DecodingError.dataCorruptedError(forKey: .target, in: container,
                                                   debugDescription: "not a usable ssh target")
        }
        self = machine
    }

    /// The name drawn next to a row: `host` from `user@host`, an alias as it
    /// is. A proper name, not catalogue text.
    public var name: String {
        guard let at = target.lastIndex(of: "@") else { return target }
        let host = target[target.index(after: at)...]
        return host.isEmpty ? target : String(host)
    }

    /// The agents of `catalog` whose rows and usage this machine's tunnel
    /// delivers. A stored name this build does not know is skipped and kept
    /// as it was.
    public func enabledAgents(of catalog: [AgentID]) -> Set<AgentID> {
        EnabledAgents.resolve(stored: agents, catalog: catalog, isPresent: { _ in true })
    }

    /// What the machine's providers are given (`HooksProvider`,
    /// `StatusLineUsageProvider`).
    public var identity: Signal.Machine.Identity {
        Signal.Machine.Identity(id: id, name: name)
    }

    public enum TargetProblem: Error, Equatable {
        case empty
        /// `ssh` would read it as an option: `-oProxyCommand=…` runs a command.
        case option
        /// A space or a control character: never part of a host name, and a
        /// sign the field holds something else.
        case invalidCharacter
    }

    /// Why a target is refused, or `nil`. The target is also passed after
    /// `--`, so this is the first of two locks against option injection.
    public static func validate(target: String) -> TargetProblem? {
        if target.isEmpty { return .empty }
        if target.hasPrefix("-") { return .option }
        let refused = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        if target.unicodeScalars.contains(where: refused.contains) { return .invalidCharacter }
        return nil
    }

    // MARK: - Which machines

    /// The `UserDefaults` key the stored list lives under. Renaming it loses
    /// the stored list silently.
    public static let storageKey = "remote.machines"

    /// The machines this process opens tunnels to, and whether they came from
    /// the environment (then they are read, never written back).
    public struct Configuration: Equatable {
        public let machines: [RemoteMachine]
        public let fromEnvironment: Bool
        /// Refused `EVLAT_MACHINES` entries, kept so a typo is visible
        /// instead of a machine that silently never appears.
        public let rejected: [String]

        public init(machines: [RemoteMachine], fromEnvironment: Bool, rejected: [String]) {
            self.machines = machines
            self.fromEnvironment = fromEnvironment
            self.rejected = rejected
        }
    }

    /// `EVLAT_MACHINES` (comma separated; empty means none) over the stored
    /// list. In a second process (`Isolation.hasOwnSocket`) without
    /// `EVLAT_MACHINES`, no machine at all: a process being measured must
    /// not open a second tunnel to the user's servers and find the running
    /// Evlat's channel there.
    ///
    /// An environment machine's id is its target: there is nowhere to keep a
    /// generated one, and the namespace only has to be stable for the run.
    public static func configuration(environment: [String: String], stored: Data?) -> Configuration {
        if let raw = environment["EVLAT_MACHINES"] {
            var machines: [RemoteMachine] = []
            var rejected: [String] = []
            for part in raw.split(separator: ",") {
                let target = part.trimmingCharacters(in: .whitespaces)
                if target.isEmpty { continue }
                if let machine = RemoteMachine(id: target, target: target) {
                    if !machines.contains(where: { $0.id == machine.id }) { machines.append(machine) }
                } else {
                    rejected.append(target)
                }
            }
            return Configuration(machines: machines, fromEnvironment: true, rejected: rejected)
        }
        if Isolation.hasOwnSocket(environment) {
            return Configuration(machines: [], fromEnvironment: true, rejected: [])
        }
        return Configuration(machines: decode(stored), fromEnvironment: false, rejected: [])
    }

    /// The stored list, entry by entry: one unreadable entry drops itself,
    /// not its neighbours.
    public static func decode(_ data: Data?) -> [RemoteMachine] {
        guard let data,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard let object = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(RemoteMachine.self, from: object)
        }
    }

    public static func encode(_ machines: [RemoteMachine]) -> Data? {
        try? JSONEncoder().encode(machines)
    }
}

/// One machine's tunnel: the `ssh` arguments, the reconnect schedule, what a
/// failure was, and the state machine that ties them together.
///
/// A tunnel is an `ssh` master of Evlat's own, then a **channel** over it:
/// the server's socket (`EvlatSocket.relativePath` under its home, the one
/// its installed commands speak to) forwarded to a socket of the machine's
/// own on this Mac (`channelPath`). In that order, each step on the last:
///
/// 1. the master logs in and its remote command prints a mark (`arguments`);
/// 2. one `sh -s` over the master probes the server's socket and reads the
///    machine (`channelProbe`, in `RemoteSettings.readingScript`): one that
///    answers is another Evlat's — another Mac's — and is never touched;
///    one that refuses or stays silent is a dead connection's, and goes;
/// 3. `ssh -O forward -R <server socket>:<this Mac's>` over the master
///    (`forwardArguments`). Only then is the machine connected.
///
/// Not `-R` on the master's own command line: a master remembers a forward
/// that failed at its start and never asks again.
///
/// The process is not here. The shell is told to start or stop it, probe and
/// forward (`Effects`), and tells this type what happened (`exited`,
/// `marked`, `probed`, `forwarded`, `heard`); the clock and the deferred call
/// are injected, so the schedule is tested without waiting on it. **Not
/// thread-safe**: every call on the main queue.
public final class RemoteTunnel {
    // MARK: - Arguments

    /// Every option is load-bearing:
    /// - `askpass` (Evlat's own helper is in the environment, `RemoteTunnels`):
    ///   `BatchMode=no`, so a password, a passphrase or an unknown host key
    ///   is a prompt — and every prompt goes to the helper, never to a
    ///   terminal. A helper's refusal sends no password at all, and a refused
    ///   host key still ends in `Host key verification failed.` (measured,
    ///   OpenSSH 10.2p1). `NumberOfPasswordPrompts=1`: a wrong password is
    ///   one try, not three. Without a helper, `BatchMode=yes` as before: no
    ///   prompt at all, else a controlling terminal — `swift run`'s — would
    ///   be asked.
    /// - `ServerAlive*`: a dead network is noticed in ~45 s.
    /// - `-M -S <controlPath> -o ControlPersist=no`: the process is a master
    ///   connection of **Evlat's own**: the channel is made over it, and the
    ///   installs and reads (`RemoteSettings.arguments`) ride it instead of
    ///   logging in again. It lives exactly as long as this process and
    ///   leaves no background master behind. On the command line the three
    ///   win over a host's `ControlMaster`/`ControlPath`/`ControlPersist`,
    ///   so the user's own master is never used — riding it would make this
    ///   process's exit say nothing about the tunnel.
    /// - `RemoteCommand=none`, `StdinNull=no`, `ForkAfterAuthentication=no`:
    ///   a host's `~/.ssh/config` may set them (`RemoteCommand tmux new -A` is
    ///   common); the first refuses a command-line command outright, the other
    ///   two hand `cat` an empty stdin and take the dead man's switch away.
    ///   On the command line they win over the config file.
    /// - The remote command prints `mark` — the login is done, the master
    ///   is up — on a line of its own: a newline first, since a login
    ///   script's last words may have none (`MarkScanner` takes whole
    ///   lines only). Then it holds the session open for as long as its stdin does,
    ///   and its stdin is a pipe this Mac's Evlat holds: when Evlat dies,
    ///   `kill -9` included, the pipe reaches EOF, `cat` ends and `ssh`
    ///   exits — no orphan holding the channel.
    public static func arguments(target: String, controlPath: String, mark: String,
                                 askpass: Bool = false) -> [String] {
        let prompts = askpass ? ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"] : ["-o", "BatchMode=yes"]
        return ["-T"]
            + prompts
            + ["-o", "ServerAliveInterval=15",
               "-o", "ServerAliveCountMax=3",
               "-o", "ConnectTimeout=10",
               "-M", "-S", controlPath, "-o", "ControlPersist=no",
               "-o", "RemoteCommand=none",
               "-o", "StdinNull=no",
               "-o", "ForkAfterAuthentication=no",
               "--", target, "echo; echo \(mark); exec cat >/dev/null"]
    }

    /// The master's own line of output: `evlat-channel-<nonce>`, new for
    /// each launch, found behind whatever a login script printed first.
    public static func mark(nonce: String) -> String { "evlat-channel-" + nonce }

    /// The channel's forward, asked of the running master: the server's
    /// socket `remote` (absolute: `-R` does not expand `~`) to this Mac's
    /// `local`. `ProxyCommand=/usr/bin/false`: a master that has just gone
    /// is no call, never a login of its own.
    public static func forwardArguments(target: String, controlPath: String, remote: String,
                                        local: String) -> [String] {
        ["-S", controlPath,
         "-o", "ControlMaster=no",
         "-o", "ProxyCommand=/usr/bin/false",
         "-O", "forward",
         "-R", remote + ":" + local,
         "--", target]
    }

    // MARK: - Master socket

    /// The longest control path `ssh` can use: a unix socket's `sun_path`
    /// holds 104 bytes with its terminator, and `ssh` binds the master at
    /// the path plus a 17-character temporary suffix before renaming it.
    public static let socketPathLimit = 104 - 17 - 1

    /// Where the machine's master listens: `<directory>/<8 hex>`, the hex a
    /// digest of the id — stable across launches, so a socket a killed
    /// master left behind is found again by the next one. `nil` when the
    /// path would not fit (`socketPathLimit`) or holds a `%`, which `ssh`
    /// expands in a control path; the tunnel then has no master and no
    /// channel.
    public static func controlPath(directory: String, machineID: String) -> String? {
        socketPath(directory: directory, machineID: machineID, suffix: "", limit: socketPathLimit)
    }

    /// Where the machine's channel ends on this Mac — the machine's own
    /// listener: the master's path with `.sock`. `ssh` connects to it, so
    /// the limit is an address's (`EvlatSocket.pathLimit`); and no `:`,
    /// which `-R` reads as its separator.
    public static func channelPath(directory: String, machineID: String) -> String? {
        socketPath(directory: directory, machineID: machineID, suffix: ".sock", limit: EvlatSocket.pathLimit)
            .flatMap { $0.contains(":") ? nil : $0 }
    }

    private static func socketPath(directory: String, machineID: String, suffix: String, limit: Int) -> String? {
        var trimmed = directory
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, !trimmed.contains("%") else { return nil }
        // FNV-1a, 32 bits: `Hasher` is seeded per process.
        var digest: UInt32 = 0x811c_9dc5
        for byte in machineID.utf8 {
            digest = (digest ^ UInt32(byte)) &* 0x0100_0193
        }
        let path = (trimmed == "/" ? "" : trimmed) + "/" + String(format: "%08x", digest) + suffix
        return path.utf8.count <= limit ? path : nil
    }

    /// The environment `ssh` runs with: Evlat's own, so `SSH_AUTH_SOCK` and
    /// the rest reach it as they would from a terminal, with the tunnel's
    /// askpass variables added on top. Only the tunnel is given those.
    public static func environment(base: [String: String], askpass: [String: String]?) -> [String: String] {
        base.merging(askpass ?? [:]) { _, added in added }
    }

    // MARK: - Failures

    public enum Failure: String, Equatable {
        case authentication
        /// The server's socket answers: another Evlat — another Mac's —
        /// has its channel there, and it is left alone (`probed`).
        case channelBusy
        /// The probe found the socket free and the forward failed: the
        /// server allows no socket forwarding (`AllowStreamLocalForwarding`,
        /// `DisableForwarding`, `AllowTcpForwarding`), or another Mac took
        /// the socket in between — the next try's probe tells which.
        case forwardingRefused
        case hostKey
        case hostName
        case unreachable
        /// A password was asked on a quiet try and nobody could answer it
        /// (`RemoteTunnel.exited`); never read from `ssh`'s lines.
        case passwordNeeded
        case other
    }

    /// OpenSSH's fixed lines. The more specific ones are asked first: an
    /// unknown host's output can carry a warning line before the one that
    /// says what went wrong. A refused forward is not read from its line:
    /// a socket in the way and a server that allows no forwarding print the
    /// same one (measured, OpenSSH 9.6p1), so the probe before it decides.
    private static let failureLines: [(String, Failure)] = [
        ("Host key verification failed", .hostKey),
        ("Could not resolve hostname", .hostName),
        ("Permission denied", .authentication),
        ("Connection refused", .unreachable),
        ("timed out", .unreachable),
        ("Network is unreachable", .unreachable),
        ("No route to host", .unreachable),
    ]

    public static func classify(stderr: String) -> Failure {
        for (text, failure) in failureLines where stderr.contains(text) { return failure }
        return .other
    }

    // MARK: - Schedule

    /// The wait after the first failure, doubled after each next one.
    public static let initialDelay: TimeInterval = 2
    /// The ceiling: a server that is down for the night is asked every five
    /// minutes, not every two seconds.
    public static let maximumDelay: TimeInterval = 5 * 60
    /// A tunnel that stayed up this long starts the schedule over when it
    /// drops.
    public static let stableAfter: TimeInterval = 60
    /// How long a try has, from its launch or its last prompt's answer, to
    /// make its channel: past `ConnectTimeout` (10 s), the probe's `curl`
    /// (5 s) and the forward, with room for a slow host. A master whose
    /// mark never comes — a server's shell that holds the command, a host
    /// that swallows it — ends then, as `other`, instead of reading
    /// connected while it carries nothing.
    public static let defaultChannelDeadline: TimeInterval = 30

    /// The wait after `failures` consecutive failures (1 = the first).
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let doublings = min(failures - 1, 16)
        return min(initialDelay * pow(2, Double(doublings)), maximumDelay)
    }

    // MARK: - State

    public enum State: Equatable {
        /// Not started, asleep or removed. No process runs.
        case stopped
        case connecting
        case connected(since: Date)
        case waiting(retryAt: Date, failure: Failure)
        /// Stopped until the user acts (`retryByUser`): a password that was
        /// sent was refused (`rejected`), or a quiet try was asked for one
        /// on a machine a password is known to open. No timer runs; a wake
        /// and a start keep it — another try would only be refused again,
        /// each one a failed login in the server's log.
        case needsUser(rejected: Bool)

        /// Stopped for the user's password, or waiting for want of one:
        /// what offers "Enter Password…" and the attention line.
        public var wantsPassword: Bool {
            switch self {
            case .needsUser, .waiting(_, .passwordNeeded): return true
            default: return false
            }
        }

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        public var text: String {
            let iso = ISO8601DateFormatter()
            switch self {
            case .stopped: return "stopped"
            case .connecting: return "connecting"
            case .connected(let since): return "connected since \(iso.string(from: since))"
            case .waiting(let at, let failure): return "waiting (\(failure.rawValue)) until \(iso.string(from: at))"
            case .needsUser(let rejected): return rejected ? "password refused" : "waiting for a password"
            }
        }
    }

    /// What the shell does for this type. `launch` starts one `ssh` process
    /// and reports its exit to `exited(generation:stderr:)` with the
    /// generation it was given; `terminate` stops the running one. `probe`
    /// runs the probe over the master and reports to `probed`; `forward`
    /// asks the master for the channel and reports to `forwarded`.
    public struct Effects {
        public var launch: (_ generation: Int) -> Void
        public var terminate: () -> Void
        public var now: () -> Date
        /// Runs the closure after the interval; the returned closure cancels it.
        public var schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
        /// Whether a password is stored for the machine (`SSHPasswordStore`).
        public var hasStoredPassword: () -> Bool
        public var probe: (_ generation: Int) -> Void
        /// The server's socket, absolute, to forward.
        public var forward: (_ generation: Int, _ remote: String) -> Void

        public init(launch: @escaping (Int) -> Void, terminate: @escaping () -> Void,
                    now: @escaping () -> Date,
                    schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void,
                    hasStoredPassword: @escaping () -> Bool = { false },
                    probe: @escaping (Int) -> Void = { _ in },
                    forward: @escaping (Int, String) -> Void = { _, _ in }) {
            self.launch = launch
            self.terminate = terminate
            self.now = now
            self.schedule = schedule
            self.hasStoredPassword = hasStoredPassword
            self.probe = probe
            self.forward = forward
        }
    }

    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { onChange?(state) } }
    }
    /// Called on every change of `state`, synchronously.
    public var onChange: ((State) -> Void)?

    /// Who a try's prompts go to. `quiet`: only a stored password answers,
    /// and only a password prompt — anything else is refused. `interactive`:
    /// the user is asked. Only the user's own press (`retryByUser`) and a
    /// machine just added (`start(interactive:)`) try interactively; every
    /// try on the schedule, after a wake or at launch, is quiet.
    public enum Mode: Equatable { case quiet, interactive }

    /// The running try's mode; the last one's while none runs.
    public private(set) var mode: Mode = .quiet
    /// The last connection was made with a password. In memory: a launch
    /// starts without it (a stored password stands in for it then).
    public private(set) var lastConnectedWithPassword = false

    /// What the running try has met, for `exited` to read.
    private struct Attempt {
        var sentPassword = false
        var refusedPassword = false
        /// Another question came after the password (a second factor): a
        /// refused login then says nothing about the password.
        var askedAfterPassword = false
        var heldPrompts = 0
        /// The master printed its mark: the probe was asked for.
        var marked = false
        /// The probe found a file it could not ask (`Channel.Socket.unknown`):
        /// a refused forward then says nothing about the server's rules.
        var forwardUncertain = false
        /// Why the channel was not made; the exit that follows says this,
        /// not its own stderr (`failChannel`).
        var channelFailure: Failure?
    }
    private var current = Attempt()

    private let effects: Effects
    private let channelDeadline: TimeInterval
    private var enabled = false
    private var asleep = false
    /// Which launch a report is about. A process terminated for sleep reports
    /// its exit after the next one may already be running; that report must
    /// not touch the new one's state.
    private var generation = 0
    private var running = false
    private var failures = 0
    private var cancelPending: (() -> Void)?

    public init(effects: Effects, channelDeadline: TimeInterval = RemoteTunnel.defaultChannelDeadline) {
        self.effects = effects
        self.channelDeadline = channelDeadline
    }

    /// Begin connecting, and keep reconnecting until `stop`. `interactive`
    /// asks the user on the first try (a machine just added). Waiting for the
    /// user stays waiting.
    public func start(interactive: Bool = false) {
        enabled = true
        guard !asleep, !running, !isWaitingForUser else { return }
        attempt(interactive ? .interactive : .quiet)
    }

    /// The user's press ("Enter password…"): the only way out of
    /// `needsUser`. An interactive try at once, the schedule from zero; a
    /// pending wait is dropped.
    public func retryByUser() {
        guard enabled, !asleep, !running else { return }
        failures = 0
        attempt(.interactive)
    }

    /// Whether the machine is known to want a password: what the setup
    /// buttons' "connect first" reads.
    public var asksForPassword: Bool {
        state.wantsPassword || lastConnectedWithPassword
    }

    private var isWaitingForUser: Bool {
        if case .needsUser = state { return true }
        return false
    }

    // MARK: - Prompts

    /// The running try's `ssh` asked something and the answer is pending.
    /// Until it is answered the try cannot be called connected.
    public func promptOpened() {
        guard running else { return }
        current.heldPrompts += 1
        cancel()
    }

    /// The prompt was answered; `sentPassword` when what went back is a
    /// password (stored or typed). The wait for the connection starts over.
    public func promptAnswered(sentPassword: Bool) {
        guard running else { return }
        if current.sentPassword, !sentPassword { current.askedAfterPassword = true }
        if sentPassword { current.sentPassword = true }
        promptClosed()
    }

    /// The prompt was refused (or abandoned); `password` when it was a
    /// password prompt.
    public func promptRefused(password: Bool) {
        guard running else { return }
        if current.sentPassword, !password { current.askedAfterPassword = true }
        if password { current.refusedPassword = true }
        promptClosed()
    }

    private func promptClosed() {
        current.heldPrompts = max(0, current.heldPrompts - 1)
        if current.heldPrompts == 0, state == .connecting { scheduleDeadline() }
    }

    /// Stop for good: the machine was removed or the app is quitting.
    public func stop() {
        enabled = false
        halt()
    }

    /// The Mac is going to sleep. The process is closed cleanly, so the
    /// server lets go of the channel at once instead of holding it until
    /// its keepalive gives up.
    public func sleep() {
        asleep = true
        halt()
    }

    /// Awake again: whatever wait was pending is dropped and the tunnel is
    /// tried now. The schedule starts over — the failures it counted were
    /// the network before the sleep.
    public func wake() {
        asleep = false
        guard enabled, !running, !isWaitingForUser else { return }
        failures = 0
        attempt(.quiet)
    }

    /// A request arrived on this machine's listener. Only the channel can
    /// carry one there, so it is connected, whatever the forward's own
    /// answer has not said yet. The caller hands the request on only after
    /// this.
    public func heard() {
        guard running, state == .connecting, current.channelFailure == nil else { return }
        cancel()
        connected()
    }

    // MARK: - The channel

    /// The master `generation` printed its mark: it is logged in and up.
    /// The probe is asked for, once.
    public func marked(generation: Int) {
        guard isCurrent(generation), !current.marked else { return }
        current.marked = true
        effects.probe(generation)
    }

    /// The probe's answer; `nil` when it could not be run or read. A
    /// socket that answers is another Evlat's: the try ends, nothing
    /// written. A free one — or a dead one the probe cleared — is
    /// forwarded. Anything else (no home, a folder that cannot be made, a
    /// path too long for an address) ends the try as `other`.
    public func probed(generation: Int, channel: Channel?) {
        guard isCurrent(generation) else { return }
        switch channel?.socket {
        case .busy?:
            failChannel(.channelBusy)
        case .free?, .cleared?, .unknown?:
            current.forwardUncertain = channel?.socket == .unknown
            effects.forward(generation, channel!.path)
        case .long?, .unwritable?, .homeless?, nil:
            failChannel(.other)
        }
    }

    /// The forward's answer. Made: connected. Refused: the probe had just
    /// found the socket free, so the server refuses the forwarding — or
    /// another Mac took the socket in between, which the next try's probe
    /// reads as `channelBusy`. After a file the probe could not ask (an old
    /// `curl`), the file itself may be what refused it: `other`, never a
    /// rule the server may not have.
    public func forwarded(generation: Int, made: Bool) {
        guard isCurrent(generation) else { return }
        guard made else { return failChannel(current.forwardUncertain ? .other : .forwardingRefused) }
        cancel()
        connected()
    }

    /// Whether a report is about the running try, still making its channel.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && running && state == .connecting && current.channelFailure == nil
    }

    /// The try ends for `failure`: its master is closed, and the exit that
    /// follows waits on the schedule with this failure, not its own line.
    private func failChannel(_ failure: Failure) {
        current.channelFailure = failure
        cancel()
        effects.terminate()
    }

    private func connected() {
        lastConnectedWithPassword = current.sentPassword
        state = .connected(since: effects.now())
    }

    /// The process `generation` ended; `stderr` is the tail of what it wrote.
    public func exited(generation: Int, stderr: String) {
        guard generation == self.generation, running else { return }
        running = false
        cancel()
        let attempt = current
        current = Attempt()
        let now = effects.now()
        let wasConnected = state.isConnected
        if case .connected(let since) = state, now.timeIntervalSince(since) >= Self.stableAfter {
            failures = 0
        }
        guard enabled, !asleep else {
            state = .stopped
            return
        }
        let failure = attempt.channelFailure ?? Self.classify(stderr: stderr)
        // A password went and the login was refused: not again, whoever
        // sent it. One wrong password is one failed login on the server.
        // Even when the timer had called it connected: a login refused
        // after 15 s (a slow PAM) never was.
        // Unless a second factor came after it: the password may have been
        // right, so it is kept and the user is asked again (`rejected: false`).
        if attempt.sentPassword, failure == .authentication {
            state = .needsUser(rejected: !attempt.askedAfterPassword)
            return
        }
        // A quiet try met a password prompt it could not answer.
        let quietPassword = mode == .quiet && attempt.refusedPassword && !wasConnected
        if quietPassword, effects.hasStoredPassword() || lastConnectedWithPassword {
            state = .needsUser(rejected: false)
            return
        }
        failures += 1
        let wait = Self.delay(afterFailures: failures)
        state = .waiting(retryAt: now.addingTimeInterval(wait),
                         failure: attempt.refusedPassword && !wasConnected ? .passwordNeeded : failure)
        cancelPending = effects.schedule(wait) { [weak self] in
            guard let self, self.enabled, !self.asleep, !self.running else { return }
            self.attempt(.quiet)
        }
    }

    private func attempt(_ mode: Mode) {
        cancel()
        generation += 1
        running = true
        current = Attempt()
        self.mode = mode
        state = .connecting
        let launched = generation
        effects.launch(launched)
        // The launch can have failed and reported its exit already.
        guard running, launched == generation else { return }
        scheduleDeadline()
    }

    /// A try still without its channel `channelDeadline` from now, with no
    /// prompt held, ends as `other`.
    private func scheduleDeadline() {
        cancel()
        let launched = generation
        cancelPending = effects.schedule(channelDeadline) { [weak self] in
            guard let self, self.isCurrent(launched), self.current.heldPrompts == 0 else { return }
            self.failChannel(.other)
        }
    }

    private func halt() {
        cancel()
        if running {
            running = false
            // The exit that follows belongs to a generation nobody waits for.
            generation += 1
            effects.terminate()
        }
        current = Attempt()
        // Waiting for the user outlives a sleep; only `stop` ends it.
        if isWaitingForUser, enabled { return }
        state = .stopped
    }

    private func cancel() {
        cancelPending?()
        cancelPending = nil
    }
}

// MARK: - The probe

extension RemoteTunnel {
    /// The server's end of the channel as the probe found it
    /// (`channelProbe`).
    public struct Channel: Equatable {
        public enum Socket: String, Equatable {
            /// Nothing at the path: the forward may make it.
            case free
            /// A file nothing answered on — a connection's that ended
            /// (`sshd` does not remove it) — taken away.
            case cleared
            /// Something answered: another Evlat's channel. Left alone.
            case busy
            /// A file there, and no `curl` that can ask it: left alone, and
            /// the forward decides.
            case unknown
            /// The path does not fit a unix address.
            case long
            /// The folder could not be made the user's alone.
            case unwritable
            /// No absolute `$HOME` to build the path from.
            case homeless
        }

        /// The `curl` the installed commands need: one that can reach a
        /// socket (`--unix-socket`, 7.40), an older one, or none.
        public enum Curl: String, Equatable {
            case ok, old, none
        }

        public let socket: Socket
        public let curl: Curl
        /// The server's socket, absolute; empty without a home.
        public let path: String

        public init(socket: Socket, curl: Curl, path: String) {
            self.socket = socket
            self.curl = curl
            self.path = path
        }
    }

    /// How long the probe waits for a socket that may answer, in seconds:
    /// past it the socket is a dead connection's: a live Evlat answers
    /// `/health` at once.
    public static let probePatience = 5

    /// Prints `<nonce> channel <socket> <curl> <path>`. POSIX `sh` and
    /// `curl`. It makes `~/.config/evlat/run` the user's alone (`0700`),
    /// asks a socket there for `/health` — an answer within
    /// `probePatience` is another Evlat's, and nothing is touched; a
    /// refusal or silence is a dead one's, and the file goes. Nothing else
    /// is written, no file of its own either.
    static func channelProbe(nonce: String) -> String {
        let folder = (EvlatSocket.relativePath as NSString).deletingLastPathComponent
        let name = (EvlatSocket.relativePath as NSString).lastPathComponent
        return """
        (
        n=\(RemoteSettings.quoted(nonce))
        say() { printf '%s channel %s %s %s\\n' "$n" "$1" "$c" "$p"; exit 0; }
        c=none
        p=
        case $HOME in /*) ;; *) say homeless ;; esac
        d="$HOME"/\(RemoteSettings.quoted(folder))
        p=$d/\(RemoteSettings.quoted(name))
        if command -v curl >/dev/null 2>&1; then
          curl -q -s -m 1 --unix-socket / -o /dev/null http://127.0.0.1/ >/dev/null 2>&1
          if [ $? -eq 2 ]; then c=old; else c=ok; fi
        fi
        mkdir -p "$d" 2>/dev/null && [ -d "$d" ] && [ ! -h "$d" ] && chmod 700 "$d" 2>/dev/null || say unwritable
        [ ${#p} -le \(EvlatSocket.pathLimit) ] || say long
        if [ ! -e "$p" ] && [ ! -h "$p" ]; then say free; fi
        [ "$c" = ok ] || say unknown
        a=$(curl -q -s -m \(probePatience) --noproxy '*' --unix-socket "$p" -o /dev/null -w '%{http_code}' \\
          \(EvlatSocket.Curl.url("/health")) 2>/dev/null)
        case $a in
          ''|000) rm -f "$p" 2>/dev/null; say cleared ;;
          *) say busy ;;
        esac
        )
        """
    }

    /// The probe's line, found behind whatever a login script printed.
    static func channel(output: Data, nonce: String) -> Channel? {
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let words = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            guard words.count >= 4, words[0] == nonce[...], words[1] == "channel",
                  let socket = Channel.Socket(rawValue: String(words[2])),
                  let curl = Channel.Curl(rawValue: String(words[3])) else { continue }
            return Channel(socket: socket, curl: curl, path: words.count == 5 ? String(words[4]) : "")
        }
        return nil
    }
}
