import Foundation

/// The OpenPeon registry (`peonping.github.io/registry`): an index of CESP
/// packs, each hosted in its own GitHub repository at a pinned ref. The
/// index stores no audio; a pack is fetched from its repository and checked
/// against the index's checksum of its manifest, and each sound against the
/// manifest's own (`SoundPackInstaller`).
///
/// Pure: reading the index, searching it, and the URLs a pack is fetched
/// from. A URL is built only from names that cannot leave the pack's folder.
public enum SoundRegistry {
    public static let index = URL(string: "https://peonping.github.io/registry/index.json")!

    public struct Entry: Equatable, Identifiable {
        public let name: String
        public let displayName: String
        public let description: String
        public let author: String
        public let license: String
        public let tags: [String]
        public let soundCount: Int
        public let totalBytes: Int
        /// `official`, `verified` or `community`, as the registry says.
        public let trust: String
        public let repository: String
        public let ref: String
        public let path: String
        public let manifestSHA256: String
        public let previews: [String]

        public var id: String { name }
    }

    /// The packs in an index, the unreadable ones left out. Official and
    /// verified first, then by name.
    public static func entries(from data: Data) -> [Entry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packs = json["packs"] as? [[String: Any]] else { return [] }
        let tiers = ["official": 0, "verified": 1]
        return packs.compactMap(entry).sorted {
            let a = tiers[$0.trust] ?? 2, b = tiers[$1.trust] ?? 2
            return a != b ? a < b : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func entry(_ json: [String: Any]) -> Entry? {
        guard let name = json["name"] as? String,
              name.range(of: SoundPack.namePattern, options: .regularExpression) != nil,
              let repository = json["source_repo"] as? String, isRepository(repository),
              let ref = json["source_ref"] as? String, isSegment(ref),
              let path = json["source_path"] as? String, isPath(path),
              let sha = json["manifest_sha256"] as? String, isSHA256(sha) else { return nil }
        let author = (json["author"] as? [String: Any])?["name"] as? String
        return Entry(name: name,
                     displayName: (json["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                     description: json["description"] as? String ?? "",
                     author: author ?? "",
                     license: json["license"] as? String ?? "",
                     tags: json["tags"] as? [String] ?? [],
                     soundCount: json["sound_count"] as? Int ?? 0,
                     totalBytes: json["total_size_bytes"] as? Int ?? 0,
                     trust: json["trust_tier"] as? String ?? "community",
                     repository: repository, ref: ref, path: path, manifestSHA256: sha.lowercased(),
                     previews: previews(json["preview_sounds"]))
    }

    /// The index lists a preview as a file name or as `{file, label}`.
    static func previews(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { item in
            (item as? String) ?? ((item as? [String: Any])?["file"] as? String)
        }.filter(isFileName)
    }

    /// A file of the pack, as GitHub serves it raw. `nil` for a path that
    /// would leave the pack.
    public static func url(of file: String, in entry: Entry) -> URL? {
        guard isPath(file) else { return nil }
        let folder = entry.path.isEmpty || entry.path == "." ? "" : entry.path + "/"
        return URL(string: "https://raw.githubusercontent.com/\(entry.repository)/\(entry.ref)/\(folder)\(file)")
    }

    public static func manifestURL(_ entry: Entry) -> URL? { url(of: "openpeon.json", in: entry) }

    /// A preview sound sits in the manifest's `sounds/` folder by name.
    public static func previewURL(_ entry: Entry) -> URL? {
        entry.previews.first.flatMap { url(of: "sounds/\($0)", in: entry) }
    }

    /// Every word of `query` in the name, display name, description, author
    /// or tags.
    public static func search(_ entries: [Entry], _ query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let text = ([entry.name, entry.displayName, entry.description, entry.author] + entry.tags)
                .joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    // MARK: - Names that stay where they are put

    static func isRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { isSegment(String($0)) }
    }

    static func isSegment(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && text != "." && text != ".."
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Relative, forward slashes, no `..`, each part a plain segment.
    static func isPath(_ text: String) -> Bool {
        if text.isEmpty || text == "." { return true }
        return !text.hasPrefix("/") && text.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { isSegment(String($0)) }
    }

    static func isFileName(_ text: String) -> Bool {
        text.range(of: SoundPack.fileNamePattern, options: .regularExpression) != nil && text != "." && text != ".."
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    /// The files a manifest names, as `SoundPack` would play them: inside
    /// the pack, plain names. With the sha256 the manifest gives, if any.
    /// A file named twice keeps a sum if either naming gives one, so a file
    /// is never fetched unchecked for the order a dictionary happens to keep.
    public static func files(in manifest: [String: Any]) -> [(path: String, sha256: String?)] {
        var paths = Set<String>()
        var sums: [String: String] = [:]
        for value in (manifest["categories"] as? [String: Any] ?? [:]).values {
            for sound in (value as? [String: Any])?["sounds"] as? [[String: Any]] ?? [] {
                guard let path = sound["file"] as? String, isPath(path), !path.isEmpty, path != ".",
                      let last = path.split(separator: "/").last, isFileName(String(last)) else { continue }
                paths.insert(path)
                if let sum = sound["sha256"] as? String, isSHA256(sum), sums[path] == nil {
                    sums[path] = sum.lowercased()
                }
            }
        }
        return paths.sorted().map { ($0, sums[$0]) }
    }

    /// The spec's limit on a whole pack (4.2).
    public static let maxPackBytes = 50 * 1_048_576
}
