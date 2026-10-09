import Foundation
import EvlatCore

/// The animated pets AI coding agents keep, read as a mascot: one folder
/// each, a `pet.json` beside one picture sheet.
///
/// The format is the Codex app's, and petdex's gallery and other agents'
/// players read it too. Its numbers are OpenAI's `hatch-pet` skill's
/// (`references/codex-pet-contract.md`, `animation-rows.md`): a PNG or WebP
/// of 8 columns of 192×208 cells, one state a row, each row's frames shown
/// for the durations in `rows`. Version 1 is 9 rows (1536×1872). Version 2
/// (`"spriteVersionNumber": 2`, 1536×2288) adds two rows of 16 cells
/// looking around, clockwise from up; that layout is read from third-party
/// players (petx's core) and from a Codex-made sheet, not from OpenAI's
/// published contract. The picture's size decides the version, as those
/// players do.
///
/// A pet keeps Evlat's contract (`MascotContract`) the way a drawn
/// character does: its rows are clips of cuts on one own control, `cell`.
/// Codex loops a row for as long as a state lasts; here a row plays as a
/// **burst** — once through, then still on its first frame — because a
/// sheet looping forever is the continuous animation the CPU budget rules
/// out (`AGENTS.md` → Rendering and CPU). `waiting` and `review` play once
/// and hold, as every character's do. The locomotion rows
/// (`running-right`, `running-left`) are a pet walking across a screen and
/// are not played; `waving` is the gesture a long wait gets.
enum PetAtlas {
    /// The manifest's fields Evlat reads; the rest are the pet's own.
    struct Manifest: Decodable {
        var displayName: String?
        var spritesheetPath: String?
    }

    /// Why a folder is not offered as a mascot.
    enum Failure: Error, Equatable {
        /// No `pet.json`, or one that is not a manifest.
        case unreadableManifest
        /// `spritesheetPath` leaves the pet's folder.
        case pictureOutside
        /// The picture named is not there, or is not a picture.
        case noPicture
        /// A picture of another size than a sheet's.
        case wrongSize(width: Int, height: Int)
    }

    static let manifestName = "pet.json"
    static let columns = 8
    static let cell = (width: 192, height: 208)
    /// The rows each version has, by the sheet's height.
    static let versions = [cell.height * 9: 9, cell.height * 11: 11]

    /// A state's row, and how long each of its frames is shown, seconds.
    struct Row: Equatable {
        let row: Int
        let durations: [Double]

        init(_ row: Int, _ milliseconds: [Double]) {
            self.row = row
            durations = milliseconds.map { $0 / 1000 }
        }
    }

    static let idle = Row(0, [280, 110, 110, 140, 140, 320])
    static let waving = Row(3, [140, 140, 140, 280])
    static let failed = Row(5, [140, 140, 140, 140, 140, 140, 140, 240])
    static let waiting = Row(6, [150, 150, 150, 150, 150, 260])
    /// "running" is the row of a working agent — not the locomotion rows.
    static let running = Row(7, [120, 120, 120, 120, 120, 220])
    static let review = Row(8, [150, 150, 150, 150, 150, 280])

    /// How long a looping phase rests on its first frame between bursts.
    static let pauses: [Phase: Double] = [.idle: 6, .working: 2.5, .failed: 6]

    /// The cell a frame is drawn from.
    static let cellControl = MascotControl("cell")

