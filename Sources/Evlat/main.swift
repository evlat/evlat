import EvlatApp
import EvlatCore
import Foundation

// `argv` picks what this process is, from `argv[1]` (`LaunchMode`) — or, for
// `ssh`'s askpass helper, from the mark in the environment.
// The bar opens only on no arguments or on what the system adds
// (`-psn_…`, `-AppleLanguages …`): it holds the hook port and dials every
// stored machine, so `Evlat --help` or a typo must never reach it.
switch LaunchMode.of(CommandLine.arguments, environment: ProcessInfo.processInfo.environment) {
case .askpass(let mark):
    // Run by a tunnel's `ssh` with the prompt in `argv[1]`: asks the Evlat
    // that started it and prints the answer, or exits non-zero silently.
    AskpassHelper.run(CommandLine.arguments, mark: mark)

case .command:
    // `Evlat watch …` and `Evlat signal …`: a wrapped command's own
    // `--capture 5` or `--list` is its argument, not a request for
    // diagnostics. Neither ever builds the app; both exit inside.
    CommandMode.runIfAsked(CommandLine.arguments)
    exit(SignalCommand.usageExitCode)

case .diagnostics:
    // Diagnostics run before any window: `--list` draws nothing, it prints and
    // exits. `--capture [SECONDS]` makes it hold the hook port for a bounded
    // window and print every event that arrives — the only way a separate
    // process ever sees those counters, since the running app keeps them in
    // memory and writes nothing. `--capture`'s number may follow anywhere
    // after (`--list --capture 90`).
    let capture = AppController.captureWindow(CommandLine.arguments)
    AppController.printSignalsAndExit(capturingFor: capture)

case .help:
    print(LaunchMode.usage)
    exit(0)

case .usageError(let message):
    FileHandle.standardError.write(Data("Evlat: \(message)\n\(LaunchMode.usage)\n".utf8))
    exit(SignalCommand.usageExitCode)

case .app:
    // A thin shell: all wiring lives in AppController, because an executable
    // target's top-level code cannot run inside a test bundle and the panel's
    // configuration has to be testable (PanelConfigTests).
    AppController.launch()
}
