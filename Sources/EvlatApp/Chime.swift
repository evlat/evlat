import AppKit
import EvlatCore

/// Evlat's own sounds, drawn in code like the icon — no sound file is checked
/// in or bundled. Each is a few struck or plucked notes: a fundamental and a
/// handful of partials under one envelope, the partials fading faster than
/// the note, as they do on a real bar or tine. Played with `NSSound`, which
/// asks for no permission.
enum EvlatSound: String, CaseIterable {
    /// The waiting reminder's sound since it first rang: two soft bell
    /// notes, a fourth apart.
    case bell
    /// One drop and a smaller one after it: a sine bent upward fast.
    case drop
    /// A struck glass bar: inharmonic partials, a long shimmer.
    case crystal
    /// A major arpeggio climbing to the octave.
    case rise
    /// A minor third falling, low and short: an ending that went wrong,
    /// said without alarm.
    case fall
    /// Two quick wooden taps, the second softer: someone at the door.
    case knock
    /// Up a fifth with a small lift into the second note, as a voice asks.
    case question
    /// Two plucked tines.
    case kalimba
    /// A soft major chord swelling in and fading.
    case glow

    /// The catalogue's name for it.
    var nameKey: String { "sound.evlat." + rawValue }

    struct Partial {
        let ratio: Double
        let weight: Double
        /// Extra decay per second on top of the note's own.
        let damp: Double
    }

    struct Note {
        let start: Double
        let frequency: Double
        var gain = 1.0
        /// The pitch it starts at, as a share of `frequency`, and how fast
        /// it reaches it: 1 is no bend.
        var bendFrom = 1.0
        var bendTime = 0.03
    }

    struct Voice {
        let notes: [Note]
        let partials: [Partial]
        let attack: Double
        let decay: Double
        let length: Double
    }

    var voice: Voice {
        switch self {
        case .bell:
            // Unchanged from the first chime: G5, then C6 a beat later.
            return Voice(notes: [Note(start: 0, frequency: 783.99), Note(start: 0.14, frequency: 1046.50)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 2, weight: 0.18, damp: 3),
                                    Partial(ratio: 3, weight: 0.05, damp: 6)],
                         attack: 0.008, decay: 0.32, length: 1.4)
        case .drop:
            return Voice(notes: [Note(start: 0, frequency: 1480, bendFrom: 0.55, bendTime: 0.025),
                                 Note(start: 0.13, frequency: 1975.5, gain: 0.55, bendFrom: 0.6, bendTime: 0.02)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 2, weight: 0.05, damp: 20)],
                         attack: 0.002, decay: 0.085, length: 0.6)
        case .crystal:
            return Voice(notes: [Note(start: 0, frequency: 1318.51), Note(start: 0.09, frequency: 1975.53, gain: 0.45)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 2.32, weight: 0.32, damp: 1.5),
                                    Partial(ratio: 4.25, weight: 0.14, damp: 4), Partial(ratio: 6.63, weight: 0.06, damp: 8)],
                         attack: 0.003, decay: 0.6, length: 2.2)
        case .rise:
            return Voice(notes: [Note(start: 0, frequency: 523.25, gain: 0.8), Note(start: 0.085, frequency: 659.25, gain: 0.85),
                                 Note(start: 0.17, frequency: 783.99, gain: 0.9), Note(start: 0.255, frequency: 1046.50)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 2, weight: 0.14, damp: 4),
                                    Partial(ratio: 4, weight: 0.05, damp: 10)],
                         attack: 0.004, decay: 0.3, length: 1.4)
        case .fall:
            return Voice(notes: [Note(start: 0, frequency: 392.00), Note(start: 0.17, frequency: 311.13, gain: 0.9)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 2, weight: 0.3, damp: 3),
                                    Partial(ratio: 3, weight: 0.1, damp: 6)],
                         attack: 0.006, decay: 0.3, length: 1.3)
        case .knock:
            return Voice(notes: [Note(start: 0, frequency: 880), Note(start: 0.13, frequency: 880, gain: 0.7)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 3.93, weight: 0.25, damp: 25),
                                    Partial(ratio: 9.2, weight: 0.08, damp: 60)],
                         attack: 0.0015, decay: 0.07, length: 0.6)
        case .question:
            return Voice(notes: [Note(start: 0, frequency: 1046.50, gain: 0.8),
                                 Note(start: 0.15, frequency: 1567.98, bendFrom: 0.94, bendTime: 0.04)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 2, weight: 0.1, damp: 4)],
                         attack: 0.005, decay: 0.26, length: 1.2)
        case .kalimba:
            return Voice(notes: [Note(start: 0, frequency: 880), Note(start: 0.11, frequency: 1318.51, gain: 0.85)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 6.27, weight: 0.12, damp: 18),
                                    Partial(ratio: 2, weight: 0.04, damp: 6)],
                         attack: 0.003, decay: 0.45, length: 1.6)
        case .glow:
            return Voice(notes: [Note(start: 0, frequency: 523.25, gain: 0.8), Note(start: 0.03, frequency: 659.25, gain: 0.7),
                                 Note(start: 0.06, frequency: 783.99, gain: 0.65)],
                         partials: [Partial(ratio: 1, weight: 1, damp: 0), Partial(ratio: 2, weight: 0.08, damp: 2)],
                         attack: 0.07, decay: 0.55, length: 1.8)
        }
    }
}

