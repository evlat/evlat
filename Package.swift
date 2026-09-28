// swift-tools-version:5.9
import PackageDescription

// Three targets, two layers. `EvlatCore` and `EvlatApp` are the two layers of
// `AGENTS.md` → Architecture; `Evlat` is a thin shell carrying only
// main.swift. The shell is separate for testing: an executable target's
// top-level code gets in the way of its own tests, and the panel's
// configuration (PanelConfigTests) has to be testable in code.
//
// Layer direction is closed BY THE COMPILER: EvlatCore depends on nothing, so
// `import EvlatApp` is impossible. The import test only adds a tripwire on top
// (Tests/EvlatCoreTests/ImportPurityTests.swift).
//
// Sparkle is the only dependency: the shell's updater (`Updater.swift`). The
// core never sees it.
let package = Package(
    name: "Evlat",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "EvlatCore", path: "Sources/EvlatCore"),
        .target(name: "EvlatApp",
                dependencies: ["EvlatCore", .product(name: "Sparkle", package: "Sparkle")],
                path: "Sources/EvlatApp"),
        .executableTarget(name: "Evlat", dependencies: ["EvlatApp", "EvlatCore"], path: "Sources/Evlat"),
        .testTarget(name: "EvlatCoreTests", dependencies: ["EvlatCore"], path: "Tests/EvlatCoreTests"),
        .testTarget(name: "EvlatAppTests", dependencies: ["EvlatApp"], path: "Tests/EvlatAppTests"),
    ],
    swiftLanguageVersions: [.v5]
)
