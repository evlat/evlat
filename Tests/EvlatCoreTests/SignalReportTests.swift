import XCTest
@testable import EvlatCore

/// The body of `POST /signal`: what an outside program may say, and how much
/// of it survives. Every rule here is a limit on a sender Evlat does not know.
final class SignalReportTests: XCTestCase {
    private func parse(_ body: [String: Any]) -> Result<SignalReport, SignalReport.Rejection> {
        SignalReport.parse(json: body)
    }

    private func report(_ body: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> SignalReport? {
        switch parse(body) {
        case .success(let report): return report
        case .failure(let rejection):
            XCTFail("rejected: \(rejection.code)", file: file, line: line)
            return nil
        }
    }

    private func code(_ body: [String: Any]) -> String? {
        if case .failure(let rejection) = parse(body) { return rejection.code }
        return nil
    }

    // MARK: - The fields

    func testAFullBodyIsRead() {
        let report = report(["id": "build-1", "ttl": 180, "phase": "working", "label": "npm run build",
                             "progress": 0.4, "detail": "~/code/app", "sender": "npm"])
        XCTAssertEqual(report?.id, "build-1")
        XCTAssertEqual(report?.ttl, 180)
        XCTAssertEqual(report?.word, .working)
        XCTAssertEqual(report?.label, "npm run build")
        XCTAssertEqual(report?.progress, 0.4)
        XCTAssertEqual(report?.detail, "~/code/app")
        XCTAssertEqual(report?.sender, "npm")
    }

    /// `done` is the bar's `review`: "just finished", the green glow. The word
    /// stays as the sender said it.
    func testThePhaseWordsMapOntoTheExistingPhases() {
        let expected: [(String, Phase)] = [("working", .working), ("waiting", .waiting),
                                           ("done", .review), ("failed", .failed)]
        for (word, phase) in expected {
            let report = report(["id": "x", "ttl": 60, "phase": word])
            XCTAssertEqual(report?.word?.phase, phase, word)
            XCTAssertEqual(report?.word?.rawValue, word)
        }
        // `idle` is not offered: a row that says it is doing nothing has no
        // place on the bar.
        for word in ["idle", "review", "Working", "", "busy"] {
            XCTAssertEqual(code(["id": "x", "ttl": 60, "phase": word]), "invalidPhase", word)
        }
        XCTAssertEqual(code(["id": "x", "ttl": 60]), "invalidPhase", "a live row needs a phase")
        XCTAssertEqual(code(["id": "x", "ttl": 60, "phase": 1]), "invalidPhase")
    }

    // MARK: - id

    func testTheIDIsAShortASCIIName() {
        for id in ["a", "build-1", "watch-4242", "A.b_c-9", String(repeating: "x", count: 64)] {
            XCTAssertEqual(report(["id": id, "ttl": 0])?.id, id, id)
        }
        for id in ["", String(repeating: "x", count: 65), "a b", "a/b", "a:b", "ç", "a\u{202E}b", "é"] {
            XCTAssertEqual(code(["id": id, "ttl": 0]), "invalidId", id)
        }
        XCTAssertEqual(code(["ttl": 0]), "invalidId", "missing")
        XCTAssertEqual(code(["id": 7, "ttl": 0]), "invalidId", "not a string")
    }

    // MARK: - ttl

    func testTheTTLIsAWholeNumberOfSecondsUpToADay() {
        XCTAssertEqual(report(["id": "x", "ttl": 86400, "phase": "working"])?.ttl, 86400)
        XCTAssertEqual(report(["id": "x", "ttl": 60.0, "phase": "working"])?.ttl, 60, "an integral double")
        for ttl: Any in [86401, -1, 1.5, "60", true, false, Double.infinity, NSNull()] {
            XCTAssertEqual(code(["id": "x", "ttl": ttl, "phase": "working"]), "invalidTtl", "\(ttl)")
        }
        XCTAssertEqual(code(["id": "x", "phase": "working"]), "invalidTtl", "missing")
    }

    /// A finished row needs no day on the bar, and a `done` kept for 24 h
    /// would keep the mascot awake for 24 h: it is cut, not refused.
    func testAFinishedRowLivesAnHourAtMost() {
        XCTAssertEqual(report(["id": "x", "ttl": 86400, "phase": "done"])?.ttl, 3600)
        XCTAssertEqual(report(["id": "x", "ttl": 86400, "phase": "failed"])?.ttl, 3600)
        XCTAssertEqual(report(["id": "x", "ttl": 600, "phase": "done"])?.ttl, 600)
        XCTAssertEqual(report(["id": "x", "ttl": 86400, "phase": "waiting"])?.ttl, 86400)
    }

    /// `ttl: 0` removes the row and reads nothing else: not even a phase.
    func testAZeroTTLNeedsNoPhase() {
        let report = report(["id": "x", "ttl": 0])
        XCTAssertEqual(report?.ttl, 0)
        XCTAssertNil(report?.word)
        XCTAssertEqual(self.report(["id": "x", "ttl": 0, "phase": "nonsense"])?.word, nil)
    }

    // MARK: - progress

    func testProgressIsAFiniteFraction() {
        XCTAssertEqual(report(["id": "x", "ttl": 60, "phase": "working", "progress": 0])?.progress, 0)
        XCTAssertEqual(report(["id": "x", "ttl": 60, "phase": "working", "progress": 1])?.progress, 1)
        XCTAssertNil(report(["id": "x", "ttl": 60, "phase": "working"])?.progress)
        XCTAssertNil(report(["id": "x", "ttl": 60, "phase": "working", "progress": NSNull()])?.progress,
                     "null is absent")
        for progress: Any in [1.01, -0.01, Double.nan, Double.infinity, "0.4", true] {
            XCTAssertEqual(code(["id": "x", "ttl": 60, "phase": "working", "progress": progress]),
                           "invalidProgress", "\(progress)")
        }
    }

    // MARK: - Text

    /// Long text is cut at the limit rather than refused: a label that is a
    /// little long is not the sender's mistake worth failing a build over.
    /// The limit counts characters as they are seen, not bytes.
    func testTextIsCutAtItsLimit() {
        let long = String(repeating: "é", count: 300)
        let report = report(["id": "x", "ttl": 60, "phase": "working",
                             "label": long, "detail": long, "sender": long])
        XCTAssertEqual(report?.label.count, SignalReport.labelLimit)
        XCTAssertEqual(report?.detail?.count, SignalReport.detailLimit)
        XCTAssertEqual(report?.sender?.count, SignalReport.senderLimit)
        XCTAssertEqual(SignalReport.labelLimit, 80)
        XCTAssertEqual(SignalReport.detailLimit, 200)
        XCTAssertEqual(SignalReport.senderLimit, 24)
        let flags = String(repeating: "🇹🇷", count: 30)
        XCTAssertEqual(self.report(["id": "x", "ttl": 60, "phase": "working", "sender": flags])?.sender,
                       String(repeating: "🇹🇷", count: 24), "a flag is one character")
    }

    /// Control and format characters are dropped — bidi overrides among
    /// them, which would let a label draw itself backwards over its
    /// neighbours. A line break becomes a space; the ends are trimmed.
    func testControlAndFormatCharactersAreDropped() {
        let report = report(["id": "x", "ttl": 60, "phase": "working",
                             "label": "  build\u{202E}gnp.exe\u{0007}\u{200B}\n done \r\n",
                             "detail": "a\tb\u{2028}c\u{0000}d",
                             "sender": "\u{FEFF}npm\u{2066}"])
        XCTAssertEqual(report?.label, "buildgnp.exe  done")
        XCTAssertEqual(report?.detail, "a b cd")
        XCTAssertEqual(report?.sender, "npm")
    }

    /// Cut after cleaning, and trimmed after cutting: a label never ends in
    /// the space its limit happened to land on.
    func testTheCutIsTrimmed() {
        let label = String(repeating: "a", count: 79) + " b"
        XCTAssertEqual(report(["id": "x", "ttl": 60, "phase": "working", "label": label])?.label,
                       String(repeating: "a", count: 79))
    }

    func testAnEmptyLabelFallsBackToTheID() {
        XCTAssertEqual(report(["id": "x", "ttl": 60, "phase": "working"])?.label, "x")
        XCTAssertEqual(report(["id": "x", "ttl": 60, "phase": "working", "label": " \u{202E}\n"])?.label, "x")
        XCTAssertNil(report(["id": "x", "ttl": 60, "phase": "working", "detail": "  ", "sender": "\u{200B}"])?.sender)
        XCTAssertNil(report(["id": "x", "ttl": 60, "phase": "working", "detail": "  "])?.detail)
    }

    func testTextThatIsNotAStringIsRefused() {
        XCTAssertEqual(code(["id": "x", "ttl": 60, "phase": "working", "label": 3]), "invalidLabel")
        XCTAssertEqual(code(["id": "x", "ttl": 60, "phase": "working", "detail": ["a"]]), "invalidDetail")
        XCTAssertEqual(code(["id": "x", "ttl": 60, "phase": "working", "sender": false]), "invalidSender")
        XCTAssertNotNil(report(["id": "x", "ttl": 60, "phase": "working", "label": NSNull()]), "null is absent")
    }

    // MARK: - Identity

    /// The identity is the server's to write. A body that names a provider, an
    /// entity, a fidelity or a kind is read as if it had not: the sender
    /// cannot choose a session's id or an internal provider's name.
    func testTheBodyCannotChooseItsIdentity() {
        let report = report(["id": "x", "ttl": 60, "phase": "working",
                             "provider": "claude-sessions", "entity": "s-1",
                             "fidelity": "official", "kind": "session"])
        let signal = report?.signal(phaseStart: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(signal?.provider, "signal")
        XCTAssertEqual(signal?.entity, "signal:x")
        XCTAssertEqual(signal?.kind, .custom)
        XCTAssertEqual(signal?.fidelity, .manual)
        XCTAssertEqual(signal?.rawStatus, "working")
    }

    func testTheSignalCarriesTheReport() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let signal = report(["id": "x", "ttl": 60, "phase": "done", "label": "render",
                             "progress": 1, "detail": "scene-3", "sender": "blender"])?
            .signal(phaseStart: start)
        XCTAssertEqual(signal?.phase, .review)
        XCTAssertEqual(signal?.rawStatus, "done")
        XCTAssertEqual(signal?.label, "render")
        XCTAssertEqual(signal?.progress, 1)
        XCTAssertEqual(signal?.detail, "scene-3")
        XCTAssertEqual(signal?.sender, "blender")
        XCTAssertEqual(signal?.updatedAt, start, "the stamp is when the phase began")
        XCTAssertNil(signal?.source, "not an agent's")
        XCTAssertNil(signal?.machine)
    }

    /// Every rejection has a stable code and an English message.
    func testEveryRejectionHasACode() {
        for rejection in SignalReport.Rejection.allCases {
            XCTAssertFalse(rejection.code.isEmpty)
            XCTAssertFalse(rejection.message.isEmpty)
        }
    }
}
