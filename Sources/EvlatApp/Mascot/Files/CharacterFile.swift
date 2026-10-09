import SwiftUI
import EvlatCore

/// A character written as a file: `character.json` in its own folder, the
/// same parts, controls, clips and rules Evlat's characters are written in
/// (`MascotRig`, `MascotClip`, `MascotBehavior`), spelled as JSON.
///
/// It says nothing the Swift could not, and loses nothing the Swift says:
/// `CharacterFileTests` reads Pati and the test lantern back from their
/// files equal to the code. What an `Animation` or a `Color` is in Swift is
/// a choice among the few the code uses — a step moves on the shared
/// spring, eased over seconds, or by a cut; a colour is named, grey, RGB
/// or hex, with an opacity — so a file cannot ask for what no clip in Evlat
/// does. A picture a part draws is a file in the character's folder
/// (`MascotSheet`), never outside it.
///
/// ```json
/// {
///   "version": 1,
///   "name": "Hap",
///   "controls": { "glow": { "lower": 0, "upper": 1, "rest": 0.3 } },
///   "root": { "name": "hap",
///             "bindings": [ { "control": "scaleY", "property": "scaleY", "from": [0, 2] } ],
///             "children": [
///               { "name": "body", "shape": { "capsule": { "minimumHeight": 1 } },
///                 "fill": "#EBEBEB", "size": [0.9, 0.7] },
///               { "eye": { "side": -1, "width": 0.12, "height": 0.26, "gap": 0.16, "gaze": [0.1, 0.07],
///                          "fill": { "name": "black", "opacity": 0.92 } } },
///               { "eye": { "side": 1, "width": 0.12, "height": 0.26, "gap": 0.16, "gaze": [0.1, 0.07],
///                          "fill": { "name": "black", "opacity": 0.92 } } } ] },
///   "states": { "waiting": { "loops": false, "steps": [
///     { "pose": { "from": "waiting", "glow": 1 }, "move": "spring", "hold": 0.6 } ] } },
///   "motions": { "pulse": { "steps": [
///     { "pose": { "from": "waiting", "glow": 0.5 }, "move": 0.15, "hold": 0.3 },
///     { "pose": { "from": "waiting", "glow": 1 }, "move": 0.15, "hold": 0.4 } ] } },
///   "rules": [ { "phase": "waiting", "after": 60, "play": ["pulse"] } ]
/// }
/// ```
///
/// A pose starts from a phase's rest (`"from"`, Evlat's table) or from the
/// neutral pose, and sets fields by name: the standard controls by theirs,
/// the character's own by the names it declared — a name it did not
/// declare is the contract's to refuse (`MascotContract`).
enum CharacterFile {
    static let name = "character.json"
    /// The one version this build reads.
    static let version = 1

    /// Why a file is not a character.
    enum Failure: Error, Hashable {
        /// Not there, too big, or not this format; `at` is where the reading
        /// stopped, as a key path (`root.children.2.shape`), when it is known.
        case unreadable(at: String)
        /// Written for a version this build does not read.
        case newerVersion(Int)
        /// A picture a part names is outside the folder.
        case pictureOutside
        /// A picture a part names is not there, or is not a picture.
        case noPicture(String)
    }

    /// The character in `folder`'s file, as `id`.
    static func character(in folder: URL, id: String) throws -> MascotCharacter {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
              data.count <= 1024 * 1024 else { throw Failure.unreadable(at: "") }
        return try character(from: data, folder: folder, id: id)
    }

