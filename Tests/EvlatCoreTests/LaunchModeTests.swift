import XCTest
@testable import EvlatCore

/// `argv` → what the binary becomes. The bar dials every stored machine over
/// `ssh`; `Evlat --help` used to open it (`013/phase-5`). Only no arguments,
/// or what the system adds, may open it.
final class LaunchModeTests: XCTestCase {
    func testOnlyNoArgumentsOrSystemArgumentsOpenTheApp() {
        XCTAssertEqual(LaunchMode.of(["Evlat"]), .app)
        XCTAssertEqual(LaunchMode.of(["Evlat", "-psn_0_12345"]), .app)
        XCTAssertEqual(LaunchMode.of(["Evlat", "-AppleLanguages", "(tr)"]), .app)
        XCTAssertEqual(LaunchMode.of(["Evlat", "-NSDocumentRevisionsDebugMode", "YES", "-psn_0_1"]), .app)
    }

    /// `~/.local/bin/evlat` (`014`): a bare `evlat` prints the usage and
    /// exits 2; the bundle's `Evlat` still opens the bar.
    func testTheCommandLinksNameAloneIsAUsageError() {
        XCTAssertEqual(LaunchMode.of(["/x/evlat"]), .usageError("a command is needed"))
        XCTAssertEqual(LaunchMode.of(["evlat"]), .usageError("a command is needed"))
        XCTAssertEqual(LaunchMode.of(["/x/Evlat"]), .app)
        XCTAssertEqual(LaunchMode.of(["/x/Evlat.app/Contents/MacOS/Evlat"]), .app)
        XCTAssertEqual(LaunchMode.of(["/x/evlat", "watch", "ls"]), .command)
        XCTAssertEqual(LaunchMode.of(["/x/evlat", "--help"]), .help)
    }

    func testHelpNeverOpensTheApp() {
        for word in ["--help", "-h", "help"] {
            XCTAssertEqual(LaunchMode.of(["Evlat", word]), .help, word)
            XCTAssertEqual(LaunchMode.of(["Evlat", word, "extra"]), .help, word)
        }
    }

    func testUnknownWordsAreUsageErrorsNotTheApp() {
        let cases: [[String]] = [
            ["Evlat", "--xyz"], ["Evlat", "-x"], ["Evlat", "frobnicate"], ["Evlat", "Watch"],
            ["Evlat", "--version"], ["Evlat", "-AppleLanguages"], ["Evlat", "-psn_0_1", "--help"],
            ["Evlat", "-psn_0_1", "stray"], ["Evlat", ""], ["Evlat", "-psn_0_1 --help"], ["Evlat", "-psn_"],
        ]
        for argv in cases {
            guard case .usageError = LaunchMode.of(argv) else {
                return XCTFail("\(argv) → \(LaunchMode.of(argv))")
            }
        }
        XCTAssertEqual(LaunchMode.of(["Evlat", "--xyz"]), .usageError("unknown option --xyz"))
        XCTAssertEqual(LaunchMode.of(["Evlat", "frobnicate"]), .usageError("unknown command frobnicate"))
    }

    func testCommandsAndDiagnosticsAreReadFromTheFirstArgumentOnly() {
        XCTAssertEqual(LaunchMode.of(["Evlat", "watch", "ls", "--list"]), .command)
        XCTAssertEqual(LaunchMode.of(["Evlat", "signal", "x", "--help"]), .command)
        XCTAssertEqual(LaunchMode.of(["Evlat", "watch"]), .command)
        XCTAssertEqual(LaunchMode.of(["Evlat", "--list"]), .diagnostics)
        XCTAssertEqual(LaunchMode.of(["Evlat", "--capture", "5"]), .diagnostics)
        XCTAssertEqual(LaunchMode.of(["Evlat", "--list", "--capture", "90"]), .diagnostics)
    }

    func testTheUsageNamesEveryWay() {
        for word in ["watch", "signal", "--list", "--capture", "no arguments"] {
            XCTAssertTrue(LaunchMode.usage.contains(word), word)
        }
    }
}
