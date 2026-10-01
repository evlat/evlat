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

    /// `nil` for a target `validate` refuses: an invalid machine cannot be
    /// built, so no later step has to ask again.
    public init?(id: String, target: String) {
        guard Self.validate(target: target) == nil, !id.isEmpty else { return nil }
        self.id = id
        self.target = target
    }

    /// A stored entry is re-validated on the way in: the value came from a
    /// file this process does not own (`UserDefaults`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let target = try container.decode(String.self, forKey: .target)
        guard let machine = RemoteMachine(id: id, target: target) else {
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
    /// list. With `EVLAT_PORT` set and no `EVLAT_MACHINES`, no machine at
    /// all: a process being measured on another port must not open a second
    /// tunnel to the user's servers and race the running Evlat for the remote
    /// 48151.
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
        if let port = environment["EVLAT_PORT"], !port.isEmpty {
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

    // MARK: - Signal keys

    /// The `UserDefaults` key the machines' `/signal` keys live under:
    /// `{machine id: key}`, next to the list. Renaming it loses the stored
    /// keys silently.
    ///
    /// Unlike this Mac's own key (`signal-<port>.token`, new on every
    /// launch), a machine's key is **kept**: a copy of it is on the server,
    /// perhaps pasted there by hand. It is made when the machine is added and
    /// dropped when it is removed; turning it over is removing the machine
    /// and adding it again.
    public static let signalKeysStorageKey = "remote.signalKeys"

    /// What a key looks like: 64 lowercase hex digits (32 random bytes), a
    /// header value that needs no escaping.
    public static func isSignalKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// One key per listed machine: a stored one that still reads as a key is
    /// kept, any other is made with `generate`, and a stored key whose
    /// machine is no longer listed is left out. `stored` is read raw: the
    /// value came from a file this process does not own (`UserDefaults`).
    public static func signalKeys(for machines: [RemoteMachine], stored: [String: Any]?,
                                  generate: () -> String) -> [String: String] {
        var keys: [String: String] = [:]
        for machine in machines {
            if let key = stored?[machine.id] as? String, isSignalKey(key) {
                keys[machine.id] = key
            } else {
                keys[machine.id] = generate()
            }
        }
        return keys
    }
}

/// One machine's tunnel: the `ssh` arguments, the reconnect schedule, what a
/// failure was, and the state machine that ties them together.
///
/// The process is not here. The shell is told to start or stop it
/// (`Effects`) and tells this type what happened (`exited`, `heard`); the
/// clock and the deferred call are injected, so the schedule is tested
/// without waiting on it. **Not thread-safe**: every call on the main queue.
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
    /// - `ExitOnForwardFailure=yes`: a remote 48151 already taken ends the
    ///   process instead of leaving a tunnel that carries nothing.
    /// - `ServerAlive*`: a dead network is noticed in ~45 s.
    /// - `-M -S <controlPath> -o ControlPersist=no`: the process is a master
    ///   connection of **Evlat's own**, so the installs and reads
    ///   (`RemoteSettings.arguments`) ride it instead of logging in again.
    ///   The master is the tunnel itself: it lives exactly as long as this
    ///   process and leaves no background master behind. On the command line
    ///   the three win over a host's `ControlMaster`/`ControlPath`/
    ///   `ControlPersist`, so the user's own master is still never used —
    ///   riding it would make this process's exit say nothing about the
    ///   tunnel. Without a path (none fits, or another process's master
    ///   holds it) `ControlMaster=no`, `ControlPath=none`, as before.
    /// - `RemoteCommand=none`, `StdinNull=no`, `ForkAfterAuthentication=no`:
    ///   a host's `~/.ssh/config` may set them (`RemoteCommand tmux new -A` is
    ///   common); the first refuses a command-line command outright, the other
    ///   two hand `cat` an empty stdin and take the dead man's switch away.
    ///   On the command line they win over the config file.
    /// - `127.0.0.1:` on both ends keeps the remote end on the server's
    ///   loopback (where `GatewayPorts clientspecified` honours it).
    /// - The remote command holds the session open for as long as its stdin
    ///   does, and its stdin is a pipe this Mac's Evlat holds: when Evlat dies,
    ///   `kill -9` included, the pipe reaches EOF, `cat` ends and `ssh` exits —
    ///   no orphan holding the remote port.
    ///
    /// The remote end is `LocalAPI.defaultPort` and never `EVLAT_PORT`: it is
    /// the port the command installed on the server names.
    public static func arguments(target: String, localPort: UInt16, controlPath: String? = nil,
                                 askpass: Bool = false) -> [String] {
        let control = controlPath.map { ["-M", "-S", $0, "-o", "ControlPersist=no"] }
            ?? ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        let prompts = askpass ? ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"] : ["-o", "BatchMode=yes"]
        return ["-T"]
            + prompts
            + ["-o", "ExitOnForwardFailure=yes",
               "-o", "ServerAliveInterval=15",
               "-o", "ServerAliveCountMax=3",
               "-o", "ConnectTimeout=10"]
            + control
            + ["-o", "RemoteCommand=none",
               "-o", "StdinNull=no",
               "-o", "ForkAfterAuthentication=no",
               "-R", "127.0.0.1:\(LocalAPI.defaultPort):127.0.0.1:\(localPort)",
               "--", target, "cat >/dev/null"]
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
    /// expands in a control path; the tunnel then runs without a master.
    public static func controlPath(directory: String, machineID: String) -> String? {
        var trimmed = directory
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, !trimmed.contains("%") else { return nil }
        // FNV-1a, 32 bits: `Hasher` is seeded per process.
        var digest: UInt32 = 0x811c_9dc5
        for byte in machineID.utf8 {
            digest = (digest ^ UInt32(byte)) &* 0x0100_0193
        }
        let path = (trimmed == "/" ? "" : trimmed) + "/" + String(format: "%08x", digest)
        return path.utf8.count <= socketPathLimit ? path : nil
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
        case portBusy
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
    /// says what went wrong.
    private static let failureLines: [(String, Failure)] = [
        ("Host key verification failed", .hostKey),
        ("Could not resolve hostname", .hostName),
        ("remote port forwarding failed", .portBusy),
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
    /// A process still running this long after it started counts as
    /// connected. Past `ConnectTimeout` (10 s) with room for the login and
    /// the forward's answer (`ExitOnForwardFailure`), so a slow host is not
    /// called connected before it is; a request arriving sooner confirms it
    /// at once (`heard`).
    public static let defaultConfirmAfter: TimeInterval = 15

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
    /// generation it was given; `terminate` stops the running one.
    public struct Effects {
        public var launch: (_ generation: Int) -> Void
        public var terminate: () -> Void
        public var now: () -> Date
        /// Runs the closure after the interval; the returned closure cancels it.
        public var schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
        /// Whether a password is stored for the machine (`SSHPasswordStore`).
        public var hasStoredPassword: () -> Bool

        public init(launch: @escaping (Int) -> Void, terminate: @escaping () -> Void,
                    now: @escaping () -> Date,
                    schedule: @escaping (TimeInterval, @escaping () -> Void) -> () -> Void,
                    hasStoredPassword: @escaping () -> Bool = { false }) {
            self.launch = launch
            self.terminate = terminate
            self.now = now
            self.schedule = schedule
            self.hasStoredPassword = hasStoredPassword
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
    }
    private var current = Attempt()

    private let effects: Effects
    private let confirmAfter: TimeInterval
    private var enabled = false
    private var asleep = false
    /// Which launch a report is about. A process terminated for sleep reports
    /// its exit after the next one may already be running; that report must
    /// not touch the new one's state.
    private var generation = 0
    private var running = false
    private var failures = 0
    private var cancelPending: (() -> Void)?

    public init(effects: Effects, confirmAfter: TimeInterval = RemoteTunnel.defaultConfirmAfter) {
        self.effects = effects
        self.confirmAfter = confirmAfter
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
        if current.heldPrompts == 0, state == .connecting { scheduleConfirmation() }
    }

    /// Stop for good: the machine was removed or the app is quitting.
    public func stop() {
        enabled = false
        halt()
    }

    /// The Mac is going to sleep. The process is closed cleanly, so the
    /// server lets go of the remote port at once instead of holding it until
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

    /// A request arrived on this machine's listener. Only the tunnel can
    /// carry one there, so it is connected — without waiting out
    /// `confirmAfter`. The caller hands the request on only after this.
    public func heard() {
        guard running, state == .connecting else { return }
        cancel()
        connected()
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
        let failure = Self.classify(stderr: stderr)
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
        scheduleConfirmation()
    }

    /// A process still running `confirmAfter` from now, with no prompt held,
    /// is connected.
    private func scheduleConfirmation() {
        cancel()
        let launched = generation
        cancelPending = effects.schedule(confirmAfter) { [weak self] in
            guard let self, self.running, launched == self.generation,
                  self.state == .connecting, self.current.heldPrompts == 0 else { return }
            self.connected()
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
