import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// **The character contract** (`MascotContract`), held for every character
/// Evlat ships and for the test characters that use what the shipped ones
/// do not yet — and each of its rules shown to catch the break it names.
final class MascotCharacterContractTests: XCTestCase {
    private var characters: [MascotCharacter] { MascotCharacters.all + [MascotTestCharacters.lantern] }

    /// Every clip a character can play: its five phases and its own motions.
    private func clips(of character: MascotCharacter) -> [(name: String, clip: MascotClip)] {
        Phase.allCases.map { ($0.rawValue, character.clip(for: $0, pacing: .normal)) }
            + character.motions.sorted { $0.key < $1.key }.map { ("motion \($0.key)", $0.value) }
    }

    func testIdsAreUniqueAndTheDefaultIsListed() {
        let ids = characters.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "\(ids)")
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(MascotCharacters.all.contains(MascotCharacters.default))
    }

    /// Every character keeps every rule of the contract (`MascotContract`) —
    /// the same check the library runs on a character found on disk.
    func testEveryCharacterKeepsTheContract() {
        for character in characters {
            XCTAssertEqual(MascotContract.violations(of: character), [], character.id)
        }
    }

    /// Evlat's clips are the default every character may play: they know no
    /// character's own controls.
    func testEvlatsClipsSetNoOwnControls() {
        for phase in Phase.allCases {
            XCTAssertTrue(MascotClip.clip(for: phase, pacing: .normal).steps.allSatisfy { $0.pose.own.isEmpty },
                          "\(phase): Evlat's clips know no character's own controls")
        }
    }

    /// Each rule catches what it is there for: a character broken one way is
    /// told so, and by the rule that names it.
    func testEachRuleCatchesItsBreak() {
        let lantern = MascotTestCharacters.lantern
        let glow = MascotTestCharacters.glow
        let still = MascotPose.resting(for: .idle)
        func with(rig: MascotRig? = nil, states: [Phase: MascotClip]? = nil, motions: [String: MascotClip]? = nil,
                  rules: [MascotRule]? = nil) -> MascotCharacter {
            MascotCharacter(id: "broken", rig: rig ?? lantern.rig,
                            states: lantern.states.merging(states ?? [:]) { $1 },
                            motions: motions ?? lantern.motions,
                            behavior: rules.map { MascotBehavior(rules: $0) } ?? lantern.behavior)
        }
        func rig(adding part: MascotPart) -> MascotRig {
            var rig = lantern.rig
            rig.root.children.append(part)
            return rig
        }
        let once = MascotClip(steps: [.entering(still, hold: 1)], loops: false)
        let cases: [(String, MascotCharacter)] = [
            ("share a name", with(rig: rig(adding: MascotPart(name: "body")))),
            ("is not declared", with(rig: rig(adding: MascotPart(
                name: "typo", bindings: [MascotBinding(MascotControl("bulb.glw"), .opacity, from: (0, 1), to: (0, 1))])))),
            ("no input range", with(rig: rig(adding: MascotPart(
                name: "flat", bindings: [MascotBinding(.yaw, .offsetX, from: (1, 1), to: (0, 1))])))),
            ("is outside its range", with(states: [.waiting: MascotClip(steps: [
                .entering(MascotTestCharacters.waitingRest.setting(glow, to: 2), hold: 1)], loops: false)])),
            ("holds 0", with(states: [.waiting: MascotClip(steps: [.entering(still, hold: 0)], loops: false)])),
            ("does not enter on the shared spring", with(states: [.review: MascotClip(steps: [
                .eased(MascotPose.resting(for: .review), over: 0.2, hold: 1)], loops: false)])),
            ("seam is a jump", with(states: [.idle: MascotClip(steps: [
                .entering(still, hold: 4), .eased(still.scaled(by: 1.05), over: 0.4, hold: 1)], loops: true)])),
            ("over 0.35", with(states: [.idle: MascotClip(steps: [
                .entering(still, hold: 1), .eased(still.scaled(by: 1.05), over: 0.5, hold: 0.5),
                .eased(still, over: 0.5, hold: 0.5)], loops: true)])),
            ("rests tilted", with(states: [.review: MascotClip(steps: [
                .entering(MascotPose(tilt: 9), hold: 1)], loops: false)])),
            ("rest alike", with(states: [.review: MascotClip(steps: [
                .entering(MascotTestCharacters.waitingRest, hold: 1)], loops: false)])),
            ("motion once loops", with(motions: ["once": MascotClip(steps: once.steps, loops: true)])),
            ("no gesture", with(rules: [MascotRule(phase: .waiting, after: 1, play: [.init("nothing")])])),
            ("ends off waiting's rest", with(rules: [MascotRule(phase: .waiting, after: 1, play: [.init("flicker")])])),
            ("cut the phase change's spring short", with(rules: [
                MascotRule(phase: .working, after: 0, play: [.init("flicker")])])),
            ("of the time with its phase", with(rules: [
                MascotRule(phase: .working, after: 1, every: 1, play: [.init("flicker")])]))
        ]
        for (fragment, character) in cases {
            let found = MascotContract.violations(of: character)
            XCTAssertTrue(found.contains { $0.contains(fragment) }, "\(fragment): \(found)")
        }
    }

    /// **A character without rules is never asked**, so it draws exactly as
    /// before rules existed: whatever the phase, the time and the sessions,
    /// its behavior plays nothing and asks to be woken for nothing.
    func testACharacterWithoutRulesDecidesNothing() {
        for character in characters where character.behavior.isEmpty {
            for phase in Phase.allCases {
                for seconds in [0.0, 1, 59, 60, 600, 86_400] {
                    for sessions in [MascotContext.Sessions(), .init(waiting: 3, working: 2, news: 4)] {
                        let decision = character.behavior.decide(
                            MascotContext(phase: phase, secondsInPhase: seconds, sessions: sessions),
                            memory: .init(), random: { 0.5 })
                        XCTAssertNil(decision.motion, "\(character.id) \(phase)")
                        XCTAssertNil(decision.wake, "\(character.id) \(phase)")
                    }
                }
            }
        }
        XCTAssertTrue(MascotCharacters.default.behavior.isEmpty, "the cube has no rules")
    }

    /// A phase the character plays its own way is its clip; the measurement
    /// variant of it is that clip with the waiting taken out, as Evlat's are.
    func testAnOwnPhaseReplacesEvlatsClip() {
        let lantern = MascotTestCharacters.lantern
        XCTAssertEqual(lantern.clip(for: .waiting, pacing: .normal), MascotTestCharacters.waiting)
        XCTAssertEqual(lantern.clip(for: .waiting, pacing: .continuous), MascotTestCharacters.waiting.continuous)
        XCTAssertEqual(lantern.clip(for: .idle, pacing: .normal), MascotClip.clip(for: .idle, pacing: .normal),
                       "a phase it does not write plays Evlat's clip")
    }

    /// An own control a pose does not set rests where the rig says; one it
    /// sets is read; a name the rig never declared drives nothing.
    func testAnOwnControlRestsUntilAClipSetsIt() {
        let rig = MascotTestCharacters.lantern.rig
        let glow = MascotTestCharacters.glow
        XCTAssertEqual(rig.value(of: glow, in: MascotPose()), 0.3)
        XCTAssertEqual(rig.value(of: glow, in: MascotPose().setting(glow, to: 0.9)), 0.9)
        XCTAssertNil(rig.value(of: MascotControl("nobody"), in: MascotPose()))
        XCTAssertEqual(rig.value(of: .eyeOpen, in: MascotPose(eyeOpen: 0.4)), 0.4)
    }

    /// Every character draws something in every phase at the bar's size.
    @MainActor
    func testEveryCharacterDrawsInEveryPhase() throws {
        for character in characters {
            for phase in Phase.allCases {
                let view = MascotBody(pose: character.resting(for: phase), size: AppController.mascotSize,
                                      rig: character.rig)
                    .frame(width: AppController.mascotSize, height: AppController.mascotSize)
                let image = try XCTUnwrap(ImageRenderer(content: view).cgImage, "\(character.id) \(phase)")
                XCTAssertGreaterThan(Self.inkedPixels(image), 0, "\(character.id) \(phase): nothing drawn")
            }
        }
    }

    private static func inkedPixels(_ image: CGImage) -> Int {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: data.count, by: 4).filter { data[$0] > 0 }.count
    }
}
