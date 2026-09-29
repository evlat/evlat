import Foundation

/// `[Go to session]` in Ghostty: the session's own terminal, not whichever
/// Ghostty window was last in front.
///
/// Ghostty publishes no link to a tab or window (its shells get no surface
/// id in their environment — checked on 1.3.1), so the one way to a given
/// terminal is its AppleScript dictionary: every `terminal` has a stable
/// `id`, its `working directory` and its title (`name`), and `focus` brings
/// its window forward. That is Apple Events — the one permission Evlat asks
/// for, only here, the first time a Ghostty session is gone to. Refused, or
/// no single terminal matching, the caller brings Ghostty forward as before.
///
/// The terminal is matched by the agent's working directory; two terminals
/// in the same folder are told apart by the session's name in the title, and
/// otherwise not guessed at.
enum GhosttyFocus {
    static let bundleID = "com.mitchellh.ghostty"

    struct Terminal: Equatable {
        let id: String
        let directory: String
        let title: String
    }

    /// Runs an AppleScript with its arguments and answers its output, or
    /// `nil` on any failure (refused, Ghostty gone, the time up). Injected so
    /// the tests send no Apple Event.
    typealias Runner = (_ script: String, _ arguments: [String]) -> String?

    /// Focuses the session's terminal; `true` only when one was focused.
    /// Blocking — the first call waits on macOS's permission prompt — so it
    /// is never called on the main thread.
    static func focus(directory: String, label: String?, run: Runner = runOsascript) -> Bool {
        guard let listed = run(listScript, []),
              let id = pick(parse(listed), directory: directory, label: label) else { return false }
        return run(focusScript, [id]) != nil
    }

    /// The one terminal for the session, or `nil` when none or several fit.
    static func pick(_ terminals: [Terminal], directory: String, label: String?) -> String? {
        let folder = standardized(directory)
        let here = terminals.filter { !$0.directory.isEmpty && standardized($0.directory) == folder }
        if here.count == 1 { return here[0].id }
        guard here.count > 1, let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else {
            return nil
        }
        let named = here.filter { $0.title.localizedCaseInsensitiveContains(label) }
        return named.count == 1 ? named[0].id : nil
    }

    private static func standardized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - The scripts

    /// Record and field separators no title or path carries.
    static let recordSeparator: Character = "\u{1E}"
    static let fieldSeparator: Character = "\u{1F}"

    /// Every terminal as `id␟directory␟title␞`, in three events rather than
    /// three per terminal. Ghostty is addressed by bundle id: a renamed copy
    /// is still found, and no other app named Ghostty is.
    static let listScript = """
    tell application id "\(bundleID)"
        set theIDs to id of every terminal
        set theDirectories to working directory of every terminal
        set theTitles to name of every terminal
    end tell
    set out to ""
    repeat with i from 1 to count of theIDs
        set d to item i of theDirectories
        if d is missing value then set d to ""
        set t to item i of theTitles
        if t is missing value then set t to ""
        set out to out & (item i of theIDs) & (character id 31) & d & (character id 31) & t & (character id 30)
    end repeat
    return out
    """

    /// Focuses the terminal whose id is the first argument. The id is an
    /// argument, never spliced into the script.
    static let focusScript = """
    on run argv
        tell application id "\(bundleID)"
            focus (first terminal whose id is (item 1 of argv))
        end tell
        return "ok"
    end run
    """

    static func parse(_ output: String) -> [Terminal] {
        output.split(separator: recordSeparator).compactMap { record in
            let fields = record.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty else { return nil }
            return Terminal(id: String(fields[0]), directory: String(fields[1]),
                            title: String(fields[2]).trimmingCharacters(in: .newlines))
        }
    }

    // MARK: - The real runner

    /// Long enough for the user to answer the first-time permission prompt,
    /// which the event waits on.
    static let timeout: TimeInterval = 60

    /// `osascript`, the script on stdin: off the main thread and killable,
    /// unlike an in-process `NSAppleScript`. Its Apple Events are attributed
    /// to Evlat (the responsible process), so the prompt names Evlat and uses
    /// its `NSAppleEventsUsageDescription`.
    static func runOsascript(_ script: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        // Read while it runs: a full pipe would otherwise stall it.
        var data = Data()
        let reader = DispatchQueue(label: "evlat.ghostty.read")
        let read = DispatchSemaphore(value: 0)
        reader.async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            done.wait()
        }
        read.wait()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