/// The synthesis: `EvlatSound.voice` → samples → a WAV `NSSound` reads.
enum Chime {
    static let sampleRate = 44_100
    private static let peak = 0.45

    /// Mono 16-bit samples, normalised to `peak`.
    static func samples(_ sound: EvlatSound = .bell) -> [Int16] {
        let voice = sound.voice
        let rate = Double(sampleRate)
        let count = Int(voice.length * rate)
        var mix = [Double](repeating: 0, count: count)
        for note in voice.notes {
            let first = Int(note.start * rate)
            guard first < count else { continue }
            // Phase is accumulated, not computed from `t`: a bending pitch
            // read as sin(2πft) would jump.
            var phases = [Double](repeating: 0, count: voice.partials.count)
            for i in first..<count {
                let t = Double(i - first) / rate
                let bend = note.bendFrom == 1 ? 1 : 1 - (1 - note.bendFrom) * exp(-t / note.bendTime)
                let frequency = note.frequency * bend
                let envelope = min(1, t / voice.attack) * exp(-t / voice.decay)
                var value = 0.0
                for (p, partial) in voice.partials.enumerated() {
                    phases[p] += 2 * .pi * frequency * partial.ratio / rate
                    value += partial.weight * exp(-t * partial.damp) * sin(phases[p])
                }
                mix[i] += note.gain * envelope * value
            }
        }
        // The tail fades to zero, so the end never clicks.
        let fade = min(count, Int(0.05 * rate))
        for i in 0..<fade { mix[count - 1 - i] *= Double(i) / Double(fade) }
        let top = mix.map(abs).max() ?? 1
        return mix.map { Int16(($0 / top * peak * Double(Int16.max)).rounded()) }
    }

    /// The samples as a WAV file.
    static func wav(_ sound: EvlatSound = .bell) -> Data {
        let pcm = samples(sound)
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
}

/// A sound to play: one of Evlat's, one of macOS's alert sounds by name
/// (`NSSound(named:)` finds them; nothing is copied), or a character's line
/// (a file of an installed pack). The first two are the tones Evlat's own
/// voice can give a moment, and are stored; a line is picked as it plays.
enum AlertSound: Hashable {
    case evlat(EvlatSound)
    case system(String)
    case line(URL)

    /// As stored: `evlat.<name>`, `system.<name>`. A line is never stored.
    init?(stored: String) {
        if stored.hasPrefix("evlat."), let sound = EvlatSound(rawValue: String(stored.dropFirst(6))) {
            self = .evlat(sound); return
        }
        if stored.hasPrefix("system."), stored.count > 7 { self = .system(String(stored.dropFirst(7))); return }
        return nil
    }

