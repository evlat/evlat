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