    /// The pet in `folder` as a mascot named `id`, or why it cannot be one.
    /// Reads the manifest and the picture's size; the picture's pixels wait
    /// until it is drawn (`MascotSheet`).
    static func character(in folder: URL, id: String) throws -> MascotCharacter {
        let manifestURL = folder.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL), data.count <= 64 * 1024,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw Failure.unreadableManifest
        }
        let picture = try pictureURL(manifest.spritesheetPath ?? "spritesheet.webp", in: folder)
        guard let size = MascotSheet.pixelSize(of: picture) else { throw Failure.noPicture }
        guard size.width == columns * cell.width, let rows = versions[size.height] else {
            throw Failure.wrongSize(width: size.width, height: size.height)
        }
        let name = manifest.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return character(sheet: MascotSheet.sheet(at: picture, columns: columns, rows: rows), id: id,
                         name: name?.isEmpty == false ? name : folder.lastPathComponent)
    }

    /// The picture a manifest names, inside the pet's folder only: no
    /// absolute path, nothing that climbs out.
    static func pictureURL(_ path: String, in folder: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." }) else {
            throw Failure.pictureOutside
        }
        return parts.reduce(folder) { $0.appendingPathComponent(String($1)) }
    }

    /// The character a sheet makes: one part drawing the cell its control
    /// names, its phases the rows above.
    static func character(sheet: MascotSheet, id: String, name: String?) -> MascotCharacter {
        let rig = MascotRig(
            root: MascotPart(
                name: "pet",
                shape: .cells(sheet, by: cellControl),
                // Scale, so a caught file still stretches it; no tilt — a
                // drawn pet does its own leaning.
                bindings: [.follows(.scaleX, .scaleX, over: (0, 2)), .follows(.scaleY, .scaleY, over: (0, 2))]),
            controls: [cellControl: MascotControl.Range(0, Double(sheet.columns * sheet.rows - 1), rest: 0)])
        return MascotCharacter(
            id: id, rig: rig,
            states: [
                .idle: burst(idle, phase: .idle),
                .working: burst(running, phase: .working),
                .failed: burst(failed, phase: .failed),
                .waiting: once(waiting, phase: .waiting, passes: 2),
                .review: once(review, phase: .review, passes: 1)
            ],
            motions: ["wave": gesture(waving, on: rest(waiting, phase: .waiting))],
            behavior: MascotBehavior(rules: [
                MascotRule(phase: .waiting, after: 45, play: [.init("wave")]),
                MascotRule(phase: .waiting, after: 180, play: [.init("wave")])
            ]),
            name: name)
    }

    /// Frame `frame` of `row`, in a phase's pose: the phase's own share of
    /// the cursor, nothing else of Evlat's face — a picture is not squashed
    /// or widened to say what its frames say.
    static func pose(_ row: Row, frame: Int, phase: Phase) -> MascotPose {
        MascotPose(gazeMix: MascotPose.resting(for: phase).gazeMix)
            .setting(cellControl, to: Double(row.row * columns + frame))
    }

    static func rest(_ row: Row, phase: Phase) -> MascotPose { pose(row, frame: 0, phase: phase) }

    /// The row once through, after a still first frame: a loop's step 0
    /// rests, the cuts play the frames after it, and the last step is the
    /// first frame again — the loop's seam, shown for its own duration.
    static func burst(_ row: Row, phase: Phase) -> MascotClip {
        let rest = rest(row, phase: phase)
        let frames = row.durations.indices.dropFirst().map {
            MascotClip.Step.cut(pose(row, frame: $0, phase: phase), hold: row.durations[$0])
        }
        return MascotClip(steps: [.entering(rest, hold: pauses[phase] ?? 6)] + frames
                            + [.cut(rest, hold: row.durations[0])], loops: true)
    }

    /// The row `passes` times on arrival, then held on its first frame. The
    /// first frame waits out the phase change's spring before the next
    /// cut: that spring is what carries a caught file's stretch away.
    static func once(_ row: Row, phase: Phase, passes: Int) -> MascotClip {
        let rest = rest(row, phase: phase)
        var steps: [MascotClip.Step] = [.entering(rest, hold: max(row.durations[0], MascotPose.transitionDuration))]
        for pass in 0..<passes {
            if pass > 0 { steps.append(.cut(rest, hold: row.durations[0])) }
            steps += row.durations.indices.dropFirst().map {
                .cut(pose(row, frame: $0, phase: phase), hold: row.durations[$0])
            }
        }
        return MascotClip(steps: steps + [.cut(rest, hold: row.durations[0])], loops: false)
    }

    /// A row played once over a phase, back on that phase's rest.
    static func gesture(_ row: Row, on rest: MascotPose) -> MascotClip {
        let frames = row.durations.indices.map { frame in
            MascotClip.Step.cut(rest.setting(cellControl, to: Double(row.row * columns + frame)),
                                hold: row.durations[frame])
        }
        return MascotClip(steps: frames + [.cut(rest, hold: 0.15)], loops: false)
    }
}
