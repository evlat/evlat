import AppKit
import CoreGraphics
import Darwin

/// Whether the user is at a session's tab: the terminal itself says so, for
/// the one pane asked about (`TabLink.focusSince`; today Bateri's `bateri
/// focus [--pid P] bateri://tab/<UUID>`). It only silences news — a sound, a
/// peek, a reminder — and is never taken for "seen": seeing stays the user's
/// own act.
///
/// The answer is one line: `pane=live focused=0|1 idle=N`, `pane=none` or
/// `pane=unknown`, exit `0` with an answer, `3` for unknown, `2` for usage;
/// the program gives itself 900 ms. `focused` is the app active, its window
/// key and that pane focused; `idle` is whole seconds since the pane's last
/// input, on a clock that counts sleep. A locked screen leaves `focused=1`,
/// so the lock is read here (`ScreenLock`). Every answer but a live, focused,
/// recent pane on an unlocked screen is "not at it", and so is every failure:
/// the news is then told as it always was.
///
/// The program run is the running copy's own, and the version gated is that
/// same file's, read from disk at each question (`Bundle(url:)` keeps one per
/// path, and an app put back to an older version would pass a stale gate).
/// A copy older than `focusSince` is never run: Bateri 0.3.0 opened a window
/// for a word it did not know, and from 0.4.0 an argument that starts with
/// `-` still does (measured on 0.5.0), so the arguments are fixed.
enum TabFocus {
    /// What a live pane said.
    struct Reading: Equatable {
        let focused: Bool
        let idle: UInt64
    }

    /// How long after the pane's last input the user still counts as at it.
    /// Not measured: a turn often runs longer than half a minute while the
    /// user watches it, so a short limit would miss the case this is for.
    static let idleLimit: UInt64 = 120

    /// Bateri's own 900 ms, and the process's start.
    static let deadline: TimeInterval = 1.2

    /// The process to run: its program, its fixed arguments, and an
    /// environment of `HOME` alone. The app finds its instances from `HOME`;
    /// nothing else of Evlat's — an inherited `BATERI_*` or an agent's
    /// session markers — is the program's business.
    struct Query: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    // MARK: - The answer

    /// The line, read the way the program's own parser reads it: tokens it
    /// does not know are skipped, since a newer copy says more; `pane=live`
    /// needs both `focused=0|1` and a whole `idle=`. Anything else, a byte
    /// that is not printable ASCII included, is no reading.
    static func parse(_ line: Substring) -> Reading? {
        guard line.utf8.allSatisfy({ $0 == 0x20 || (0x21...0x7E).contains($0) }) else { return nil }
        let tokens = line.split(separator: " ")
        guard tokens.first == "pane=live" else { return nil }
        var focused: Bool?
        var idle: UInt64?
        for token in tokens.dropFirst() {
            if token.hasPrefix("focused=") {
                switch token.dropFirst("focused=".count) {
                case "0": focused = false
                case "1": focused = true
                default: return nil
                }
            } else if token.hasPrefix("idle=") {
                let value = token.dropFirst("idle=".count)
                guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let seconds = UInt64(value) else { return nil }
                idle = seconds
            }
        }
        guard let focused, let idle else { return nil }
        return Reading(focused: focused, idle: idle)
    }

    /// At the pane: focused, touched within `idleLimit`, the screen unlocked.
    static func isAtPane(_ reading: Reading?, locked: Bool) -> Bool {
        guard let reading, !locked else { return false }
        return reading.focused && reading.idle <= idleLimit
    }

    // MARK: - The gate

    /// A version's numbers: `0.4` is `0.4.0`; a part that is not digits, an
    /// empty one or no part at all is no version.
    static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// Whether `version` is `minimum` or newer, part by part; `false` when
    /// either is no version.
    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        guard var have = numbers(version), var need = numbers(minimum) else { return false }
        let width = max(have.count, need.count)
        have += Array(repeating: 0, count: width - have.count)
        need += Array(repeating: 0, count: width - need.count)
        return !have.lexicographicallyPrecedes(need)
    }

    /// The bundle's `CFBundleShortVersionString`, read from its `Info.plist`
    /// on disk now, not from a cached `Bundle`.
    static func version(ofBundle bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// The question for an app's tab, or `nil` when it must not be asked:
    /// an app the table cannot ask, no tab, a tab that is not the app's own
    /// link, no program or bundle, or a copy older than `focusSince`.
    static func query(for app: SessionHost.App, executable: URL?, bundle: URL?, home: String) -> Query? {
        guard let entry = TabLink.of(app.bundleID), let since = entry.focusSince, let tab = app.tab,
              entry.link([Substring(tab.absoluteString)]) == tab,
              let executable, let bundle, let version = version(ofBundle: bundle),
              isAtLeast(version, since), app.pid > 0 else { return nil }
        return Query(executable: executable, arguments: ["focus", "--pid", String(app.pid), tab.absoluteString],
                     environment: ["HOME": home])
    }

    /// The question for a running app, by its pid.
    static func query(for app: SessionHost.App) -> Query? {
        let running = NSRunningApplication(processIdentifier: app.pid)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return query(for: app, executable: running?.executableURL, bundle: running?.bundleURL, home: home)
    }

    // MARK: - Asking

    /// The process, synchronously: its one line, or `nil` for anything but
    /// an answer in time. One still running at `deadline` is killed — it
    /// only reads, so there is nothing to let it finish.
    static func run(_ query: Query, deadline: TimeInterval = deadline) -> Reading? {
        let process = Process()
        process.executableURL = query.executable
        process.arguments = query.arguments
        process.environment = query.environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard done.wait(timeout: .now() + deadline) == .success else {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).first.flatMap(parse)
    }

    /// One queue for every question: a stuck program holds up the next one
    /// for its deadline at most.
    private static let queue = DispatchQueue(label: "evlat.tab-focus")

    /// Asks off the main queue and answers on it, exactly once: whether the
    /// user is at the pane (`isAtPane`), the lock read once the program has
    /// answered. `run` and `locked` are parameters so a test runs neither.
    static func ask(_ query: Query, run: @escaping (Query) -> Reading? = { TabFocus.run($0) },
                    locked: @escaping () -> Bool = { ScreenLock.isLocked },
                    completion: @escaping (Bool) -> Void) {
        queue.async {
            let reading = run(query)
            // The lock only matters for a reading, and is read after it.
            let at = reading != nil && isAtPane(reading, locked: locked())
            DispatchQueue.main.async { completion(at) }
        }
    }
}

/// Whether the screen is locked, from the window server's session
/// dictionary — no permission. Measured (macOS 26.4.1): unlocked, the
/// dictionary has no `CGSSessionScreenIsLocked` at all; locked, it is
/// `true`; unlocked again, gone. So a missing key is unlocked, not
/// unknown. No dictionary, or a value that is not a number, is locked: the
/// news is then told.
enum ScreenLock {
    static let key = "CGSSessionScreenIsLocked"

    static func isLocked(_ session: [String: Any]?) -> Bool {
        guard let session else { return true }
        guard let value = session[key] else { return false }
        return (value as? NSNumber)?.boolValue ?? true
    }

    static var isLocked: Bool {
        isLocked(CGSessionCopyCurrentDictionary() as? [String: Any])
    }
}
