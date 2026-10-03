import Foundation
import EvlatCore

/// A Docker sandbox's session's terminal on this Mac: the `sbx run` client
/// the user started it from. The sandbox runs under `sbx`'s daemon, parented
/// to launchd, and its agent has no pid here; the client is an ordinary
/// process in the terminal's tab (`sbx → -zsh → login → Bateri`, measured on
/// sbx 0.46.0), not Apple-signed, so its environment names its tab.
///
/// Every `sbx run` to a sandbox opens a new agent session there (measured:
/// three clients, three Claude sessions), and a session outlives its client.
/// So a sandbox's clients are the candidates and the session's start tells
/// them apart — the same rules as a remote `ssh` (`StartMatch`), with this
/// side's thresholds:
///  - a client that started **after** the session began is another one's;
///  - with the session's start heard, one left: its tab if it started
///    within `aloneWithin` of the session, else the app alone; several: the
///    nearest within `nearest`, every other past `apart` (the session's
///    `SessionStart` arrived 1.4–3.5 s after its client started, measured;
///    creating a sandbox took 14 s, but then it was the only client);
///  - no start heard, a lone one too far, or none told apart: the app alone
///    when every candidate is in one, with no tab; else nothing;
///  - no candidate: no terminal is open for it (`Found.noTerminal`).
///
/// One client is one session's (each `sbx run` starts exactly one agent), so
/// a sandbox's sessions are matched together: those whose start was heard,
/// in order of start, each by the rule above over the clients no earlier
/// one took (`claimed`). Two tabs 3 s apart left the second session with
/// two candidates 5 s and 2 s away, none told apart; the first one's client
/// is the first session's. A session with no start heard claims nothing,
/// and a later session never moves an earlier one's.
/// Nothing is run: the clients are read like any other process
/// (`SessionHost.Probe`).
enum Sandbox {
    /// A lone client far from the session's start may be an earlier
    /// session's, this one's own client gone: the slowest client-to-session
    /// start measured was 14 s (creating a sandbox), with room to spare.
    static let aloneWithin: TimeInterval = 30
    static let rule = StartMatch.Rule(nearest: 5, apart: 10, aloneWithin: aloneWithin)

    enum Found: Equatable {
        /// What the candidates gave, `.notFound` included (several in two
        /// apps, or a row that names no sandbox).
        case host(SessionHost)
        /// No client of that sandbox has a terminal: said on the card.
        case noTerminal
    }

    /// `earlier`: the starts of the same sandbox's other sessions that come
    /// before this one (`earlierStarts`), whose clients are theirs first.
    static func resolve(name: String?, start: Date?, earlier: [Date] = [], _ probe: SessionHost.Probe) -> Found {
        guard let name else { return .host(.notFound) }
        let pids = candidates(named: name, startedBy: start, probe)
        // A client whose sandbox could not be read may be this one's: then
        // "no terminal" would be a guess, and the card says nothing.
        if pids.isEmpty { return unreadClient(startedBy: start, probe) ? .host(.notFound) : .noTerminal }
        // Without the session's start one client could be another
        // session's: the app, never a tab.
        guard let start else { return .host(SessionHost.sameApp(pids, keepsTab: false, probe)) }
        let starts = Dictionary(uniqueKeysWithValues: pids.map { ($0, probe.startedAt($0)) })
        let startedAt = { (pid: Int32) in starts[pid] ?? nil }
        let taken = claimed(pids, by: earlier.filter { $0 <= start }, startedAt: startedAt)
        let free = pids.filter { !taken.contains($0) }
        // Every client is an earlier session's: this one's is gone. Not
        // "no terminal", which would claim more than was told apart.
        if free.isEmpty { return .host(SessionHost.sameApp(pids, keepsTab: false, probe)) }
        switch StartMatch.choose(free, start: start, rule: rule, startedAt: startedAt) {
        case .one(let pid): return .host(SessionHost.resolve(pid: pid, probe))
        case .ambiguous(let pids): return .host(SessionHost.sameApp(pids, keepsTab: false, probe))
        // The candidates are not empty: a lone one too far from the start,
        // which may be the session's or not — the app, never a tab.
        case .none: return .host(SessionHost.sameApp(free, keepsTab: false, probe))
        }
    }

    static func resolve(name: String?, start: Date?, earlier: [Date] = []) -> Found {
        resolve(name: name, start: start, earlier: earlier, SessionHost.live)
    }

    /// The clients the earlier sessions take, in order of start: each by the
    /// rule over its own candidates (none started after it) that no session
    /// before it took. Only a client told apart is taken.
    static func claimed(_ pids: [Int32], by earlier: [Date], startedAt: (Int32) -> Date?) -> Set<Int32> {
        var taken: Set<Int32> = []
        for start in earlier.sorted() {
            let own = pids.filter { pid in
                !taken.contains(pid) && (startedAt(pid).map { $0 <= start } ?? true)
            }
            if case .one(let pid) = StartMatch.choose(own, start: start, rule: rule, startedAt: startedAt) {
                taken.insert(pid)
            }
        }
        return taken
    }

