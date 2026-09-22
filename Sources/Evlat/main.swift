import EvlatApp

// Diagnostics run before any window: `--liste` draws nothing, it prints and exits.
if CommandLine.arguments.contains("--liste") {
    AppController.printSignalsAndExit()
}

// A thin shell: all wiring lives in AppController, because an executable
// target's top-level code cannot run inside a test bundle and the panel's
// configuration has to be testable (PanelConfigTests).
AppController.launch()