    static func character(from data: Data, folder: URL, id: String) throws -> MascotCharacter {
        let file: File
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.mascotFolder] = folder
            file = try decoder.decode(File.self, from: data)
        } catch let failure as Failure {
            throw failure
        } catch let DecodingError.dataCorrupted(context), let DecodingError.keyNotFound(_, context),
                let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            if let failure = context.underlyingError as? Failure { throw failure }
            throw Failure.unreadable(at: context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
                .joined(separator: "."))
        } catch {
            throw Failure.unreadable(at: "")
        }
        guard file.version == version else { throw Failure.newerVersion(file.version) }
        return MascotCharacter(
            id: id,
            rig: MascotRig(root: file.root.part,
                           controls: Dictionary(uniqueKeysWithValues: (file.controls ?? [:]).map {
                               (MascotControl($0.key), $0.value.range)
                           })),
            states: Dictionary(uniqueKeysWithValues: (file.states ?? [:]).map { ($0.key.phase, $0.value.clip) }),
            motions: (file.motions ?? [:]).mapValues(\.clip),
            behavior: MascotBehavior(rules: (file.rules ?? []).map(\.rule)),
            name: file.name)
    }

    // MARK: - The file, as decoded

    struct File: Decodable {
        var version: Int
        var name: String?
        var controls: [String: Range]?
        var root: Part
        var states: [PhaseName: Clip]?
        var motions: [String: Clip]?
        var rules: [Rule]?
    }

    struct Range: Decodable {
        var lower: Double
        var upper: Double
        var rest: Double

        var range: MascotControl.Range { MascotControl.Range(lower, upper, rest: rest) }
    }

    /// A phase by its name, as a dictionary key or a value.
    struct PhaseName: Decodable, Hashable, CodingKeyRepresentable {
        var phase: Phase

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let phase = Phase(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                       debugDescription: "no phase \(raw)")
            }
            self.phase = phase
        }

        var codingKey: CodingKey { Key(stringValue: phase.rawValue) }

        init?<T: CodingKey>(codingKey: T) {
            guard let phase = Phase(rawValue: codingKey.stringValue) else { return nil }
            self.phase = phase
        }
    }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// A part, or Evlat's eye (`MascotPart.eye`) by its measures.
    struct Part: Decodable {
        var part: MascotPart

        private enum Keys: String, CodingKey {
            case eye, name, shape, fill, center, size, pivot, bindings, children
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if c.contains(.eye) {
                let eye = try c.decode(Eye.self, forKey: .eye)
                part = .eye(side: eye.side, y: eye.y ?? 0, width: eye.width, height: eye.height, gap: eye.gap,
                            gaze: (eye.gaze.x, eye.gaze.y), fill: eye.fill.color)
                return
            }
            part = MascotPart(
                name: try c.decode(String.self, forKey: .name),
                shape: try c.decodeIfPresent(Shape.self, forKey: .shape)?.shape,
                fill: try c.decodeIfPresent(Fill.self, forKey: .fill)?.color ?? .clear,
                center: try c.decodeIfPresent(Pair.self, forKey: .center)?.point ?? .zero,
                size: try c.decodeIfPresent(Pair.self, forKey: .size)?.size ?? CGSize(width: 1, height: 1),
                pivot: try c.decodeIfPresent(Pair.self, forKey: .pivot)?.point ?? .zero,
                bindings: try c.decodeIfPresent([Binding].self, forKey: .bindings)?.map(\.binding) ?? [],
                children: try c.decodeIfPresent([Part].self, forKey: .children)?.map(\.part) ?? [])
        }
    }

    struct Eye: Decodable {
        var side: Double
        var y: Double?
        var width: Double
        var height: Double
        var gap: Double
        var gaze: Pair
        var fill: Fill
    }

    /// Two numbers, `[x, y]` or `[width, height]`.
    struct Pair: Decodable {
        var x: Double
        var y: Double

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            x = try c.decode(Double.self)
            y = try c.decode(Double.self)
            guard c.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "more than two numbers")
            }
        }

        var point: CGPoint { CGPoint(x: x, y: y) }
        var size: CGSize { CGSize(width: x, height: y) }
    }

    /// One of the shapes, by name: `{"capsule": {"minimumHeight": 0.35}}`,
    /// `{"roundedRectangle": {"cornerRadius": 0.3}}`,
    /// `{"polygon": {"points": [[0, 0], [1, 0], [0.5, 1]], "cornerRadius": 0.02}}` —
    /// with `"morphs"` to move its points (`MascotMorph`) —
    /// `{"image": "ear.png"}`, or a sheet's cells named by a control:
    /// `{"cells": {"image": "blink.png", "columns": 4, "rows": 1, "by": "lid"}}`.
    struct Shape: Decodable {
        var shape: MascotShape

        private enum Keys: String, CodingKey { case capsule, roundedRectangle, polygon, image, cells }
        private struct Capsule: Decodable { var minimumHeight: Double }
        private struct Rounded: Decodable { var cornerRadius: Double }
        private struct Polygon: Decodable { var points: [Pair]; var cornerRadius: Double; var morphs: [Morph]? }
        /// `{"control": "eyeOpen", "from": [1, 0], "points": [[x, y], …]}`: the
        /// outline at full weight, reached as the control goes from the
        /// first number to the second.
        private struct Morph: Decodable { var control: String; var from: Pair; var points: [Pair] }
        private struct Cells: Decodable { var image: String; var columns: Int; var rows: Int; var by: String }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            guard c.allKeys.count == 1, let key = c.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "one shape"))
            }
            let folder = decoder.userInfo[.mascotFolder] as? URL
            switch key {
            case .capsule:
                shape = .capsule(minimumHeight: try c.decode(Capsule.self, forKey: key).minimumHeight)
            case .roundedRectangle:
                shape = .roundedRectangle(cornerRadius: try c.decode(Rounded.self, forKey: key).cornerRadius)
            case .polygon:
                let polygon = try c.decode(Polygon.self, forKey: key)
                shape = .polygon(points: polygon.points.map(\.point), cornerRadius: polygon.cornerRadius,
                                 morphs: (polygon.morphs ?? []).map {
                                     MascotMorph(MascotControl($0.control), from: ($0.from.x, $0.from.y),
                                                 to: $0.points.map(\.point))
                                 })
            case .image:
                shape = .cells(try CharacterFile.sheet(try c.decode(String.self, forKey: key), columns: 1, rows: 1,
                                                       in: folder), by: nil)
            case .cells:
                let cells = try c.decode(Cells.self, forKey: key)
                guard cells.columns > 0, cells.rows > 0, cells.columns * cells.rows <= 1024 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [key],
                                                            debugDescription: "no grid"))
                }
                shape = .cells(try CharacterFile.sheet(cells.image, columns: cells.columns, rows: cells.rows,
                                                       in: folder), by: MascotControl(cells.by))
            }
        }
    }

    /// A picture in the character's folder, as a sheet.
    static func sheet(_ path: String, columns: Int, rows: Int, in folder: URL?) throws -> MascotSheet {
        guard let folder, let url = try? PetAtlas.pictureURL(path, in: folder) else { throw Failure.pictureOutside }
        guard MascotSheet.pixelSize(of: url) != nil else { throw Failure.noPicture(path) }
        return MascotSheet.sheet(at: url, columns: columns, rows: rows)
    }

    /// A colour: `"#RRGGBB"` or `"#RRGGBBAA"`, or `{"name": "black"}`,
    /// `{"white": 0.92}`, `{"red": 0.96, "green": 0.7, "blue": 0.74}`, any
    /// of them with an `"opacity"`.
    struct Fill: Decodable {
        var color: Color

        private enum Keys: String, CodingKey { case name, white, red, green, blue, opacity }

        init(from decoder: Decoder) throws {
            if let hex = try? decoder.singleValueContainer().decode(String.self) {
                guard let color = Self.hex(hex) else {
                    throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                           debugDescription: "not a colour")
                }
                self.color = color
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            var color: Color
            if let name = try c.decodeIfPresent(String.self, forKey: .name) {
                guard let named = Self.named[name] else {
                    throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "no colour \(name)")
                }
                color = named
            } else if let white = try c.decodeIfPresent(Double.self, forKey: .white) {
                color = Color(white: white)
            } else {
                color = Color(red: try c.decode(Double.self, forKey: .red),
                              green: try c.decode(Double.self, forKey: .green),
                              blue: try c.decode(Double.self, forKey: .blue))
            }
            if let opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) { color = color.opacity(opacity) }
            self.color = color
        }

        static let named: [String: Color] = ["black": .black, "white": .white, "clear": .clear, "gray": .gray,
                                              "red": .red, "orange": .orange, "yellow": .yellow, "green": .green,
                                              "blue": .blue, "pink": .pink, "purple": .purple]

        static func hex(_ text: String) -> Color? {
            guard text.hasPrefix("#"), [7, 9].contains(text.count),
                  let value = UInt64(text.dropFirst(), radix: 16) else { return nil }
            let digits = text.count == 9 ? value : value << 8 | 0xFF
            func channel(_ shift: UInt64) -> Double { Double((digits >> shift) & 0xFF) / 255 }
            let color = Color(red: channel(24), green: channel(16), blue: channel(8))
            return text.count == 9 ? color.opacity(channel(0)) : color
        }
    }

    /// `{"control": "yaw", "property": "offsetX", "from": [-1, 1], "to": [-0.1, 0.1]}`;
    /// `to` left out passes the control through (`MascotBinding.follows`).
    struct Binding: Decodable {
        var binding: MascotBinding

        private enum Keys: String, CodingKey { case control, property, from, to }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let property = try c.decode(String.self, forKey: .property)
            guard let moved = MascotProperty.named[property] else {
                throw DecodingError.dataCorruptedError(forKey: .property, in: c,
                                                       debugDescription: "no property \(property)")
            }
            let from = try c.decode(Pair.self, forKey: .from)
            let to = try c.decodeIfPresent(Pair.self, forKey: .to) ?? from
            binding = MascotBinding(MascotControl(try c.decode(String.self, forKey: .control)), moved,
                                    from: (from.x, from.y), to: (to.x, to.y))
        }
    }

    struct Clip: Decodable {
        var loops: Bool?
        var steps: [Step]

        var clip: MascotClip { MascotClip(steps: steps.map(\.step), loops: loops ?? false) }
    }

    /// `{"pose": {...}, "move": "spring" | "cut" | seconds, "hold": seconds}`.
    struct Step: Decodable {
        var step: MascotClip.Step

        private enum Keys: String, CodingKey { case pose, move, hold }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let pose = try c.decode(Pose.self, forKey: .pose).pose
            let hold = try c.decode(Double.self, forKey: .hold)
            if let seconds = try? c.decode(Double.self, forKey: .move) {
                step = .eased(pose, over: seconds, hold: hold)
                return
            }
            switch try c.decode(String.self, forKey: .move) {
            case "spring": step = .entering(pose, hold: hold)
            case "cut": step = .cut(pose, hold: hold)
            default:
                throw DecodingError.dataCorruptedError(forKey: .move, in: c,
                                                       debugDescription: "spring, cut or seconds")
            }
        }
    }

    /// `{"from": "waiting", "eyeOpen": 1.3, "glow": 1}`: a phase's rest, or
    /// the neutral pose, with fields set by name.
    struct Pose: Decodable {
        var pose: MascotPose

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            var pose = MascotPose()
            if c.contains(Key(stringValue: "from")) {
                pose = MascotPose.resting(for: try c.decode(PhaseName.self, forKey: Key(stringValue: "from")).phase)
            }
            for key in c.allKeys where key.stringValue != "from" {
                let value = try c.decode(Double.self, forKey: key)
                switch key.stringValue {
                case "yaw": pose.yaw = value
                case "pitch": pose.pitch = value
                case "eyeOpen": pose.eyeOpen = value
                case "eyeSquint": pose.eyeSquint = value
                case "scaleX": pose.scaleX = value
                case "scaleY": pose.scaleY = value
                case "tilt": pose.tilt = value
                case "gazeMix": pose.gazeMix = value
                default: pose = pose.setting(MascotControl(key.stringValue), to: value)
                }
            }
            self.pose = pose
        }
    }

    /// `{"phase": "waiting", "when": [{"fact": "news", "atLeast": 1}], "after": 60, "every": 20,
    /// "play": ["flicker", {"motion": "sway", "weight": 3}]}`.
    struct Rule: Decodable {
        var phase: PhaseName
        var when: [Condition]?
        var after: Double?
        var every: Double?
        var play: [Pick]

        var rule: MascotRule {
            MascotRule(phase: phase.phase, when: (when ?? []).map(\.condition), after: after ?? 0, every: every,
                       play: play.map(\.pick))
        }
    }

    struct Condition: Decodable {
        var fact: String
        var atLeast: Int?
        var atMost: Int?

        var condition: MascotCondition {
            MascotCondition(fact: MascotContext.Fact.named[fact] ?? .waiting, atLeast: atLeast ?? 0,
                            atMost: atMost ?? Int.max)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            fact = try c.decode(String.self, forKey: Key(stringValue: "fact"))
            guard MascotContext.Fact.named[fact] != nil else {
                throw DecodingError.dataCorruptedError(forKey: Key(stringValue: "fact"), in: c,
                                                       debugDescription: "no fact \(fact)")
            }
            atLeast = try c.decodeIfPresent(Int.self, forKey: Key(stringValue: "atLeast"))
            atMost = try c.decodeIfPresent(Int.self, forKey: Key(stringValue: "atMost"))
        }
    }

    /// A gesture's name, or `{"motion": "sway", "weight": 3}`.
    struct Pick: Decodable {
        var pick: MascotRule.Pick

        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                pick = .init(name)
                return
            }
            let c = try decoder.container(keyedBy: Key.self)
            pick = .init(try c.decode(String.self, forKey: Key(stringValue: "motion")),
                         weight: try c.decodeIfPresent(Double.self, forKey: Key(stringValue: "weight")) ?? 1)
        }
    }
}

extension CodingUserInfoKey {
    /// The folder a character file is read from, where its pictures are.
    static let mascotFolder = CodingUserInfoKey(rawValue: "evlat.mascotFolder")!
}

extension MascotProperty {
    /// Each property by its name in a file.
    static let named: [String: MascotProperty] = Dictionary(uniqueKeysWithValues: allCases.map {
        ("\($0)", $0)
    })
}

extension MascotContext.Fact {
    /// Each fact by its name in a file.
    static let named: [String: MascotContext.Fact] = Dictionary(uniqueKeysWithValues: allCases.map {
        ("\($0)", $0)
    })
}
