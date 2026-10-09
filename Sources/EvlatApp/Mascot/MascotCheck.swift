import SwiftUI
import AppKit
import EvlatCore

/// `evlat mascot check FOLDER [--preview FILE.png]`: a mascot's folder read
/// as Settings → Mascot reads it (`MascotLibrary`), and every rule of the
/// contract it breaks printed — where Settings shows only the first, under
/// the tiles. For whoever makes a mascot, a person or an agent: the one
/// answer it can read without opening Evlat, and with `--preview`, a
/// picture of its five states it can look at.
///
/// Exit 0 when the folder is a mascot Settings would offer, 1 when it is
/// not, 2 on a usage error. The output is English, as every other line the
/// command line prints.
public enum MascotCheck {
    public struct Result: Equatable {
        public var status: Int32
        public var output: String
    }

    static let usage = "usage: evlat mascot check FOLDER [--preview FILE.png]"

    /// The arguments after `mascot`, under the home the app works under.
    @MainActor
    public static func run(_ arguments: [String]) -> Result {
        run(arguments, home: AppController.resolvedHome())
    }

    @MainActor
    static func run(_ arguments: [String], home: URL) -> Result {
        guard arguments.first == "check" else {
            return Result(status: SignalCommand.usageExitCode, output: usage)
        }
        var folder: URL?
        var preview: URL?
        var rest = Array(arguments.dropFirst())
        while let word = rest.first {
            rest.removeFirst()
            if word == "--preview" {
                guard let path = rest.first else { return Result(status: SignalCommand.usageExitCode, output: usage) }
                rest.removeFirst()
                preview = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else if folder == nil, !word.hasPrefix("-") {
                folder = URL(fileURLWithPath: (word as NSString).expandingTildeInPath, isDirectory: true)
            } else {
                return Result(status: SignalCommand.usageExitCode, output: usage)
            }
        }
        guard let folder else { return Result(status: SignalCommand.usageExitCode, output: usage) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return Result(status: 1, output: "\(folder.path): no such folder")
        }
        let own = MascotLibrary.folder(home: home).standardizedFileURL.path
        // Found where Settings looks — Evlat's own folder or an agent's
        // pets — it carries that source's id; anywhere else, Evlat's.
        let parent = folder.standardizedFileURL.deletingLastPathComponent().path
        let source = MascotLibrary.sources(home: home).first { $0.folder.standardizedFileURL.path == parent }
        let id = (source?.prefix ?? MascotLibrary.ownPrefix) + ":" + folder.lastPathComponent

        switch MascotLibrary.read(in: folder, id: id) {
        case .failure(let reason):
            var lines = ["not a mascot: " + line(for: reason)]
            if case .file(.unreadable) = reason, let detail = CharacterFile.detail(in: folder) {
                lines.append("  " + detail)
            }
            return Result(status: 1, output: lines.joined(separator: "\n"))
        case .success(let character):
            var lines: [String] = []
            let broken = MascotContract.violations(of: character)
            let name = character.name ?? folder.lastPathComponent
            if broken.isEmpty {
                lines.append("ok: “\(name)” reads and keeps every rule.")
                lines.append(source != nil
                    ? "It shows in Settings → Mascot → Look (\(id))."
                    : "Put its folder in \(own)/ to see it in Settings → Mascot → Look.")
            } else {
                lines.append("“\(name)” breaks \(broken.count) rule\(broken.count == 1 ? "" : "s"), so Settings leaves it out:")
                // The contract names the character by its id first; the id
                // is this check's, not the author's.
                lines += broken.map { "  - " + $0.replacingOccurrences(of: id + ": ", with: "") }
            }
            if let preview {
                if let failure = draw(character, named: name, to: preview) {
                    lines.append("no preview: \(failure)")
                } else {
                    lines.append("preview: \(preview.path)")
                }
            }
            return Result(status: broken.isEmpty ? 0 : 1, output: lines.joined(separator: "\n"))
        }
    }

    static func line(for reason: MascotLibrary.Reason) -> String {
        switch reason {
        case .empty: return "the folder has no character.json or pet.json"
        case .file(.unreadable(let at)): return "character.json can't be read" + (at.isEmpty ? "" : " at \(at)")
        case .file(.newerVersion(let version)):
            return "character.json is version \(version); this Evlat reads version \(CharacterFile.version)"
        case .file(.pictureOutside), .pet(.pictureOutside): return "a picture it names is outside its folder"
        case .file(.noPicture(let path)): return "its picture \(path) is missing or is not a picture"
        case .pet(.unreadableManifest): return "pet.json can't be read"
        case .pet(.noPicture): return "its sheet is missing or is not a picture"
        case .pet(.wrongSize(let width, let height)):
            return "its sheet is \(width)×\(height); a pet sheet is 1536×1872 or 1536×2288"
        case .contract(let rule): return rule
        }
    }

    /// Draws the five states at rest, large and at the bar's size, with a
    /// blink and a look each way; `nil` when it is written, else why not.
    @MainActor
    static func draw(_ character: MascotCharacter, named name: String, to url: URL) -> String? {
        let renderer = ImageRenderer(content: MascotPreviewSheet(character: character, name: name))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return "it could not be drawn"
        }
        do {
            try data.write(to: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The preview: each state at rest, as large as a picture can show and at
/// the bar's own size, beside a blink and the gaze either way.
struct MascotPreviewSheet: View {
    let character: MascotCharacter
    let name: String

    private var poses: [(String, MascotPose)] {
        let idle = character.resting(for: .idle)
        var blink = idle
        blink.eyeOpen *= 0.08
        return Phase.allCases.map { ($0.rawValue, character.resting(for: $0)) } + [
            ("blink", blink),
            ("look ←", idle.blending(gaze: CGSize(width: -1, height: 0.2))),
            ("look →", idle.blending(gaze: CGSize(width: 1, height: -0.2)))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            row(size: 96)
            row(size: AppController.mascotSize)
        }
        .padding(16)
        .background(Color.black)
    }

    private func row(size: CGFloat) -> some View {
        // Room either side of each: whiskers and ears reach past the square.
        HStack(alignment: .top, spacing: size * 0.25 + 8) {
            ForEach(poses.indices, id: \.self) { i in
                VStack(spacing: 6) {
                    MascotBody(pose: poses[i].1, size: size, rig: character.rig).frame(width: size, height: size)
                    Text(poses[i].0).font(.system(size: 10)).foregroundStyle(.gray)
                }
                .frame(width: max(size, 60))
            }
        }
    }
}
