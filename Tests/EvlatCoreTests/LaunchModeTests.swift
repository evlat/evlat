import XCTest
@testable import EvlatCore

/// `argv` → what the binary becomes. The bar dials every stored machine over
/// `ssh`; `Evlat --help` used to open it. Only no arguments,
/// or what the system adds, may open it.
final class LaunchModeTests: XCTestCase {
    func testOnlyNoArgumentsOrSystemArgumentsOpenTheApp() {
        XCTAssertEqual(LaunchMode.of(["Evlat"]), .app)
        XCTAssertEqual(LaunchMode.of(["Evlat", "-psn_0_12345"]), .app)
        XCTAssertEqual(LaunchMode.of(["Evlat", "-AppleLanguages", "(tr)"]), .app)
        XCTAssertEqual(LaunchMode.of(["Evlat", "-NSDocumentRevisionsDebugMode", "YES", "-psn_0_1"]), .app)
    }

    /// `~/.local/bin/evlat`: a bare `evlat` prints the usage and
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

    // MARK: - Askpass

    private let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let prompt = "nobodyx@127.0.0.1's password: "

    /// `ssh` calls its askpass with the prompt alone in `argv[1]`; only the
    /// mark Evlat puts in the tunnel's environment makes that a helper.
    func testAMarkedEnvironmentIsTheAskpassHelper() {
        let marked = [Askpass.environmentKey: "\(token):/tmp/evlat-t/evlat.sock"]
        let mark = Askpass.Mark(socket: "/tmp/evlat-t/evlat.sock", token: token)
        XCTAssertEqual(LaunchMode.of(["/x/Evlat", prompt], environment: marked), .askpass(mark))
        // Whatever argv says: the mark is read first.
        XCTAssertEqual(LaunchMode.of(["/x/Evlat"], environment: marked), .askpass(mark))
        XCTAssertEqual(LaunchMode.of(["/x/evlat"], environment: marked), .askpass(mark))
        XCTAssertEqual(LaunchMode.of(["/x/Evlat", "--help"], environment: marked), .askpass(mark))
        XCTAssertEqual(LaunchMode.of(["/x/Evlat", "watch", "ls"], environment: marked), .askpass(mark))
    }

    /// A prompt without the mark, or with a broken one, is a stray word: never
    /// the bar, never a helper.
    func testAPromptWithoutAValidMarkIsAUsageError() {
        for environment in [[:], [Askpass.environmentKey: ""], [Askpass.environmentKey: "48151"],
                            [Askpass.environmentKey: "0:\(token)"], [Askpass.environmentKey: "48151:abc"]] {
            XCTAssertEqual(LaunchMode.of(["/x/Evlat", prompt], environment: environment),
                           .usageError("unknown command \(prompt)"), "\(environment)")
            XCTAssertEqual(LaunchMode.of(["/x/Evlat"], environment: environment), .app, "\(environment)")
        }
        XCTAssertEqual(LaunchMode.of(["/x/Evlat", "Password:"]), .usageError("unknown command Password:"))
    }
}
