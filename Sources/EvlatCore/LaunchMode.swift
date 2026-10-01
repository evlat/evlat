import Foundation

/// What `argv` asks the `Evlat` binary to be. Pure: `main.swift`
/// switches on it and owns every side effect.
///
/// The binary is two things — the bar, and a command-line tool
/// (`watch`, `signal`, `--list`, `--capture`). The bar is the dangerous one to
/// open by mistake: it holds the hook port and dials every stored machine over
/// `ssh`. `Evlat --help` used to fall through to it and open an
/// unisolated second bar. So the
/// app opens only on **no** arguments, or on arguments the system itself adds;
/// every other word is a command, a request for help, or a usage error.
public enum LaunchMode: Equatable {
    /// No arguments, or only launch arguments (`isLaunchArguments`).
    case app
    /// `argv[1]` is `watch` or `signal` (`CommandMode`).
    case command
    /// `argv[1]` is `--list` or `--capture`.
    case diagnostics
    /// `--help`, `-h` or `help` in `argv[1]`: usage on stdout, exit 0.
    case help
    /// Anything else: one line and the usage on stderr, exit 2.
    case usageError(String)
    /// `ssh`'s askpass helper: the environment carries a valid
    /// `EVLAT_ASKPASS` mark (`Askpass`). Read **before** `argv`, which then
    /// holds only the prompt.
    case askpass(Askpass.Mark)

    /// The diagnostics' words, read from `argv[1]` only.
    public static let diagnosticsWords: Set<String> = ["--list", "--capture"]
    static let helpWords: Set<String> = ["--help", "-h", "help"]

    /// The name the command link gives the binary (`~/.local/bin/evlat`).
    /// Called by it with nothing after, the binary prints its usage:
    /// a bare `evlat` in a terminal must not open a second, unisolated bar
    /// that inherits the terminal's Claude markers (`AGENTS.md` → Pitfalls).
    public static let linkName = "evlat"

    /// `environment` is read for the askpass mark only. Without a valid
    /// one, a prompt in `argv[1]` (`user@host's password: `) is an unknown
    /// word like any other: `ssh` must never open the bar by running Evlat.
    public static func of(_ argv: [String], environment: [String: String] = [:]) -> LaunchMode {
        if let mark = Askpass.mark(in: environment) { return .askpass(mark) }
        let arguments = Array(argv.dropFirst())
        guard let first = arguments.first else {
            // Exactly the link's name: the bundle's `Evlat` and `open` keep
            // opening the app.
            let name = argv.first.map { ($0 as NSString).lastPathComponent }
            return name == linkName ? .usageError("a command is needed") : .app
        }
        if SignalCommand.subcommand(argv) != nil { return .command }
        if diagnosticsWords.contains(first) { return .diagnostics }
        if helpWords.contains(first) { return .help }
        if isLaunchArguments(arguments) { return .app }
        return .usageError(first.hasPrefix("-") ? "unknown option \(first)" : "unknown command \(first)")
    }

    /// What the system may hand an app it opens: LaunchServices' `-psn_…`, and
    /// `-NS…`/`-Apple…` defaults pairs (`-AppleLanguages (tr)`, used to look
    /// at the Turkish catalog). Nothing a person types by mistake.
    static func isLaunchArguments(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if isProcessSerialNumber(word) {
                index += 1
            } else if word.hasPrefix("-NS") || word.hasPrefix("-Apple"), index + 1 < arguments.count {
                index += 2
            } else {
                return false
            }
        }
        return true
    }

    /// `-psn_0_12345`: digits and underscores after the prefix, nothing else.
    static func isProcessSerialNumber(_ word: String) -> Bool {
        guard word.hasPrefix("-psn_") else { return false }
        let rest = word.dropFirst(5)
        return !rest.isEmpty && rest.allSatisfy { $0 == "_" || ("0"..."9").contains($0) }
    }

    /// The whole binary's usage: the commands' own, then the diagnostics.
    public static let usage = SignalCommand.usage + """


        Evlat --list [--capture [SECONDS]]
                prints the signals and the hook endpoint, then exits.
        Evlat --capture [SECONDS]
                holds the hook port for SECONDS (default 30) and prints what arrives.
        Evlat   with no arguments opens the bar; `evlat` (the command link) prints this.
        """
}
