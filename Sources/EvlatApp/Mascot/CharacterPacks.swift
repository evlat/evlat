import AppKit
import SwiftUI
import EvlatCore

/// The installed character packs (`CharacterPack`), their images loaded, and
/// how one gets in: import a folder or a `.zip`, or export the user's own
/// Custom character as one to share.
///
/// Packs live in `Application Support/Evlat/Characters/<name>`. A pack is
/// data only; an import is validated before it is copied in, and replaces a
/// pack of the same name whole.
struct LoadedPack: Equatable {
    let pack: CharacterPack
    let body: NSImage
    let face: NSImage?
}

enum CharacterPacks {
    static func folder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Evlat/Characters", isDirectory: true)
    }

    static func load(home: URL) -> [LoadedPack] {
        CharacterPack.installed(in: folder(home: home)).compactMap { pack in
            guard let body = NSImage(contentsOf: pack.body) else { return nil }
            return LoadedPack(pack: pack, body: body, face: pack.face.flatMap { NSImage(contentsOf: $0.image) })
        }
    }

    enum ImportError: Error, Equatable {
        case unreadable
        case invalid(CharacterPack.Rejection)
        case unwritable
    }

    /// A pack folder, or a `.zip` holding one (at its top or one folder down).
    static func importPack(from url: URL, home: URL) -> Result<CharacterPack, ImportError> {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("evlat-character-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        var source = url
        if url.pathExtension.lowercased() == "zip" {
            guard (try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil,
                  unzip(url, into: scratch) else { return .failure(.unreadable) }
            source = scratch
        }
        guard let root = manifestFolder(in: source),
              let data = try? Data(contentsOf: root.appendingPathComponent(CharacterPack.manifestName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable)
        }
        let pack: CharacterPack
        switch CharacterPack.validate(json, directory: root, fileSize: SoundPack.fileSize) {
        case .failure(let rejection): return .failure(.invalid(rejection))
        case .success(let found): pack = found
        }
        // Only what the manifest names is copied: the pack's own files, nothing else.
        let destination = folder(home: home).appendingPathComponent(pack.name, isDirectory: true)
        let staging = scratch.appendingPathComponent("staged-\(pack.name)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in [root.appendingPathComponent(CharacterPack.manifestName), pack.body] + [pack.face?.image].compactMap({ $0 }) {
                try fm.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
            }
            try fm.createDirectory(at: folder(home: home), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staging) }
            else { try fm.moveItem(at: staging, to: destination) }
        } catch {
            return .failure(.unwritable)
        }
        return CharacterPack.read(directory: destination).map { .success($0) } ?? .failure(.unwritable)
    }

    static func manifestFolder(in url: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent(CharacterPack.manifestName).path) { return url }
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.first { fm.fileExists(atPath: $0.appendingPathComponent(CharacterPack.manifestName).path) }
    }

    /// `ditto`, macOS's own archiver, the way Finder unpacks a zip.
    static func unzip(_ zip: URL, into folder: URL) -> Bool {
        run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
    }

    /// The Custom character as a shareable `.zip`: its face as the body, its
    /// eyes, a manifest.
    static func export(_ portrait: Portrait, displayName: String, author: String, to zip: URL) -> Bool {
        let fm = FileManager.default
        let name = slug(displayName)
        let scratch = fm.temporaryDirectory.appendingPathComponent("evlat-export-\(UUID().uuidString)", isDirectory: true)
        let folder = scratch.appendingPathComponent(name, isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let manifest = CharacterPack.manifest(name: name, displayName: displayName, author: author,
                                              license: "", eyes: portrait.eyes)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let tiff = portrait.face.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let json = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
              (try? png.write(to: folder.appendingPathComponent("body.png"))) != nil,
              (try? json.write(to: folder.appendingPathComponent(CharacterPack.manifestName))) != nil else { return false }
        try? fm.removeItem(at: zip)
        return run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", folder.path, zip.path])
    }

    /// A pack name from a display name: lowercase letters, digits, `-`.
    static func slug(_ text: String) -> String {
        let kept = text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let joined = String(kept).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "custom" : String(joined.prefix(48))
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

private struct MascotPackKey: EnvironmentKey { static let defaultValue: LoadedPack? = nil }

extension EnvironmentValues {
    /// The character pack drawn when `mascotCharacter` is `.pack`.
    var mascotPack: LoadedPack? {
        get { self[MascotPackKey.self] }
        set { self[MascotPackKey.self] = newValue }
    }
}

/// A character pack, drawn from the pose: the body leans and squashes like
/// the cube's; a face layer (when there is one) squeezes on a blink, swells
/// on `waiting`, follows the gaze and takes the status colour; eyes (when
/// there are any) are the cube's capsules where the pack puts them.
struct PackBody: View {
    let pose: MascotPose
    let size: CGFloat
    let loaded: LoadedPack
    @Environment(\.mascotPhase) private var phase

    /// Strong enough to read on a small white disc.
    static func faceColor(_ phase: Phase) -> Color {
        switch phase {
        case .idle: return Color(red: 0.98, green: 0.62, blue: 0.76)
        case .working: return Color(red: 0.40, green: 0.70, blue: 1.0)
        case .waiting: return Color(red: 1.0, green: 0.76, blue: 0.20)
        case .review: return Color(red: 0.35, green: 0.85, blue: 0.45)
        case .failed: return Color(red: 1.0, green: 0.36, blue: 0.34)
        }
    }

    var body: some View {
        let lookX = pose.yaw * size * 0.06, lookY = pose.pitch * size * 0.05
        return ZStack(alignment: .topLeading) {
            Image(nsImage: loaded.body).resizable().interpolation(.high).frame(width: size, height: size)
            if let face = loaded.pack.face, let image = loaded.face {
                faceLayer(face, image)
                    .offset(x: lookX, y: lookY)
            }
            ForEach(Array(loaded.pack.eyes.enumerated()), id: \.offset) { index, eye in
                capsule(eye, side: index == 0 ? -1 : 1)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .center)
        .rotationEffect(.degrees(pose.tilt))
        .animation(.easeInOut(duration: 0.35), value: phase)
    }

    @ViewBuilder private func faceLayer(_ face: CharacterPack.Face, _ image: NSImage) -> some View {
        let side = size * face.size
        let squeeze = max(0.12, min(1.25, pose.eyeOpen)) * (1 - pose.eyeSquint * 0.3)
        let swell = 1 + max(0, pose.eyeOpen - 1) * 0.6
        Group {
            if face.tintsByStatus {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                    .foregroundStyle(Self.faceColor(phase))
            } else {
                Image(nsImage: image).resizable().interpolation(.high)
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(x: 1, y: squeeze, anchor: .center)
        .scaleEffect(swell)
        .position(x: size * face.cx, y: size * face.cy)
    }

    private func capsule(_ eye: EyeFinder.Eye, side: Double) -> some View {
        let away = max(0, side * pose.yaw)
        let width = size * eye.width * (1 - away * 0.42)
        let length = size * eye.length * pose.eyeOpen * (1 - pose.eyeSquint * 0.55)
        return Capsule(style: .continuous)
            .fill(Color(white: 0.07))
            .frame(width: width, height: max(width * 0.35, length))
            .rotationEffect(.degrees(eye.tilt))
            .position(x: size * eye.cx + pose.yaw * size * 0.05,
                      y: size * eye.cy + pose.pitch * size * 0.04 + pose.eyeSquint * size * 0.02)
    }
}
