import Foundation
import EvlatCore

/// Group identity is independent of phase, title preference and list position.
/// Folder paths on different machines never identify the same directory.
public struct SessionGroup: Equatable {
    public struct MachineScope: Hashable {
        let id: String?
        let name: String
    }
    public enum Key: Hashable {
        case repository(String)
        case folder(machine: MachineScope?, path: String)
    }
    public let key: Key
    public let title: String
    public let entities: [String]

    /// Receives the existing row order. The first member determines a group's
    /// place, retaining the list's attention order between groups. Singletons
    /// and non-session signals remain ordinary rows.
    public static func groups(_ signals: [Signal], repository: (Signal) -> GitRepository.Identity?) -> [SessionGroup] {
        var order: [Key] = []
        var members: [Key: [String]] = [:]
        var titles: [Key: String] = [:]
        for signal in signals {
            guard signal.kind == .session, let folder = signal.detail, folder.hasPrefix("/") else { continue }
            let key: Key, title: String
            if signal.machine == nil, let repo = repository(signal) {
                key = .repository(repo.key); title = repo.name
            } else {
                let path = (folder as NSString).standardizingPath
                key = .folder(machine: signal.machine.map { MachineScope(id: $0.id, name: $0.name) }, path: path)
                let name = (path as NSString).lastPathComponent
                title = name + (signal.machine.map { " · " + $0.name } ?? "")
            }
            if members[key] == nil { order.append(key); titles[key] = title }
            members[key, default: []].append(signal.entity)
        }
        return order.compactMap { key in
            guard let entities = members[key], entities.count > 1 else { return nil }
            return SessionGroup(key: key, title: titles[key] ?? "", entities: entities)
        }
    }
}
