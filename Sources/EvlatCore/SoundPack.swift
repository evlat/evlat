import Foundation

/// A sound pack in the Coding Event Sound Pack Specification (CESP v1.0,
/// `github.com/PeonPing/openpeon`): a directory with an `openpeon.json`
/// that maps event categories to audio files — one character's voice, a
/// few lines for each moment. Evlat ships none; it plays the packs the user
/// installs.
///
/// Packs live where the spec says players should look, `~/.openpeon/packs/`,
/// so a pack installed for another player plays here too. Only what the
/// player needs is read: the name, the display name, and each category's
/// files and labels. A file that breaks the spec's rules — outside the
/// pack, a name with other characters, over 1 MB — is left out; the rest of
/// the pack still plays.
public struct SoundPack: Equatable {
    /// The spec's categories. A pack may fill any subset; Evlat speaks only
    /// the ones its moments map to (`SoundMoment.category` in the shell).
    public enum Category: String, CaseIterable {
        case sessionStart = "session.start"
        case taskAcknowledge = "task.acknowledge"
        case taskComplete = "task.complete"
        case taskError = "task.error"
        case inputRequired = "input.required"
        case resourceLimit = "resource.limit"
        case userSpam = "user.spam"
        case sessionEnd = "session.end"
        case taskProgress = "task.progress"
    }

    public struct Sound: Equatable {
        public let file: URL
        /// What the line says, when the manifest writes it down; otherwise
        /// the file's name (`hasLabel` false).
        public let label: String
        public let hasLabel: Bool

        public init(file: URL, label: String, hasLabel: Bool = true) {
            self.file = file
            self.label = label
            self.hasLabel = hasLabel
        }
    }

    /// `name` in the manifest: the pack's id, and how the setting stores it.
    public let name: String
    public let displayName: String
    public let directory: URL
    public let sounds: [Category: [Sound]]

    public init(name: String, displayName: String, directory: URL, sounds: [Category: [Sound]]) {
        self.name = name
        self.displayName = displayName
        self.directory = directory
        self.sounds = sounds
    }

    /// The spec's limits a player checks itself.
    static let maxFileBytes = 1_048_576
    static let namePattern = #"^[a-z0-9][a-z0-9_-]{0,63}$"#
    static let fileNamePattern = #"^[a-zA-Z0-9._-]+$"#

    /// Reads `openpeon.json` in `directory`; `nil` when there is none, it is
    /// not JSON, or it is not CESP 1.x. `fileSize` is injected so the parser
    /// stays testable without real audio.
    /// `isPlayable` is the platform's say on a file's name: a line the
    /// player cannot decode is left out like one that breaks a rule.
    public static func read(directory: URL,
                            fileSize: (URL) -> Int? = SoundPack.fileSize,
                            isPlayable: (String) -> Bool = { _ in true }) -> SoundPack? {
        let manifest = directory.appendingPathComponent("openpeon.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json, directory: directory, fileSize: fileSize, isPlayable: isPlayable)
    }

    static func parse(_ json: [String: Any], directory: URL,
                      fileSize: (URL) -> Int?, isPlayable: (String) -> Bool = { _ in true }) -> SoundPack? {
        guard let version = json["cesp_version"] as? String, version.hasPrefix("1."),
              let name = json["name"] as? String, name.range(of: namePattern, options: .regularExpression) != nil,
              let categories = json["categories"] as? [String: Any] else { return nil }
        let displayName = (json["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let root = directory.standardizedFileURL.path
        var sounds: [Category: [Sound]] = [:]
        // Legacy names a pack maps to the spec's (section 6).
        var keys: [String: String] = [:]
        for (alias, target) in json["category_aliases"] as? [String: String] ?? [:] { keys[alias] = target }
        for (key, value) in categories {
            guard let category = Category(rawValue: keys[key] ?? key),
                  let list = (value as? [String: Any])?["sounds"] as? [[String: Any]] else { continue }
            let kept = list.compactMap { entry -> Sound? in
                guard let path = entry["file"] as? String, !path.contains(".."), !path.hasPrefix("/"),
                      let last = path.split(separator: "/").last,
                      String(last).range(of: fileNamePattern, options: .regularExpression) != nil,
                      isPlayable(String(last)) else { return nil }
                let url = directory.appendingPathComponent(path).standardizedFileURL
                guard url.path.hasPrefix(root + "/"),
                      let bytes = fileSize(url), bytes > 0, bytes <= maxFileBytes else { return nil }
                let label = (entry["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return Sound(file: url, label: label ?? String(last), hasLabel: label != nil)
            }
            if !kept.isEmpty { sounds[category, default: []] += kept }
        }
        return SoundPack(name: name, displayName: displayName, directory: directory, sounds: sounds)
    }

    public static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// `~/.openpeon/packs`, the spec's global place.
    public static func directory(home: URL) -> URL {
        home.appendingPathComponent(".openpeon/packs", isDirectory: true)
    }

    /// Every readable pack under `root`, by display name.
    public static func installed(in root: URL, isPlayable: (String) -> Bool = { _ in true }) -> [SoundPack] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { read(directory: $0, isPlayable: isPlayable) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

/// Picks a character's line for a moment: at random among its lines, never
/// the same file twice in a row (spec 8.1). Pacing — one sound at a time —
/// is the player's, for every source alike, not this.
public struct SoundPicker {
    private var lastFile: URL?

    public init() {}

    /// `nil`: the pack has no line for it.
    public mutating func pick(_ category: SoundPack.Category, from pack: SoundPack,
                              random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> SoundPack.Sound? {
        guard let sounds = pack.sounds[category], !sounds.isEmpty else { return nil }
        let choices = sounds.count > 1 ? sounds.filter { $0.file != lastFile } : sounds
        let sound = choices[random(choices.count)]
        lastFile = sound.file
        return sound
    }
}
