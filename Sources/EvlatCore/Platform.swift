import Foundation

/// Platform capabilities the core receives from outside.
///
/// `EvlatCore` never calls Darwin. `sysctl`, `kill` and `open` live on the
/// `EvlatApp` side and arrive here as closures. The reason: on macOS
/// `Foundation` re-exports Darwin, so a rule that says "import Foundation only"
/// does **not** measure portability — v1's `SessionHost.swift` imports nothing
/// but `Foundation`, calls `sysctl`, and would not compile on Linux. The
/// injection pattern is v1's own answer (`SessionStore.resolveHost`).
///
/// Defaults are **pure and safe**: with no real capability bound, the core says
/// "I don't know" instead of guessing.
public struct Platform {
    /// Is a process alive under this pid? Defaults to `false`: when liveness is
    /// unknown a session counts as dead, so no ghost row survives in the list.
    public var isAlive: (Int32) -> Bool

    /// When the process under this pid started. `nil` means no process, or the
    /// value could not be read.
    ///
    /// Liveness alone is not enough: macOS **recycles** pids and session records
    /// stick around for months (this machine still holds files from July). On a
    /// recycled pid an unrelated process is alive and the record would show a
    /// ghost session. Records carry their own start time, so the two can be
    /// compared.
    public var processStartedAt: (Int32) -> Date?

    /// Now. Injected so tests can pin time; a `Date()` call scattered through
    /// the code makes time-dependent rules untestable.
    public var now: () -> Date

    public init(isAlive: @escaping (Int32) -> Bool = { _ in false },
                processStartedAt: @escaping (Int32) -> Date? = { _ in nil },
                now: @escaping () -> Date = Date.init) {
        self.isAlive = isAlive
        self.processStartedAt = processStartedAt
        self.now = now
    }

    /// A platform that knows nothing; the default for tests and compile time.
    public static let unknown = Platform()
}

extension Platform {
    /// Is the process under `pid` still the **same** process it was?
    ///
    /// Two gates: does a process exist at all, and is it the one we mean. The
    /// second gate is the pid-recycling guard described on `processStartedAt`.
    ///
    /// It lives here rather than in a provider because both sources need it and
    /// **neither owns it**. What differs is only where `startedAt` comes from:
    /// a file record hands over the start time it *claims*, while a source that
    /// keeps no record hands over the one it read at *first sight* and so
    /// measures one reading against the next. One comparison, two origins.
    ///
    /// When either side is unknown the process is trusted: dropping a live
    /// session over an unreadable field is worse than the ghost it prevents.
    ///
    /// The default tolerance absorbs second-level resolution and the moment
    /// between a process starting and its record being written — measured
    /// across 21 real records, 0.7–6.3 s. On a recycled pid the gap is days.
    public func sameProcess(pid: Int32, startedAt: Date?, tolerance: TimeInterval = 120) -> Bool {
        guard isAlive(pid) else { return false }
        guard let reference = startedAt, let actual = processStartedAt(pid) else { return true }
        return abs(actual.timeIntervalSince(reference)) < tolerance
    }
}
