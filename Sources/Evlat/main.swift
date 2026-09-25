import EvlatApp

// `Evlat watch …` and `Evlat signal …` come first, read from `argv[1]` only
// (`012`): a wrapped command's own `--capture 5` or `--list` is its argument,
// not a request for diagnostics. Neither ever builds the app; both exit here.
CommandMode.runIfAsked(CommandLine.arguments)

// Diagnostics run before any window: `--list` draws nothing, it prints and exits.
// `--capture [SECONDS]` makes it hold the hook port for a bounded window and
// print every event that arrives — the only way a separate process ever sees
// those counters, since the running app keeps them in memory and writes nothing.
//
// `--capture` alone counts as diagnostics too: falling through to the window
// would open the bar instead, and the port would then be held by a GUI that
// prints nothing — the flag would look broken rather than misspelled.
//
// Diagnostics too are asked for by `argv[1]` alone; `--capture`'s number may
// follow anywhere after (`--list --capture 90`).
if AppController.isDiagnostics(CommandLine.arguments) {
    let capture = AppController.captureWindow(CommandLine.arguments)
    AppController.printSignalsAndExit(capturingFor: capture)
}

// A thin shell: all wiring lives in AppController, because an executable
// target's top-level code cannot run inside a test bundle and the panel's
// configuration has to be testable (PanelConfigTests).
AppController.launch()