    /// The starts of the sessions of `signal`'s sandbox that come before it
    /// in `signals`: heard, and earlier by start, then by entity, so every
    /// card of the sandbox orders them alike. Empty for a row with no
    /// sandbox or no start, which claims nothing either.
    static func earlierStarts(of signal: Signal, in signals: [Signal]) -> [Date] {
        guard let name = signal.activity?.sandboxName, let start = signal.activity?.sessionStartedAt
        else { return [] }
        return signals.compactMap { other -> Date? in
            guard other.entity != signal.entity, other.kind == .session,
                  other.machine?.id == SandboxListener.identity.id,
                  other.activity?.sandboxName == name,
                  let own = other.activity?.sessionStartedAt,
                  own < start || (own == start && other.entity < signal.entity) else { return nil }
            return own
        }.sorted()
    }

    /// The live `sbx run` clients of the sandbox `name` that have a terminal
    /// and did not start after `start`. A start that cannot be read rules
    /// nobody out.
    static func candidates(named name: String, startedBy start: Date?, _ probe: SessionHost.Probe) -> [Int32] {
        probe.processes().filter { pid in
            guard let path = probe.executablePath(pid), (path as NSString).lastPathComponent == "sbx",
                  probe.hasTerminal(pid) != false,
                  clientName(arguments: probe.arguments(pid), directory: { probe.currentDirectory(pid) }) == name
            else { return false }
            if let start, let own = probe.startedAt(pid), own > start { return false }
            return true
        }.sorted()
    }

    /// Whether a live `sbx run` client with a terminal, not started after
    /// `start`, names no sandbox that can be read (`clientName` is `nil`).
    static func unreadClient(startedBy start: Date?, _ probe: SessionHost.Probe) -> Bool {
        probe.processes().contains { pid in
            guard let path = probe.executablePath(pid), (path as NSString).lastPathComponent == "sbx",
                  probe.hasTerminal(pid) != false else { return false }
            let arguments = probe.arguments(pid)
            guard arguments.dropFirst().contains("run"),
                  clientName(arguments: arguments, directory: { probe.currentDirectory(pid) }) == nil
            else { return false }
            if let start, let own = probe.startedAt(pid), own > start { return false }
            return true
        }
    }

    /// The sandbox an `sbx run` client attaches to: `--name`'s, or with
    /// none, `sbx`'s default `<agent>-<folder>` — the agent word and the
    /// last part of its working directory. `nil` for anything else: another
    /// subcommand, a cloud sandbox, or arguments not read whole (an unknown
    /// option, a kit reference, a workspace path), where a derived name
    /// could be wrong. No client beats a wrong tab.
    static func clientName(arguments: [String], directory: () -> String?) -> String? {
        var rest = arguments.dropFirst()[...]
        // Global options before the subcommand.
        while let word = rest.first, word.hasPrefix("-") {
            guard globalSwitches.contains(word) else { return nil }
            rest = rest.dropFirst()
        }
        guard rest.first == "run" else { return nil }
        rest = rest.dropFirst()
        var name: String?
        var positionals: [String] = []
        var readWhole = true
        while let word = rest.first {
            rest = rest.dropFirst()
            if word == "--" { break }
            if word == "--cloud" { return nil }
            if word == "--name" {
                guard let value = rest.first else { return nil }
                rest = rest.dropFirst()
                name = value
            } else if word.hasPrefix("--name=") {
                name = String(word.dropFirst("--name=".count))
            } else if word.hasPrefix("--") {
                let flag = String(word.dropFirst(2))
                if let equals = flag.firstIndex(of: "=") {
                    if !valueOptions.contains(String(flag[..<equals])) { readWhole = false }
                } else if valueOptions.contains(flag) {
                    rest = rest.dropFirst()
                } else if !switches.contains(flag) {
                    readWhole = false
                }
            } else if word.hasPrefix("-"), word.count >= 2 {
                let letter = word.dropFirst().first!
                if shortValueOptions.contains(letter) {
                    if word.count == 2 { rest = rest.dropFirst() }
                } else if !(word.count == 2 && shortSwitches.contains(letter)) {
                    readWhole = false
                }
            } else {
                positionals.append(word)
            }
        }
        if let name { return name.isEmpty ? nil : name }
        // Unnamed: `<agent>-<workdir>`, the workdir the current one only
        // when no path follows the agent. A kit reference is a path or a
        // registry name, not an agent word.
        guard readWhole, positionals.count == 1, let agent = positionals.first,
              !agent.contains("/"), !agent.contains(":"), !agent.hasPrefix("."),
              let folder = directory().map({ ($0 as NSString).lastPathComponent }),
              !folder.isEmpty, folder != "/" else { return nil }
        // A folder name a hook could never carry (a space, a letter past
        // ASCII) is one `sbx` may have rewritten: not read whole.
        let derived = "\(agent)-\(folder)"
        return HookEvent.isSandboxName(derived) ? derived : nil
    }

    /// `sbx run --help`'s options (sbx 0.46.0): those that take a value,
    /// the switches, and the global ones.
    static let valueOptions: Set<String> = [
        "allow-network", "cpus", "deny-network", "detach-keys", "env", "env-file", "image-ref", "kit",
        "kit-arg", "kit-args-file", "memory", "name", "on-timeout", "platform", "profile", "publish", "pull",
        "skills", "static-mcp", "template", "ttl", "volume",
    ]
    static let switches: Set<String> = ["clone", "detached", "help", "new", "debug"]
    static let shortValueOptions: Set<Character> = ["e", "m", "p", "t", "v"]
    static let shortSwitches: Set<Character> = ["d", "h", "D"]
    static let globalSwitches: Set<String> = ["-D", "--debug"]
}
