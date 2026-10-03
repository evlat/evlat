import AppKit
import SwiftUI
import EvlatCore

/// A character the user made from a picture: the bot icon with its eyes
/// painted out (`face.png`), and where the eyes were (`character.json`).
/// `PortraitBody` draws the mascot's own eyes there, so it blinks, looks and
/// squints like the cube.
///
/// One slot, in `Application Support/Evlat/Character`: making another
/// replaces it.
struct Portrait: Equatable {
    let face: NSImage
    let eyes: [EyeFinder.Eye]

    /// The side the icon is worked at: plenty for a 34 pt mascot at 3×.
    static let side = 512

    static func folder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Evlat/Character", isDirectory: true)
    }

    /// A character from before the head floated (version 1: framed and
    /// tilted) is shaped once here and saved again.
    static func load(home: URL) -> Portrait? {
        let folder = folder(home: home)
        guard let face = NSImage(contentsOf: folder.appendingPathComponent("face.png")),
              let data = try? Data(contentsOf: folder.appendingPathComponent("character.json")),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.eyes.count == 2 else { return nil }
        guard stored.version < Stored.current else { return Portrait(face: face, eyes: stored.eyes) }
        guard let rgba = bitmap(from: face) else { return nil }
        let shaped = PortraitShaper.shape(rgba: rgba, side: side, eyes: stored.eyes, out: side)
        return (try? save(rgba: shaped.rgba, eyes: shaped.eyes, home: home).get())
    }

    struct Stored: Codable {
        /// 2: a floating head (`PortraitShaper`).
        static let current = 2
        var version = current
        let eyes: [EyeFinder.Eye]
    }

    /// The picture as a `side`×`side` RGBA buffer, scaled to fill: an icon
    /// is square, and anything else is centred and cropped.
    static func bitmap(from image: NSImage) -> [UInt8]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let scale = Double(side) / Double(min(cg.width, cg.height))
            let w = Double(cg.width) * scale, h = Double(cg.height) * scale
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
            return true
        }
        return ok ? buffer : nil
    }

    static func png(from rgba: [UInt8]) -> Data? {
        var copy = rgba
        return copy.withUnsafeMutableBytes { raw -> Data? in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }

    /// Finds the eyes in an icon and stores the character. The failure is
    /// the eye-finder's: an icon without two clear capsule eyes is not saved.
    static func make(from image: NSImage, home: URL) -> Result<Portrait, MakeError> {
        guard let rgba = bitmap(from: image) else { return .failure(.unreadable) }
        switch EyeFinder.find(rgba: rgba, width: side, height: side) {
        case .failure(let failure): return .failure(.eyes(failure))
        case .success(let found):
            let shaped = PortraitShaper.shape(rgba: found.cleaned, side: side, eyes: found.eyes, out: side)
            return save(rgba: shaped.rgba, eyes: shaped.eyes, home: home)
        }
    }

    private static func save(rgba: [UInt8], eyes: [EyeFinder.Eye], home: URL) -> Result<Portrait, MakeError> {
        guard let png = png(from: rgba), let face = NSImage(data: png),
              let json = try? JSONEncoder().encode(Stored(eyes: eyes)) else { return .failure(.unwritable) }
        let folder = folder(home: home)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("face.png"), options: .atomic)
            try json.write(to: folder.appendingPathComponent("character.json"), options: .atomic)
        } catch {
            return .failure(.unwritable)
        }
        return .success(Portrait(face: face, eyes: eyes))
    }

    enum MakeError: Error, Equatable {
        case unreadable, unwritable
        case eyes(EyeFinder.Failure)
        case makerMissing
        /// No prompt pasted yet.
        case noPrompt
        /// Codex ran and gave no icon; the tail of what it said.
        case generationFailed(String)
    }
}

private struct MascotPortraitKey: EnvironmentKey { static let defaultValue: Portrait? = nil }

extension EnvironmentValues {
    /// The user's character, when there is one.
    var mascotPortrait: Portrait? {
        get { self[MascotPortraitKey.self] }
        set { self[MascotPortraitKey.self] = newValue }
    }
}

/// The user's character: a floating head, their face with the mascot's eyes.
///
/// Upright and unframed (`PortraitShaper`), so it leans with the pose's
/// tilt, squashes like the cube and hovers on a breath, as the fairy does.
/// The eyes are the cube's capsules, placed where the picture had them,
/// sized by the pose (`eyeOpen`, `eyeSquint`), moved a little by the gaze,
/// and narrowed on the far side as the cube's are.
struct PortraitBody: View {
    let pose: MascotPose
    let size: CGFloat
    let portrait: Portrait

    var body: some View {
        // A breath (squash above 1) lifts the head instead of stretching it.
        let hover = (pose.scaleY - 1) * size * 1.6
        return ZStack(alignment: .topLeading) {
            Image(nsImage: portrait.face)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
            ForEach(Array(portrait.eyes.enumerated()), id: \.offset) { index, eye in
                capsule(eye, side: index == 0 ? -1 : 1)
            }
        }
        .frame(width: size, height: size)
        // Unframed, the head can take more of the mascot's room than the
        // cube's box: it reads at the cube's weight.
        .scaleEffect(1.15)
        .scaleEffect(x: 1 + (pose.scaleX - 1) * 0.5, y: 1 + (pose.scaleY - 1) * 0.5, anchor: .bottom)
        .rotationEffect(.degrees(pose.tilt * 1.4), anchor: .bottom)
        .offset(x: pose.yaw * size * 0.03, y: -hover)
    }

    private func capsule(_ eye: EyeFinder.Eye, side: Double) -> some View {
        let away = max(0, side * pose.yaw)
        let narrow = 1 - away * 0.42
        let width = size * eye.width * narrow
        let length = size * eye.length * pose.eyeOpen * (1 - pose.eyeSquint * 0.55)
        return Capsule(style: .continuous)
            .fill(Color(white: 0.07))
            .frame(width: width, height: max(width * 0.35, length))
            .rotationEffect(.degrees(eye.tilt))
            .position(x: size * eye.cx + pose.yaw * size * 0.05,
                      y: size * eye.cy + pose.pitch * size * 0.04 + pose.eyeSquint * size * 0.02)
    }
}
