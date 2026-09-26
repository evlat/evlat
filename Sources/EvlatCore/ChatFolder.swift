import Foundation

/// Dropped files: which folder a chat runs in, how
/// the files are named in the prompt, and what kind of thing they are — the
/// balloon's suggestions follow the kind.
///
/// Pure path arithmetic: the shell says what is a folder, nothing here
/// touches the disk.
public enum ChatFolder {
    public struct Item: Equatable, Hashable {
        public let path: String
        public let isDirectory: Bool

        public init(path: String, isDirectory: Bool) {
            self.path = ChatFolder.standardized(path)
            self.isDirectory = isDirectory
        }

        public var name: String { (path as NSString).lastPathComponent }
    }

    /// What the balloon suggests for. The class names live here; how a
    /// class reads to the user is the catalog's.
    public enum Kind: String, Equatable {
        case pdf, image, folder, other
    }

    /// The folder a chat with these files runs in; `nil` is its own
    /// workspace (`chats/<id>/`).
    ///
    /// One folder dropped alone is itself. Anything else — files, or a
    /// folder among them — runs in the deepest folder holding all of it.
    /// **Never the home or above it**: a file on the Desktop and one in
    /// Downloads share only the home, and a turn run there reaches
    /// everything the user has. Such a chat gets the workspace and names the
    /// files by their full paths; reaching them goes through the permission
    /// card.
    public static func folder(for items: [Item], home: String) -> String? {
        guard let first = items.first else { return nil }
        let candidate: String
        if items.count == 1, first.isDirectory {
            candidate = first.path
        } else {
            let parents = items.map { components(of: ($0.path as NSString).deletingLastPathComponent) }
            var common = parents[0]
            for parent in parents.dropFirst() {
                common = Array(zip(common, parent).prefix { $0 == $1 }.map(\.0))
            }
            candidate = "/" + common.joined(separator: "/")
        }
        return isHomeOrAbove(candidate, home: home) ? nil : candidate
    }

    /// A file as the prompt names it: relative to the chat's folder when it
    /// is inside, its full path when it is not. The folder itself is `./`.
    public static func attachmentPath(_ path: String, in folder: String) -> String {
        let path = standardized(path), folder = standardized(folder)
        if path == folder { return "./" }
        let prefix = folder == "/" ? folder : folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    public static func kind(of item: Item) -> Kind {
        if item.isDirectory { return .folder }
        let ext = (item.path as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        return .other
    }

    /// The group's one kind, or `nil` when it is mixed (or empty).
    public static func kind(of items: [Item]) -> Kind? {
        let kinds = Set(items.map { kind(of: $0) })
        return kinds.count == 1 ? kinds.first : nil
    }

    /// The short tag on a file's chip: its extension, upper-cased. A folder
    /// and a file without one have none.
    public static func label(of item: Item) -> String? {
        guard !item.isDirectory else { return nil }
        let ext = (item.path as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp",
                                               "tif", "tiff", "bmp"]

    /// Absolute, without empty or `.` components or a trailing slash. Not
    /// `standardizingPath`: that one asks the disk (it drops `/private`
    /// only when the result exists), and this stays pure.
    private static func standardized(_ path: String) -> String {
        "/" + components(of: path).joined(separator: "/")
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    /// The home itself, or one of the folders it is in (the root included).
    private static func isHomeOrAbove(_ path: String, home: String) -> Bool {
        let path = components(of: path), home = components(of: home)
        return path.count <= home.count && Array(home.prefix(path.count)) == path
    }
}
