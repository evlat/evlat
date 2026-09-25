import Foundation
import EvlatCore

/// `Evlat watch <command…>` (`012/phase-4`): runs the command **as it is**
/// and keeps a row on the bar while it runs.
///
/// Transparent is the whole promise. The child inherits the wrapper's stdin,
/// stdout and stderr (no file actions: a terminal stays a terminal, so
/// colours, prompts and job control are the command's own), its exit code is
/// returned unchanged, and a child killed by a signal kills the wrapper with
/// the same signal — a shell loop around `Evlat watch` stops on Ctrl-C as it
/// would around the command. Evlat itself writes nothing to any of the three
/// streams: not when it is closed, not when it refuses.
///
/// The row is `working` with a 180 s lifetime, sent again every 60 s (the
/// heartbeat): a wrapper killed with `-9` loses its row within three minutes,
/// and an Evlat that restarts has it back within one.
enum Watch {
    /// The signals the wrapper takes over to pass on. `SIGQUIT` is here too:
    /// its default would kill the wrapper before it could say `failed`; so
    /// are the ones a supervisor sends and whose default also kills
    /// (`SIGUSR1`, `SIGUSR2`, `SIGALRM`, `012` kapı) — else the wrapper would
    /// die, the child run on unwatched and its exit code be lost.
    static let forwarded: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGALRM]

    /// Signals whose default action dumps core. Raising one of those on the
    /// wrapper would file a crash report **for Evlat**; the exit code says it
    /// instead (the shell's `128 + n`).
    static let coreDumping: Set<Int32> = [SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGEMT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS]

    static func run(_ watch: SignalCommand.Watch) -> Never {
        // Taken over before the child exists, so no signal falls between the
        // spawn and the handler. A signal the wrapper was started with
        // *ignored* (`nohup`, a background job of a non-interactive shell) is
        // left alone: the child inherits the ignore, as it would unwrapped.
        let taken = forwarded.filter { !isIgnored($0) }
        taken.forEach { signal($0, SIG_IGN) }

        let child: pid_t
        switch spawn(watch.command, resetting: taken) {
        case .success(let pid):
            child = pid
        case .failure(let failure):
            let code = failure.code
            // The shell's words and codes for a command that never ran; no row
            // was ever shown, so none is sent.
            let reason = code == ENOENT ? "command not found" : String(cString: strerror(code))
            FileHandle.standardError.write(Data("Evlat: \(watch.command[0]): \(reason)\n".utf8))
            exit(code == ENOENT ? 127 : 126)
        }

        let pid = getpid()
        let directory = FileManager.default.currentDirectoryPath
        let home = NSHomeDirectory()
        // One serial queue for every post: the final `done` can never be
        // overtaken by a heartbeat's `working`. Refusals are not printed
        // (the command's output is not mixed with Evlat's).
        let posts = DispatchQueue(label: "evlat.watch.post")
        let running = watch.post(.running, pid: pid, directory: directory, home: home)
        // After the spawn: an Evlat that hangs must not delay the command.
        posts.async { _ = SignalClient.post(running) }
        let heartbeat = DispatchSource.makeTimerSource(queue: posts)
        heartbeat.schedule(deadline: .now() + SignalCommand.heartbeat, repeating: SignalCommand.heartbeat)
        heartbeat.setEventHandler { _ = SignalClient.post(running) }
        heartbeat.resume()

        let signals = DispatchQueue(label: "evlat.watch.signals")
        let sources = taken.map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: signals)
            source.setEventHandler {
                if shouldForward(number) { kill(child, number) }
            }
            source.resume()
            return source
        }

        let state = wait(for: child)
        sources.forEach { $0.cancel() }
        posts.sync { heartbeat.cancel() }
        let finished = watch.post(state, pid: pid, directory: directory, home: home)
        posts.sync { _ = SignalClient.post(finished) }

        switch state {
        case .exited(let code):
            exit(code)
        case .signaled(let number):
            if !coreDumping.contains(number) {
                signal(number, SIG_DFL)
                var set = sigset_t()
                sigemptyset(&set)
                sigaddset(&set, number)
                sigprocmask(SIG_UNBLOCK, &set, nil)
                kill(getpid(), number)
            }
            exit(128 + number)
        case .running:
            exit(1)   // `wait(for:)` never returns it
        }
    }

    /// A terminal's Ctrl-C (and Ctrl-\) goes to the whole foreground process
    /// group, the child included: passing it on would hand the child a second
    /// one, and "press Ctrl-C again to quit" programs would quit on the first.
    /// So they are passed on only when the wrapper is **not** in its
    /// terminal's foreground group — `kill -INT` from a script, a background
    /// job, no terminal at all. The price: `kill -INT <wrapper>` from another
    /// terminal while the watch runs in the foreground is not passed on.
    /// `SIGTERM` and `SIGHUP` are always passed on.
    static func shouldForward(_ number: Int32) -> Bool {
        guard number == SIGINT || number == SIGQUIT else { return true }
        return !inTerminalForeground()
    }

    static func inTerminalForeground() -> Bool {
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where isatty(descriptor) == 1 {
            return tcgetpgrp(descriptor) == getpgrp()
        }
        return false
    }

    private static func isIgnored(_ number: Int32) -> Bool {
        var current = sigaction()
        guard sigaction(number, nil, &current) == 0 else { return false }
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    /// `posix_spawnp`: `PATH` is searched as a shell would. The dispositions
    /// the wrapper took over go back to default in the child — otherwise it
    /// would inherit `SIG_IGN` and a Ctrl-C would never reach it — and the
    /// mask is emptied.
    private static func spawn(_ command: [String], resetting taken: [Int32]) -> Result<pid_t, SpawnError> {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        taken.forEach { sigaddset(&defaults, $0) }
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawnp(&pid, command[0], nil, &attributes, arguments, environ)
        return result == 0 ? .success(pid) : .failure(SpawnError(code: result))
    }

    struct SpawnError: Error {
        let code: Int32
    }

    /// Blocks until the child ends. The taken signals are ignored at the
    /// process level (their sources still see them), so `waitpid` is not
    /// interrupted by them; `EINTR` is looped on anyway.
    private static func wait(for child: pid_t) -> SignalCommand.Watch.State {
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 {
            if errno != EINTR { return .exited(1) }
        }
        let low = status & 0x7f
        return low == 0 ? .exited((status >> 8) & 0xff) : .signaled(low)
    }
}
