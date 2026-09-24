import XCTest
import EvlatCore
@testable import EvlatApp

/// The string catalogue. Every failure here is silent in the field: a key
/// missing from one table shows the key itself on the bar, and only in that
/// language.
final class L10nTests: XCTestCase {
    private var catalog: Catalog { L10n.catalog }

    func testBothTablesAreFoundAndCarryTheSameKeys() {
        let en = catalog.tables["en"] ?? [:]
        let tr = catalog.tables["tr"] ?? [:]
        XCTAssertFalse(en.isEmpty, "the source table was not found under \(String(describing: L10n.root()))")
        XCTAssertFalse(tr.isEmpty, "the Turkish table was not found")
        XCTAssertEqual(Set(en.keys).subtracting(tr.keys), [], "keys missing from tr")
        XCTAssertEqual(Set(tr.keys).subtracting(en.keys), [], "keys missing from en")
    }

    /// Every key the code can ask for is in the table. The keys are literals
    /// in one table per kind (`StatusLine`), so iterating the cases reaches
    /// all of them — a grep for `L10n.t("` would miss a key built in a switch.
    func testEveryKeyTheStatusLineAsksForExists() {
        var keys = [StatusLine.lineKey, StatusLine.justNowKey]
        keys += StatusLine.Unit.allCases.map(\.key)
        for phase in Phase.allCases {
            keys.append(StatusLine.statusKey(phase: phase, waitKind: nil))
        }
        keys.append(StatusLine.statusKey(phase: .waiting, waitKind: .approval))
        keys.append(StatusLine.statusKey(phase: .waiting, waitKind: .answer))
        keys += Signal.Machine.Reason.allCases.map(StatusLine.dimKey)
        for lang in ["en", "tr"] {
            for key in keys {
                XCTAssertNotNil(catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }

    func testEveryKeyTheSummaryAsksForExists() {
        for lang in ["en", "tr"] {
            for key in SummaryLine.keys {
                XCTAssertNotNil(catalog.tables[lang]?[key], "\(lang) has no \(key)")
            }
        }
    }

    /// "{n} sessions · {k} working": with nothing working the second part is
    /// gone, with no session the line is.
    func testTheSummaryLine() {
        func rows(_ phases: [Phase]) -> [SessionRow] {
            phases.enumerated().map { SessionRow(entity: "e\($0.offset)", label: "x", phase: $0.element) }
        }
        XCTAssertNil(SummaryLine.text(rows: [], in: "tr"))
        XCTAssertEqual(SummaryLine.text(rows: rows([.idle, .idle, .review]), in: "tr"), "3 oturum")
        XCTAssertEqual(SummaryLine.text(rows: rows([.idle]), in: "en"), "1 session")
        XCTAssertEqual(SummaryLine.text(rows: rows([.working, .waiting, .idle]), in: "en"),
                       "3 sessions · 1 working", "waiting is not working")
        XCTAssertEqual(SummaryLine.text(rows: rows(Array(repeating: .idle, count: 17)
                                                   + [.working, .working, .working]), in: "tr"),
                       "20 oturum · 3 çalışıyor")
        let dimmed = SessionRow(entity: "far", label: "x", phase: .working, machine: "devbox",
                                dim: Signal.Machine.Dim(reason: .quiet, since: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(SummaryLine.text(rows: rows([.working]) + [dimmed], in: "en"),
                       "2 sessions · 1 working", "a dimmed row is listed, not counted as working")
    }

    func testAMissingKeyReturnsItself() {
        XCTAssertEqual(L10n.t("no.such.key", in: "tr"), "no.such.key")
    }

    func testTurkishReadsWithItsAccents() {
        XCTAssertEqual(L10n.t("status.working", in: "tr"), "çalışıyor")
        XCTAssertEqual(L10n.t("status.waiting.approval", in: "tr"), "onay bekliyor")
    }

    func testPlaceholdersAreFilled() {
        XCTAssertEqual(L10n.t("time.minutes", ["count": "14"], in: "tr"), "14 dk")
        XCTAssertEqual(Catalog.fill("{a} and {b}", ["a": "x"]), "x and {b}",
                       "an unfilled placeholder stays visible")
    }

    /// A language with no table falls back to the source one, which is listed
    /// first: `Bundle.preferredLocalizations` returns the first entry when
    /// nothing matches.
    func testTheLanguageFallsBackToTheSource() {
        XCTAssertEqual(catalog.available.first, "en")
        XCTAssertEqual(catalog.resolve(preferred: ["de-DE"]), "en")
        XCTAssertEqual(catalog.resolve(preferred: ["tr-TR"]), "tr")
    }
}

/// The grey line under each name: "working · 14 min". A pure function of the
/// phase, the wait kind, when the phase was entered and the time now, so the
/// minute tick only has to hand it a date.
final class StatusLineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func line(_ phase: Phase, _ kind: Signal.Activity.WaitKind? = nil,
                      after seconds: TimeInterval?, in lang: String = "en") -> String {
        StatusLine.text(phase: phase, waitKind: kind,
                        enteredAt: seconds == nil ? nil : t0,
                        now: t0.addingTimeInterval(seconds ?? 0), in: lang)
    }

    func testTheBoundaries() {
        XCTAssertEqual(line(.working, after: 0), "working · just now")
        XCTAssertEqual(line(.working, after: 59), "working · just now")
        XCTAssertEqual(line(.working, after: 60), "working · 1 min")
        XCTAssertEqual(line(.working, after: 59 * 60 + 59), "working · 59 min")
        XCTAssertEqual(line(.working, after: 3600), "working · 1 h")
        XCTAssertEqual(line(.working, after: 86_399), "working · 23 h")
        XCTAssertEqual(line(.working, after: 86_400), "working · 1 d")
    }

    func testAClockBehindTheStampReadsAsJustNow() {
        XCTAssertEqual(line(.idle, after: -30), "idle · just now")
    }

    /// No observed entry — the row was first seen in this phase — means no
    /// duration: how long it has been so is not known, and nothing is invented.
    func testNoEntryMeansNoDuration() {
        XCTAssertEqual(line(.review, after: nil), "done")
        XCTAssertEqual(line(.review, after: nil, in: "tr"), "bitti")
    }

    func testTheTwoWaitKindsAreTwoWords() {
        XCTAssertEqual(line(.waiting, .approval, after: 120, in: "tr"), "onay bekliyor · 2 dk")
        XCTAssertEqual(line(.waiting, .answer, after: 120, in: "tr"), "yanıt bekliyor · 2 dk")
        XCTAssertNotEqual(line(.waiting, .approval, after: nil), line(.waiting, .answer, after: nil))
        // A file row can wait with no hook having said on what.
        XCTAssertEqual(line(.waiting, nil, after: nil, in: "tr"), "bekliyor")
    }

    /// The open body is fitted to the widest the line can get, so the body
    /// does not move as the minutes pass.
    func testTheWidestFormIsAtLeastAsWideAsAnyReading() {
        let widest = SessionColumn.statusWidth(phase: .working, waitKind: nil, in: "en")
        for seconds: TimeInterval in [0, 60, 59 * 60, 23 * 3600, 99 * 86_400] {
            let text = line(.working, after: seconds)
            let width = (text as NSString).size(withAttributes: [.font: SessionColumn.statusFont]).width
            XCTAssertLessThanOrEqual(ceil(width), widest, text)
        }
    }
}
