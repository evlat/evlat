import XCTest
import AppKit
import EvlatCore
@testable import EvlatApp

/// The sounds: what each moment plays and when, held on the controller with
/// a recorder in place of the speaker; Evlat's own sounds as samples; and
/// what an upgrade keeps of the reminder's old switch.
@MainActor
final class SoundTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private final class Stub: Provider {
        let id = "stub"
        var signals: [Signal] = []
        func currentSignals() -> [Signal] { signals }
    }

    @MainActor private final class Rig {
        let controller = AppController()
        let provider = Stub()
        var played: [AlertSound] = []
        var panel: BarPanel!
        var now = Date(timeIntervalSince1970: 1_790_000_000)

        init(before: [Signal] = []) {
            controller.now = { [unowned self] in self.now }
            controller.peekSchedule = { _, _ in }
            controller.soundTones = [.done: .evlat(.rise), .failed: .evlat(.fall),
                                     .approval: .evlat(.bell), .answer: .evlat(.question)]
            controller.soundOn = [.done: true, .failed: true, .approval: true, .answer: true]
            provider.signals = before
            controller.registry.register(provider)
            panel = controller.installPanel()
            controller.playSound = { [unowned self] in self.played.append($0) }
            controller.refresh()
        }

        func set(_ rows: [(String, Phase)], waitKind: Signal.Activity.WaitKind? = nil) {
            provider.signals = rows.map {
                Signal(provider: "stub", entity: $0.0, phase: $0.1, label: $0.0, fidelity: .official,
                       updatedAt: Date(timeIntervalSince1970: 0),
                       activity: $0.1 == .waiting ? Signal.Activity(waitKind: waitKind) : nil)
            }
            controller.refresh()
        }
    }

    // MARK: - A finish

    func testAFinishSoundsOnceWithItsPeek() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.played, [.evlat(.rise)])
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [.evlat(.rise)], "told once")
    }

    func testFinishesTogetherMakeOneSoundAFailuresIfOneFailed() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("a", .working), ("b", .working)])
        rig.set([("a", .review), ("b", .failed)])
        XCTAssertEqual(rig.played, [.evlat(.fall)])
    }

    func testAFinishOnTheOpenBarIsSilent() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("s", .working)])
        rig.controller.openBar()
        rig.set([("s", .review)])
        XCTAssertEqual(rig.played, [])
    }

    func testTheFirstScansFinishesAreSilent() {
        let rig = Rig(before: [Signal(provider: "stub", entity: "s", phase: .review, label: "s",
                                      fidelity: .official, updatedAt: Date(timeIntervalSince1970: 0))])
        defer { rig.panel.close() }
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [])
    }

    func testAMomentThatIsOffIsSilent() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.soundOn[.done] = false
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.played, [])
    }

    /// One sound at a time: a second within the gap is let go.
    func testSoundsInsideTheGapAreLetGo() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("a", .working), ("b", .working)])
        rig.set([("a", .review), ("b", .working)])
        rig.now += 1
        rig.set([("a", .review), ("b", .failed)])
        XCTAssertEqual(rig.played, [.evlat(.rise)])
        rig.now += AppController.soundGap
        rig.set([("a", .review), ("b", .failed), ("c", .working)])
        rig.set([("a", .review), ("b", .failed), ("c", .review)])
        XCTAssertEqual(rig.played, [.evlat(.rise), .evlat(.rise)])
    }

    // MARK: - A wait

    func testAWaitSpeaksAsItBeginsByWhatItWaitsOn() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("s", .working)])
        rig.set([("s", .waiting)], waitKind: .answer)
        XCTAssertEqual(rig.played, [.evlat(.question)])
        rig.now += AppController.soundGap
        rig.set([("s", .working)])
        rig.set([("s", .waiting)], waitKind: .approval)
        XCTAssertEqual(rig.played, [.evlat(.question), .evlat(.bell)], "an answer re-arms it")
    }

    func testAWaitAtTheFirstScanIsSilent() {
        let rig = Rig(before: [Signal(provider: "stub", entity: "s", phase: .waiting, label: "s", fidelity: .official,
                                      updatedAt: Date(timeIntervalSince1970: 0),
                                      activity: Signal.Activity(waitKind: .approval))])
        defer { rig.panel.close() }
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [])
    }

    func testAWaitOnTheOpenBarIsSilentButItsReminderSpeaks() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.set([("s", .working)])
        rig.controller.openBar()
        rig.set([("s", .waiting)], waitKind: .approval)
        XCTAssertEqual(rig.played, [])
        rig.now += 120
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [.evlat(.bell)], "the reminder is the user's to have asked for")
    }

    /// The reminder speaks once more only where the row is on (the user's
    /// choice); a row off keeps it to a notification.
    func testTheReminderFollowsTheRowsSwitch() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.controller.soundOn[.approval] = false
        rig.set([("s", .working)])
        rig.set([("s", .waiting)], waitKind: .approval)
        rig.now += 120
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [])
    }

    func testOffRemindsOfNothing() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.set([("s", .working)])
        rig.set([("s", .waiting)], waitKind: .approval)
        rig.now += 3600
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [.evlat(.bell)], "the start only")
    }

    // MARK: - Remind again → Everything

    func testAFinishNotLookedAtSpeaksOnceMore() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.controller.nudgeScope = .all
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        XCTAssertEqual(rig.played, [.evlat(.rise)])
        rig.now += 119
        rig.controller.refresh()
        XCTAssertEqual(rig.played.count, 1)
        rig.now += 1
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [.evlat(.rise), .evlat(.rise)])
        rig.now += 600
        rig.controller.refresh()
        XCTAssertEqual(rig.played.count, 2, "once")
    }

    func testAFinishLookedAtIsNotRemindedOf() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.controller.nudgeScope = .all
        rig.set([("s", .working)])
        rig.set([("s", .failed)])
        rig.controller.openBar()
        rig.now += 2
        rig.controller.closeBar()
        rig.now += 300
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [.evlat(.fall)], "seen at the close")
    }

    func testWaitsOnlyRemindsOfNoFinish() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.set([("s", .working)])
        rig.set([("s", .review)])
        rig.now += 300
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [.evlat(.rise)])
    }

    func testAFinishThatCameOnTheOpenBarIsNotRemindedOf() {
        let rig = Rig()
        defer { rig.panel.close() }
        rig.controller.nudgeMinutes = 2
        rig.controller.nudgeScope = .all
        rig.set([("s", .working)])
        rig.controller.openBar()
        rig.set([("s", .review)])
        rig.now += 300
        rig.controller.refresh()
        XCTAssertEqual(rig.played, [])
    }

    func testAWaitThatDidNotSayOnWhatIsAnApproval() {
        XCTAssertEqual(AppController.waitMoment(nil), .approval)
        XCTAssertEqual(AppController.waitMoment(.answer), .answer)
    }

    // MARK: - A character

    private func installPack(in home: URL, lines: [String: [(String, String?)]]) throws {
        let folder = SoundPack.directory(home: home).appendingPathComponent("peon")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        var categories: [String: Any] = [:]
        for (category, files) in lines {
            categories[category] = ["sounds": files.map { file, label -> [String: Any] in
                try? Data(repeating: 1, count: 100).write(to: folder.appendingPathComponent("sounds/\(file)"))
                var entry: [String: Any] = ["file": "sounds/\(file)"]
                if let label { entry["label"] = label }
                return entry
            }]
        }
        let manifest: [String: Any] = ["cesp_version": "1.0", "name": "peon", "display_name": "Peon", "categories": categories]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("openpeon.json"))
    }

    func testACharacterSpeaksItsLinesAndHasNoneWhereItHasNone() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("evlat-sound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try installPack(in: home, lines: ["task.complete": [("done1.wav", "Jobs done!"), ("done2.wav", nil)]])
        let controller = AppController(defaults: nil, home: home)
        var played: [AlertSound] = []
        controller.playSound = { played.append($0) }
        controller.setVoice(.pack("peon"))
        XCTAssertEqual(controller.voicePack?.displayName, "Peon")
        XCTAssertTrue(controller.canSpeak(.done))
        XCTAssertFalse(controller.canSpeak(.failed), "no task.error lines")
        controller.preview(.done)
        controller.preview(.done)
        XCTAssertEqual(played.count, 2)
        XCTAssertNotEqual(played[0], played[1], "never the same line twice in a row")
        controller.preview(.failed)
        XCTAssertEqual(played.count, 2, "nothing to say")
    }

    func testAGoneCharacterSpeaksAsEvlat() {
        let controller = AppController(defaults: nil, home: FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-none-\(UUID().uuidString)"))
        controller.setVoice(.pack("peon"))
        XCTAssertNil(controller.voicePack)
        XCTAssertEqual(controller.sound(for: .done), .evlat(.rise))
    }

    // MARK: - The setting

    func testChoosingAToneStoresAndPlaysIt() {
        let suite = "evlat.tests.sound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppController(defaults: defaults)
        var played: [AlertSound] = []
        controller.playSound = { played.append($0) }
        controller.settingsHost.setTone(.system("Glass"), .done)
        XCTAssertEqual(defaults.string(forKey: SoundMoment.done.toneKey), "system.Glass")
        XCTAssertEqual(controller.settingsHost.tone(.done), .system("Glass"))
        XCTAssertEqual(played, [.system("Glass")])
        controller.settingsHost.setSoundOn(true, .done)
        XCTAssertEqual(defaults.object(forKey: SoundMoment.done.onKey) as? Bool, true)
        controller.settingsHost.setVoice(.pack("peon"))
        XCTAssertEqual(defaults.string(forKey: AppController.soundVoiceKey), "pack.peon")
    }

    /// Nothing stored: finishes are off; waits speak only where the old
    /// reminder rang — on with minutes and its sound — so an upgrade keeps it.
    func testAnUpgradeKeepsTheOldReminderSound() {
        let suite = "evlat.tests.sound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AppController.storedSoundOn(.done, defaults))
        XCTAssertFalse(AppController.storedSoundOn(.approval, defaults), "no reminder, nothing to keep")
        defaults.set(5, forKey: AppController.nudgeKey)
        XCTAssertTrue(AppController.storedSoundOn(.approval, defaults))
        XCTAssertTrue(AppController.storedSoundOn(.answer, defaults))
        XCTAssertFalse(AppController.storedSoundOn(.failed, defaults))
        defaults.set(false, forKey: AppController.nudgeSoundKey)
        XCTAssertFalse(AppController.storedSoundOn(.approval, defaults), "the chime was off")
        XCTAssertEqual(AppController.storedTone(.approval, defaults), .evlat(.bell))
        defaults.set("evlat.nonesuch", forKey: SoundMoment.done.toneKey)
        XCTAssertEqual(AppController.storedTone(.done, defaults), .evlat(.rise), "unknown is the default")
    }

    func testAStoredToneAndVoiceRoundTrip() {
        for tone in [AlertSound.evlat(.kalimba), .system("Ping")] {
            XCTAssertEqual(tone.stored.flatMap(AlertSound.init(stored:)), tone)
        }
        XCTAssertNil(AlertSound.line(URL(fileURLWithPath: "/x.wav")).stored, "a line is never stored")
        XCTAssertNil(AlertSound(stored: "system."))
        XCTAssertEqual(SoundVoice(stored: SoundVoice.pack("peon").stored), .pack("peon"))
        XCTAssertEqual(SoundVoice(stored: nil), .evlat)
        XCTAssertEqual(SoundVoice(stored: "pack."), .evlat)
    }

    // MARK: - Evlat's own sounds

    /// Every sound has a body, reaches the same peak and ends at silence, so
    /// none is louder than another and none clicks at its end.
    func testEverySoundIsWellFormed() {
        for sound in EvlatSound.allCases {
            let samples = Chime.samples(sound)
            XCTAssertGreaterThan(samples.count, Chime.sampleRate / 4, "\(sound)")
            let top = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertEqual(Double(top), 0.45 * Double(Int16.max), accuracy: 2, "\(sound)")
            XCTAssertEqual(samples.last, 0, "\(sound) ends at silence")
            let wav = Chime.wav(sound)
            XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(wav.count, 44 + samples.count * 2)
        }
    }

    /// The bell is the reminder's sound as it always was.
    func testTheBellIsTheFirstChime() {
        let bell = EvlatSound.bell.voice
        XCTAssertEqual(bell.notes.map(\.frequency), [783.99, 1046.50])
        XCTAssertEqual(bell.length, 1.4)
    }
}