    var stored: String? {
        switch self {
        case .evlat(let sound): return "evlat." + sound.rawValue
        case .system(let name): return "system." + name
        case .line: return nil
        }
    }

    /// Read once: the list does not change while Evlat runs, and every tone
    /// menu asks for it as it draws.
    static let installedSystemNames = systemNames()

    /// macOS's alert sounds, by the names `NSSound(named:)` takes. Read
    /// where the system keeps them; none found is an empty list.
    static func systemNames(in directory: URL = URL(fileURLWithPath: "/System/Library/Sounds")) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }
}

/// Who speaks (Settings → Mascot → Sounds): Evlat's own tones, or a
/// character — an installed CESP pack (`SoundPack`), by its name.
enum SoundVoice: Hashable {
    case evlat
    case pack(String)

    init(stored: String?) {
        if let stored, stored.hasPrefix("pack."), stored.count > 5 {
            self = .pack(String(stored.dropFirst(5)))
        } else {
            self = .evlat
        }
    }

    var stored: String {
        switch self {
        case .evlat: return "evlat"
        case .pack(let name): return "pack." + name
        }
    }
}

/// The moments that can speak (Settings → Mascot). A finish speaks as it is
/// told (`AppController.tellNews`); a wait as it begins and, once more, when
/// the reminder tells it (`WaitingNudge`), each by what it waits on.
enum SoundMoment: String, CaseIterable {
    case done, failed, approval, answer

    /// Whether it speaks, and Evlat's tone for it.
    var onKey: String { "sound." + rawValue + ".on" }
    var toneKey: String { "sound." + rawValue }
    var nameKey: String { "settings.mascot.moment." + rawValue }

    /// The pack's category a character speaks it from: CESP has one
    /// category for anything that needs the user.
    var category: SoundPack.Category {
        switch self {
        case .done: return .taskComplete
        case .failed: return .taskError
        case .approval, .answer: return .inputRequired
        }
    }

    /// Evlat's tone when none is stored: a climb for done, a fall for an
    /// error, the bell the reminder always rang, a lift for a question.
    var defaultTone: AlertSound {
        switch self {
        case .done: return .evlat(.rise)
        case .failed: return .evlat(.fall)
        case .approval: return .evlat(.bell)
        case .answer: return .evlat(.question)
        }
    }
}

/// What this Mac can play of a pack's files. Measured: an Ogg Vorbis line
/// (`Evet_M.ogg`, 22 kHz mono) is opened by `NSSound` and `AVAudioPlayer`
/// alike and played by neither — `play()` answers `false` — so a pack in Ogg
/// is silent here. Judged by the name, as the registry lists previews.
enum AudioSupport {
    static let unplayable: Set<String> = ["ogg", "oga", "opus", "spx"]

    static func canPlay(_ fileName: String) -> Bool {
        !unplayable.contains((fileName as NSString).pathExtension.lowercased())
    }
}

/// What "Remind again" covers (Settings → Mascot).
enum NudgeScope: String {
    /// Waits, until answered.
    case waits
    /// Waits, and finishes until they are looked at.
    case all
}

/// Plays one sound at a time: a new one stops the last.
@MainActor
enum SoundPlayer {
    /// Settings → Mascot → Volume, 0…1, for every source.
    static var volume: Float = 1
    /// Kept alive while it plays: a released `NSSound` stops.
    private static var playing: NSSound?
    private static var made: [EvlatSound: NSSound] = [:]

    static func play(_ sound: AlertSound) {
        playing?.stop()
        switch sound {
        case .evlat(let evlat):
            let made = Self.made[evlat] ?? NSSound(data: Chime.wav(evlat))
            Self.made[evlat] = made
            playing = made
        case .system(let name):
            playing = NSSound(named: NSSound.Name(name))
        case .line(let file):
            // A pack's file is checked by decoding it: one `NSSound` cannot
            // read plays nothing (CESP 4.4).
            playing = NSSound(contentsOf: file, byReference: true)
        }
        playing?.volume = volume
        playing?.play()
    }
}
