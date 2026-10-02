import Foundation

/// A source of signals. Everything source-specific stays here; the core only
/// ever sees the canonical vocabulary (each agent's `HookChannel.canonical`).
///
/// A provider is a **compiled** type; no code is loaded from outside. The way
/// in for third parties is posting signals to the local API.
public protocol Provider {
    /// Wire identity: `Signal.provider`, and later `/hook/{id}`.
    var id: String { get }
    /// Signals as of now. Called on the main queue.
    func currentSignals() -> [Signal]
    /// What `Evlat --list` prints about the provider itself: where it reads,
    /// and the drift that would otherwise look like a quiet, healthy source.
    /// The provider says it; the shell prints it without knowing which
    /// provider spoke.
    var diagnostics: [String] { get }
}

extension Provider {
    public var diagnostics: [String] { [] }
}

/// A provider whose reading is expensive, done at the moment the **caller**
/// chooses rather than on every `currentSignals()`.
///
/// `currentSignals()` is asked every 1.5 s and on every hook event, so it must
/// answer from memory. A provider that has to open a file to know anything
/// does that here instead. The shell calls it when the bar opens, through
/// `Registry.reload()`, without looking at which provider it is: the moment is
/// the shell's decision, what reading means is the provider's.
public protocol Reloadable: AnyObject {
    /// Read the source again. Called on the main queue.
    func reload()
}

/// A provider whose rows can be let go of once they have been seen.
///
/// Optional, like `Reloadable`: the shell hands every provider the same set
/// through `Registry.release(_:)` without knowing which one owns a row, and a
/// provider that keeps no such rows is never asked. What "let go" means is
/// the provider's: a row is dropped only while it is still the finish that
/// was seen — one that has moved on since is someone else's news.
public protocol Releasable: AnyObject {
    /// Drop the rows these finishes name. Called on the main queue.
    func release(_ finishes: Set<Finish>)
}
