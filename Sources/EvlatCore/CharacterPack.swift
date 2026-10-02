import Foundation

/// A character someone made and shared: a folder with `character.json` and
/// its images, installed under `Application Support/Evlat/Characters`. What
/// CESP packs are for sounds (`SoundPack`), this is for the mascot: Evlat
/// ships the format and the loader, and characters live outside it, each
/// under its own author's license.
///
/// A pack is **data, never code**: a body image, and optionally where the
/// mascot's animated eyes go and a face layer that takes the status colour.
/// Everything is drawn by `PackBody` from the same `MascotPose` every
/// character uses.
///
/// ```json
/// {
///   "evlat_character": 1,
///   "name": "heart-cube",
///   "display_name": "Heart Cube",
///   "version": "1.0.0",
///   "author": "Someone",
///   "license": "CC-BY-4.0",
///   "inspired_by": "Optional credit",
///   "body": "body.png",
///   "eyes": [{"cx": 0.38, "cy": 0.5, "length": 0.14, "width": 0.05, "tilt": 0},
///            {"cx": 0.62, "cy": 0.5, "length": 0.14, "width": 0.05, "tilt": 0}],
///   "face": {"image": "heart.png", "cx": 0.5, "cy": 0.5, "size": 0.3, "tint": "status"},
///   "sound_pack": "a-cesp-pack-name"
/// }
/// ```
public struct CharacterPack: Equatable {
    public struct Face: Equatable {
        public let image: URL
        public let cx: Double
        public let cy: Double
        /// Its side, as a share of the character's.
        public let size: Double
        /// Coloured by the sessions' status (the image is a mask), or drawn
        /// as it is.
        public let tintsByStatus: Bool
    }

    public let name: String
    public let displayName: String
    public let version: String
    public let author: String
    public let license: String
    public let inspiredBy: String?
    public let directory: URL
    public let body: URL
    /// None, or exactly two: the mascot's own capsule eyes, placed here.
    public let eyes: [EyeFinder.Eye]
    public let face: Face?
    /// A CESP pack this character goes with, used when it is installed.
    public let soundPack: String?

    public static let manifestName = "character.json"
    public static let formatVersion = 1
    /// Per image; the mascot is drawn at 34 pt, so this is generous.
    static let maxImageBytes = 2 * 1_048_576
    static let imagePattern = #"^[A-Za-z0-9._-]+\.png$"#

    public static func read(directory: URL, fileSize: (URL) -> Int? = SoundPack.fileSize) -> CharacterPack? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json, directory: directory, fileSize: fileSize)
    }

    public enum Rejection: Error, Equatable {
        case notACharacter, badName, missingBody, badEyes, badFace
    }

    public static func parse(_ json: [String: Any], directory: URL,
                             fileSize: (URL) -> Int?) -> CharacterPack? {
        try? validate(json, directory: directory, fileSize: fileSize).get()
    }

    /// Why a manifest is not a usable pack — for the import's message.
    public static func validate(_ json: [String: Any], directory: URL,
                                fileSize: (URL) -> Int?) -> Result<CharacterPack, Rejection> {
        guard json["evlat_character"] as? Int == formatVersion else { return .failure(.notACharacter) }
        guard let name = json["name"] as? String,
              name.range(of: SoundPack.namePattern, options: .regularExpression) != nil else { return .failure(.badName) }
        func image(_ value: Any?) -> URL? {
            guard let file = value as? String, file.range(of: imagePattern, options: .regularExpression) != nil else { return nil }
            let url = directory.appendingPathComponent(file)
            guard let bytes = fileSize(url), bytes > 0, bytes <= maxImageBytes else { return nil }
            return url
        }
        guard let body = image(json["body"]) else { return .failure(.missingBody) }
        var eyes: [EyeFinder.Eye] = []
        if let list = json["eyes"] {
            guard let items = list as? [[String: Any]], items.count == 2 else { return .failure(.badEyes) }
            for item in items {
                guard let eye = Self.eye(item) else { return .failure(.badEyes) }
                eyes.append(eye)
            }
        }
        var face: Face?
        if let value = json["face"] {
            guard let item = value as? [String: Any], let url = image(item["image"]),
                  let cx = unit(item["cx"]), let cy = unit(item["cy"]),
                  let size = unit(item["size"]), size > 0 else { return .failure(.badFace) }
            face = Face(image: url, cx: cx, cy: cy, size: size, tintsByStatus: item["tint"] as? String == "status")
        }
        let text = { (key: String) -> String? in
            (json[key] as? String).map { String($0.prefix(200)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return .success(CharacterPack(
            name: name, displayName: text("display_name") ?? name, version: text("version") ?? "",
            author: text("author") ?? "", license: text("license") ?? "", inspiredBy: text("inspired_by"),
            directory: directory, body: body, eyes: eyes, face: face,
            soundPack: (json["sound_pack"] as? String).flatMap {
                $0.range(of: SoundPack.namePattern, options: .regularExpression) != nil ? $0 : nil
            }))
    }

    /// A number in 0…1.
    static func unit(_ value: Any?) -> Double? {
        guard let n = UsageReport.number(value), (0...1).contains(n) else { return nil }
        return n
    }

    static func eye(_ json: [String: Any]) -> EyeFinder.Eye? {
        guard let cx = unit(json["cx"]), let cy = unit(json["cy"]),
              let length = unit(json["length"]), let width = unit(json["width"]), length > 0, width > 0 else { return nil }
        let tilt = UsageReport.number(json["tilt"]) ?? 0
        guard (-90...90).contains(tilt) else { return nil }
        return EyeFinder.Eye(cx: cx, cy: cy, length: length, width: width, tilt: tilt)
    }

    /// Every readable pack under `root`, by display name.
    public static func installed(in root: URL) -> [CharacterPack] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { read(directory: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The manifest for a pack made from `eyes` and a body, as `Export` writes it.
    public static func manifest(name: String, displayName: String, author: String, license: String,
                                eyes: [EyeFinder.Eye]) -> [String: Any] {
        var json: [String: Any] = ["evlat_character": formatVersion, "name": name, "display_name": displayName,
                                   "version": "1.0.0", "body": "body.png"]
        if !author.isEmpty { json["author"] = author }
        if !license.isEmpty { json["license"] = license }
        if eyes.count == 2 {
            json["eyes"] = eyes.map { ["cx": $0.cx, "cy": $0.cy, "length": $0.length, "width": $0.width, "tilt": $0.tilt] }
        }
        return json
    }
}
