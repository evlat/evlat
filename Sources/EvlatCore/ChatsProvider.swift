import Foundation

/// The `evlat` provider (`011`): every chat's row, a `kind: .job` signal in
/// the same registry as the sessions.
///
/// It only holds the chats' state machines; the shell's `ChatStore` writes
/// them as turns run. Providers are pure and live here, never in the app
/// layer (`HookListenerTests.testNoTypeInTheAppLayerIsAProvider`).
///
/// Main queue, like every provider.
public final class ChatsProvider: Provider {
    public static let id = ChatSession.provider
    public var id: String { Self.id }

    public private(set) var chats: [String: ChatSession] = [:]
    /// The clock a row's life is read against (`ChatSession.signal(at:)`):
    /// a finished, unseen chat leaves the bar on its own after 12 h.
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public subscript(id: String) -> ChatSession? {
        get { chats[id] }
        set { chats[id] = newValue }
    }

    /// Claude session ids of every chat: the record provider leaves them
    /// out, since a `claude -p` turn writes a session record too (measured,
    /// `011/phase-1`).
    public var sessionIDs: Set<String> { Set(chats.values.map(\.sessionID)) }

    public func currentSignals() -> [Signal] {
        let now = now()
        return chats.values.compactMap { $0.signal(at: now) }.sorted { $0.entity < $1.entity }
    }
}
