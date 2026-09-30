import AppKit

/// The waiting nudge's sound: two soft bell notes, a fourth apart, drawn in
/// code like the icon — no sound file is checked in or bundled. Played with
/// `NSSound`, which asks for no permission.
enum Chime {
    static let sampleRate = 44_100

    /// (start, frequency) of each note: G5, then C6 a beat later.
    private static let notes: [(start: Double, frequency: Double)] = [(0, 783.99), (0.14, 1046.50)]
    /// Partials over the fundamental and their weights: a little octave and
    /// twelfth warm it without the metallic edge of a real bell.
    private static let partials: [(ratio: Double, weight: Double)] = [(1, 1), (2, 0.18), (3, 0.05)]
    private static let length = 1.4
    private static let attack = 0.008
    private static let decay = 0.32
    private static let peak = 0.45

    /// Mono 16-bit samples, normalised to `peak`.
    static func samples() -> [Int16] {
        let count = Int(length * Double(sampleRate))
        var mix = [Double](repeating: 0, count: count)
        for note in notes {
            let first = Int(note.start * Double(sampleRate))
            for i in first..<count {
                let t = Double(i - first) / Double(sampleRate)
                let envelope = min(1, t / attack) * exp(-t / decay)
                var value = 0.0
                for partial in partials {
                    // Higher partials fade faster, as they do on a struck bar.
                    value += partial.weight * exp(-t * (partial.ratio - 1) * 3)
                        * sin(2 * .pi * note.frequency * partial.ratio * t)
                }
                mix[i] += envelope * value
            }
        }
        // The tail fades to zero, so the end never clicks.
        let fade = Int(0.05 * Double(sampleRate))
        for i in 0..<fade { mix[count - 1 - i] *= Double(i) / Double(fade) }
        let top = mix.map(abs).max() ?? 1
        return mix.map { Int16(($0 / top * peak * Double(Int16.max)).rounded()) }
    }

    /// The samples as a WAV file.
    static func wav() -> Data {
        let pcm = samples()
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                        // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))  // rate, bytes per second
        append(UInt16(2)); append(UInt16(16))                       // block, bits
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in pcm { append(sample) }
        return data
    }

    /// Kept alive while it plays: a released `NSSound` stops.
    @MainActor private static var sound: NSSound?

    @MainActor static func play() {
        if sound == nil { sound = NSSound(data: wav()) }
        sound?.stop()
        sound?.play()
    }
}
