import Foundation

/// `Evlat signal …` and `Evlat watch …` as arguments (`012/phase-4`): the
/// words, and the bodies they turn into. Pure — nothing here posts, spawns or
/// reads the process: the pid, the folder and the home are handed in, so the
/// shell (`EvlatApp`) owns every side effect and this owns every rule.
///
/// Every body built here is one `SignalReport.parse` accepts
/// (`SignalCommandTests`): the command and the route are two halves of one
/// contract, and the route is the half that is enforced.
public enum SignalCommand {
    /// What the arguments asked for.
    public enum Parsed: Equatable {
        case signal(Post)
        case watch(Watch)
        /// `--help` / `-h` before anything else: the usage, on stdout, exit 0.
        case help
    }

    /// A wrong argument. The message is one line; the caller prints it with
    /// the usage and exits `usageExitCode`.
    public struct UsageError: Error, Equatable {
        public let message: String
    }

    /// The shell convention for a usage error (`EX_USAGE` is 64; 2 is what
    /// `sh`, `grep` and `ls` say, and what a script tests for).
    public static let usageExitCode: Int32 = 2

    /// A watched command's row lives three heartbeats' worth of a missed
    /// minute: a wrapper killed with `-9` takes its row away within three
    /// minutes, and an Evlat that restarts has it back within one.
    public static let watchTTL = 180
    /// How often `watch` sends its row again.
    public static let heartbeat: TimeInterval = 60
    /// `signal`'s default lifetimes: a live row is expected to be refreshed
    /// by whoever sent it; a finished one is read and goes.
    public static let liveTTL = 900
    public static let finishedTTL = 600

    public static let usage = """
        usage: Evlat watch [--label TEXT] [--sender TEXT] [--] COMMAND [ARG…]
               Evlat signal ID [--label TEXT] [--progress 0…1] [--detail TEXT]
                               [--sender TEXT] [--ttl SECONDS]
                               [--waiting | --done | --failed | --clear]

        watch   runs COMMAND as it is (terminal, colours, input, exit code) and
                shows it on the bar while it runs. Evlat's flags go before it.
        signal  sets or clears one row. The default is working; a live row
                lasts 900 s, a finished one 600 s, unless --ttl says otherwise.

        Neither prints anything when Evlat is not running.
        """

    /// The subcommand, read from `argv[1]` **only**: a later `watch` or
    /// `--capture` is some other program's word.
    public static func subcommand(_ argv: [String]) -> String? {
        guard argv.count > 1, ["watch", "signal"].contains(argv[1]) else { return nil }
        return argv[1]
    }

    /// `arguments` starts with the subcommand (`argv` without `argv[0]`).
    public static func parse(_ arguments: [String]) -> Result<Parsed, UsageError> {
        guard let word = arguments.first else { return .failure(UsageError(message: "no subcommand")) }
        let rest = Array(arguments.dropFirst())
        switch word {
        case "watch": return parseWatch(rest)
        case "signal": return parseSignal(rest)
        default: return .failure(UsageError(message: "unknown subcommand \(word)"))
        }
    }

    // MARK: - The body

    /// One POST: the whole row (`SignalReport` is stateless full replacement).
    public struct Post: Equatable {
        public let id: String
        /// `nil` only for a removal (`ttl == 0`).
        public let word: SignalReport.Word?
        public let ttl: Int
        public let label: String?
        public let progress: Double?
        public let detail: String?
        public let sender: String?

        public init(id: String, word: SignalReport.Word?, ttl: Int, label: String? = nil,
                    progress: Double? = nil, detail: String? = nil, sender: String? = nil) {
            self.id = id
            self.word = word
            self.ttl = ttl
            self.label = label
            self.progress = progress
            self.detail = detail
            self.sender = sender
        }

        /// The JSON body. Absent fields are left out, not sent as `null`.
        public var body: Data {
            var json: [String: Any] = ["id": id, "ttl": ttl]
            if let word { json["phase"] = word.rawValue }
            if let label { json["label"] = label }
            if let progress { json["progress"] = progress }
            if let detail { json["detail"] = detail }
            if let sender { json["sender"] = sender }
            return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        }
    }

    // MARK: - watch

    /// `watch [--label …] [--sender …] [--] <command…>`.
    public struct Watch: Equatable {
        public let label: String?
        public let sender: String?
        /// Never empty.
        public let command: [String]

        /// Where the command is.
        public enum State: Equatable {
            case running
            case exited(Int32)
            case signaled(Int32)
        }

        /// The row for `state`. The id is the wrapper's pid: two watches in
        /// two terminals are two rows, and a wrapper started again is a new one.
        public func post(_ state: State, pid: Int32, directory: String, home: String) -> Post {
            let folder = SignalCommand.abbreviate(directory, home: home)
            let word: SignalReport.Word
            let detail: String
            switch state {
            case .running:
                word = .working
                detail = folder
            case .exited(0):
                word = .done
                detail = folder
            case .exited(let code):
                word = .failed
                detail = "exit \(code) · \(folder)"
            case .signaled(let number):
                word = .failed
                detail = "signal \(number) · \(folder)"
            }
            return Post(id: "watch-\(pid)", word: word,
                        ttl: state == .running ? SignalCommand.watchTTL : SignalCommand.finishedTTL,
                        label: label ?? SignalCommand.shorten(command.joined(separator: " ")),
                        detail: detail,
                        sender: sender ?? (command[0] as NSString).lastPathComponent)
        }
    }

