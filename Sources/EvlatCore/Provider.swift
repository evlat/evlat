import Foundation

/// A source of signals. Everything source-specific stays here; the core only
/// ever sees the canonical vocabulary (v1's `AgentSource.canonical` pattern).
///
/// A provider is a **compiled** type; no code is loaded from outside. The way
/// in for third parties is posting signals to the local API (`002`).
public protocol Provider {
    /// Wire identity: `Signal.provider`, and later `/hook/{id}`.
    var id: String { get }
    /// Signals as of now. Called on the main queue.
    func currentSignals() -> [Signal]
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
