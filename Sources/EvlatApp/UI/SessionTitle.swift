import Foundation
import EvlatCore

/// Presentation only: never changes a session's identity, phase, or provider label.
public enum SessionTitle: String, CaseIterable {
    case folder, cli, branch

    public static func stored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .folder
    }

    /// CLI titles are provider labels, when supplied. Missing metadata falls
    /// back to the working folder, then the provider's label. Other kinds
    /// retain their own names (in particular chats and external jobs).
    public func label(for signal: Signal, branch: () -> String?) -> String {
        guard signal.kind == .session else { return signal.label }
        let folder = signal.detail.map { ($0 as NSString).lastPathComponent }
        let fallback = folder.flatMap { $0.isEmpty ? nil : $0 } ?? signal.label
        switch self {
        case .folder: return fallback
        case .cli:
            return signal.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : signal.label
        case .branch: return branch().flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
    }
}