    private static func parseWatch(_ arguments: [String]) -> Result<Parsed, UsageError> {
        var label: String?
        var sender: String?
        var index = 0
        // Evlat's flags only before the command: the first word that is not
        // one of them starts the command, and nothing after it is read here.
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--":
                index += 1
                return finishWatch(Array(arguments[index...]), label: label, sender: sender)
            case "-h", "--help":
                return .success(.help)
            case "--label", "--sender":
                guard index + 1 < arguments.count else {
                    return .failure(UsageError(message: "\(argument) needs a value"))
                }
                if argument == "--label" { label = arguments[index + 1] } else { sender = arguments[index + 1] }
                index += 2
            default:
                if argument.hasPrefix("-") {
                    return .failure(UsageError(message: "unknown flag \(argument) (use -- before a command that starts with -)"))
                }
                return finishWatch(Array(arguments[index...]), label: label, sender: sender)
            }
        }
        return finishWatch([], label: label, sender: sender)
    }

    private static func finishWatch(_ command: [String], label: String?, sender: String?) -> Result<Parsed, UsageError> {
        guard let first = command.first, !first.isEmpty else {
            return .failure(UsageError(message: "no command to watch"))
        }
        return .success(.watch(Watch(label: label, sender: sender, command: command)))
    }

    // MARK: - signal

    private static func parseSignal(_ arguments: [String]) -> Result<Parsed, UsageError> {
        var id: String?
        var word: SignalReport.Word?
        var clear = false
        var ttl: Int?
        var label: String?
        var progress: Double?
        var detail: String?
        var sender: String?
        var index = 0
        func value(_ flag: String) -> Result<String, UsageError> {
            guard index + 1 < arguments.count else { return .failure(UsageError(message: "\(flag) needs a value")) }
            index += 1
            return .success(arguments[index])
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return .success(.help)
            case "--waiting", "--done", "--failed", "--clear":
                guard word == nil, !clear else { return .failure(UsageError(message: "one of --waiting, --done, --failed, --clear")) }
                switch argument {
                case "--waiting": word = .waiting
                case "--done": word = .done
                case "--failed": word = .failed
                default: clear = true
                }
            case "--label", "--detail", "--sender":
                switch value(argument) {
                case .failure(let error): return .failure(error)
                case .success(let text):
                    switch argument {
                    case "--label": label = text
                    case "--detail": detail = text
                    default: sender = text
                    }
                }
            case "--progress":
                switch value(argument) {
                case .failure(let error): return .failure(error)
                case .success(let text):
                    guard let number = Double(text), number.isFinite, (0...1).contains(number) else {
                        return .failure(UsageError(message: "--progress must be a number from 0 to 1"))
                    }
                    progress = number
                }
            case "--ttl":
                switch value(argument) {
                case .failure(let error): return .failure(error)
                case .success(let text):
                    guard let seconds = Int(text), (0...SignalReport.ttlLimit).contains(seconds) else {
                        return .failure(UsageError(message: "--ttl must be whole seconds from 0 to \(SignalReport.ttlLimit)"))
                    }
                    ttl = seconds
                }
            default:
                if argument.hasPrefix("-") { return .failure(UsageError(message: "unknown flag \(argument)")) }
                guard id == nil else { return .failure(UsageError(message: "one id only (got \(id!) and \(argument))")) }
                guard SignalReport.isValid(id: argument) else {
                    return .failure(UsageError(message: "id must match [A-Za-z0-9._-]{1,64}"))
                }
                id = argument
            }
            index += 1
        }
        guard let id else { return .failure(UsageError(message: "no id")) }
        if clear {
            // A removal says nothing else (`SignalReport.parse` reads no
            // other field of it); a flag given with it is a mistake, not a hint.
            guard label == nil, progress == nil, detail == nil, sender == nil, ttl == nil else {
                return .failure(UsageError(message: "--clear takes no other flag"))
            }
            return .success(.signal(Post(id: id, word: nil, ttl: 0)))
        }
        let spoken = word ?? .working
        let finished = spoken == .done || spoken == .failed
        return .success(.signal(Post(id: id, word: spoken, ttl: ttl ?? (finished ? finishedTTL : liveTTL),
                                     label: label, progress: progress, detail: detail, sender: sender)))
    }

    // MARK: - Text

    /// The command line cut to what the row holds, with an ellipsis so a cut
    /// is seen as one.
    static func shorten(_ text: String) -> String {
        let limit = SignalReport.labelLimit
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// `~` for the home, as a shell prompt says it.
    static func abbreviate(_ directory: String, home: String) -> String {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return directory }
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }
}
