import EvlatApp

// Diagnostics run before any window: `--list` draws nothing, it prints and exits.
// `--capture [SECONDS]` makes it hold the hook port for a bounded window and
// print every event that arrives — the only way a separate process ever sees
// those counters, since the running app keeps them in memory and writes nothing.
//
// `--capture` alone counts as diagnostics too: falling through to the window
// would open the bar instead, and the port would then be held by a GUI that
// prints nothing — the flag would look broken rather than misspelled.
let capture = AppController.captureWindow(CommandLine.arguments)
if CommandLine.arguments.contains("--list") || capture != nil {
    AppController.printSignalsAndExit(capturingFor: capture)
}

// A thin shell: all wiring lives in AppController, because an executable
// target's top-level code cannot run inside a test bundle and the panel's
// configuration has to be testable (PanelConfigTests).
AppController.launch()
