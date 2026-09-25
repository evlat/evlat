import Foundation

/// A fake written into a temporary directory pays macOS's assessment of a
/// new executable on its first run (`syspolicyd`/`XProtect`): measured
/// ~0.2 s against ~0.03 s for the second run of the same file, and several
/// seconds while `XprotectService` was busy — which ran past a tunnel's
/// 0.2 s confirmation and a 5 s wait (`012` kapı, `AGENTS.md` → Tuzaklar).
/// Every fake that feeds a timed wait is run once here, untimed, first.
///
/// The fake answers `--evlat-warm` by exiting at once, before it logs or
/// reads anything, so the warm-up leaves no trace a test counts.
enum FreshExecutable {
    static let warmFlag = "--evlat-warm"

    /// The shell line a fake starts with.
    static let warmLine = "[ \"$1\" = \(warmFlag) ] && exit 0"

    static func warm(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [warmFlag]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
