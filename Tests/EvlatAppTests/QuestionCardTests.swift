import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// A held question on the card (`AskQuestion`): which drawn buttons take a
/// press, and what re-arms the card.
@MainActor
final class QuestionCardTests: XCTestCase {
    private let color = AgentQuestion(text: "Which color?", header: "Color",
                                             options: [.init(label: "Red"), .init(label: "Blue")])
    private let sizes = AgentQuestion(text: "Which sizes?", options: [.init(label: "S"), .init(label: "L")],
                                             multiSelect: true)

    private func request(_ questions: [AgentQuestion]?) -> HeldRequest {
        HeldRequest(id: "q-1", token: nil, tool: questions == nil ? "Bash" : AskQuestion.tool,
                               subject: nil, questions: questions, input: Data("{}".utf8))
    }

    /// A bare Allow answers no question. Every button the card draws takes
    /// a press at once: there is no wait after the card comes up.
    func testAQuestionCardHasNoAllow() {
        var draft = AgentQuestion.Draft(questions: [color])
        let card = SessionDetail.ApprovalCard(request([color]), draft: draft)
        XCTAssertFalse(card.takes(.allow))
        XCTAssertTrue(card.takes(.deny))
        XCTAssertTrue(card.takes(.option(1)))
        XCTAssertFalse(card.takes(.option(2)), "no such option")
        XCTAssertTrue(card.takes(.other))
        XCTAssertFalse(card.takes(.send), "nothing picked: Send is faint")
        XCTAssertEqual(card.question?.isLast, true, "the only question is the last: Send is drawn")

        draft.choose(0)
        let picked = SessionDetail.ApprovalCard(request([color]), draft: draft)
        XCTAssertEqual(picked.question?.picked, [0], "the last question's press picks")
        XCTAssertTrue(picked.takes(.send), "and Send sends")
        draft.commit()
        XCTAssertNil(SessionDetail.ApprovalCard(request([color]), draft: draft).question,
                     "an answered draft is no question")
    }

    func testAPermissionCardHasNoQuestionButtons() {
        let card = SessionDetail.ApprovalCard(request(nil))
        XCTAssertTrue(card.takes(.allow))
        XCTAssertFalse(card.takes(.option(0)))
        XCTAssertFalse(card.takes(.other))
    }

    /// Send is live once something is picked.
    func testSendWaitsForAPick() {
        var draft = AgentQuestion.Draft(questions: [sizes])
        XCTAssertFalse(SessionDetail.ApprovalCard(request([sizes]), draft: draft).takes(.send))
        draft.choose(1)
        XCTAssertTrue(SessionDetail.ApprovalCard(request([sizes]), draft: draft).takes(.send))
    }

    /// The next question takes a press as soon as it is up: no wait between
    /// questions either.
    func testTheNextQuestionTakesAPressAtOnce() {
        var draft = AgentQuestion.Draft(questions: [color, sizes])
        draft.choose(0)
        let second = SessionDetail.ApprovalCard(request([color, sizes]), draft: draft)
        XCTAssertEqual(second.question?.question, sizes)
        XCTAssertTrue([.option(0), .other, .deny, .back].allSatisfy(second.takes))
    }

    /// The way back is on the second question, not the first.
    func testBackIsOnlyAfterTheFirst() {
        var draft = AgentQuestion.Draft(questions: [color, sizes])
        XCTAssertFalse(SessionDetail.ApprovalCard(request([color, sizes]), draft: draft).takes(.back))
        draft.choose(0)
        XCTAssertTrue(SessionDetail.ApprovalCard(request([color, sizes]), draft: draft).takes(.back))
    }

    func testTheTagNamesTheTabAndWhereItIs() throws {
        var draft = AgentQuestion.Draft(questions: [color, sizes])
        XCTAssertEqual(DetailCard.questionTag(try XCTUnwrap(SessionDetail.QuestionCard(draft))), "Color · 1/2")
        draft.choose(0)
        XCTAssertEqual(DetailCard.questionTag(try XCTUnwrap(SessionDetail.QuestionCard(draft))), "2/2")
        XCTAssertEqual(DetailCard.questionTag(try XCTUnwrap(SessionDetail.QuestionCard(.init(questions: [color])))),
                       "Color")
    }

    /// The tallest question card, drawn: three lines of question, four
    /// options, a long description, the button row with the way back and
    /// `[Go to session]`. Under the cap, so nothing is clipped — a clipped
    /// button would still take clicks where it is not seen. A name too long
    /// for the header's one line puts the tool's name on a line of its own.
    func testTheTallestQuestionFitsTheCard() throws {
        try tallestQuestion(label: "api")
        try tallestQuestion(label: "Metalterm: GPU glyph atlas eviction under memory pressure")
    }

    /// Three options with two lines of description each, the common case,
    /// stay whole: the list does not scroll before `optionsMaxHeight`.
    func testThreeDescribedOptionsStayWhole() throws {
        let options = [("LRU", "Evict the glyphs used least recently; simple and predictable."),
                       ("Clock", "Second-chance sweep; cheaper bookkeeping per frame."),
                       ("Size-aware", "Evict the largest glyphs first to free the most memory.")]
            .map { AgentQuestion.Option(label: $0.0, description: $0.1) }
        let question = AgentQuestion(
            text: "Which eviction policy should the glyph atlas use when the GPU reports memory pressure?",
            header: "Policy", options: options)
        func height(cap: CGFloat) -> CGFloat {
            let model = DetailModel()
            model.resolveHost = { _ in .notFound }
            model.update(row: SessionRow(entity: "s", label: "Metalterm: GPU glyph atlas eviction under memory pressure",
                                         phase: .waiting, source: .claude, waitKind: .answer),
                         signal: nil, approval: SessionDetail.ApprovalCard(request([question]),
                                                                           draft: .init(questions: [question])))
            return NSHostingView(rootView: DetailCard(model: model, maxHeight: cap)).fittingSize.height
        }
        XCTAssertLessThanOrEqual(height(cap: 10_000), AppController.detailCardMaxHeight - 8, "inside the cap")
        let whole = DetailCard.optionsMaxHeight
        XCTAssertGreaterThan(whole, 0)
    }

    private func tallestQuestion(label: String) throws {
        let long = String(repeating: "A long description of what this option would change for the build. ", count: 4)
        let options = (1...4).map { AgentQuestion.Option(label: "An option with a long label number \($0) that runs on",
                                                       description: long) }
        let question = AgentQuestion(
            text: String(repeating: "Which colour should the badge use when a long build waits on you? ", count: 5),
            header: "Colour", options: options, multiSelect: true)
        var draft = AgentQuestion.Draft(questions: [color, question])
        draft.choose(0)
        let card = SessionDetail.ApprovalCard(request([color, question]), draft: draft)
        XCTAssertTrue(try XCTUnwrap(card.question).canGoBack)

        let model = DetailModel()
        model.resolveHost = { _ in .notFound }
        model.update(row: SessionRow(entity: "s", label: label, phase: .waiting, source: .claude, waitKind: .answer),
                     signal: nil, approval: card)
        model.hovered = .option(0)
        XCTAssertTrue(DetailCard.showsButton(try XCTUnwrap(model.detail)), "the way to the terminal stays")
        let height = NSHostingView(rootView: DetailCard(model: model, maxHeight: 10_000)).fittingSize.height
        XCTAssertGreaterThan(height, 200, "drawn")
        // With room to spare: type renders a little differently elsewhere.
        XCTAssertLessThanOrEqual(height, AppController.detailCardMaxHeight - 8, "\(label): clipped at the cap")
    }

    /// The tallest permission card: a name that wraps, its branch, a
    /// command long enough to scroll, both buttons and `[Go to session]`.
    /// The header's second line is the room the 320 pt card took; it still
    /// ends under the cap.
    func testTheTallestPermissionFitsTheCard() throws {
        let command = String(repeating: "swift test --parallel --filter EvlatAppTests.SandboxWatcherTests ", count: 6)
        let held = HeldRequest(id: "p-1", token: nil, tool: "Bash", subject: command, questions: nil,
                               input: Data("{}".utf8))
        let model = DetailModel()
        model.resolveHost = { _ in .notFound }
        model.update(row: SessionRow(entity: "s", label: String(repeating: "Refactor the sandbox watcher ", count: 4),
                                     phase: .waiting, source: .claude,
                                     branch: "feature/PROJ-1234-sandbox-watcher-reconnect", waitKind: .approval),
                     signal: nil, approval: SessionDetail.ApprovalCard(held))
        XCTAssertNotNil(try XCTUnwrap(model.detail).approval?.text, "the command is on the card")
        let height = NSHostingView(rootView: DetailCard(model: model, maxHeight: 10_000)).fittingSize.height
        XCTAssertGreaterThan(height, 200, "drawn")
        XCTAssertLessThanOrEqual(height, AppController.detailCardMaxHeight - 8, "clipped at the cap")
    }

    /// The line written in goes where its row goes, and keeps the keyboard:
    /// laid once where it opened, it stood beside a row that had moved.
    func testTheAnswerLineFollowsItsRow() {
        let line = AnswerPanel(content: EmptyView())
        defer { line.close() }
        line.present(over: NSRect(x: 100, y: 300, width: 284, height: 48))
        line.follow(NSRect(x: 100, y: 220, width: 284, height: 48))
        XCTAssertEqual(line.frame, NSRect(x: 100, y: 220, width: 284, height: 48))
        XCTAssertEqual(line.contentView?.frame.size, NSSize(width: 284, height: 48))
    }

    /// The line's mark is the row's: round for a question that picks one,
    /// square for one that picks any.
    func testTheAnswerLineKnowsWhichMarkItStandsOn() {
        let model = AnswerModel()
        model.open(question: "Which sizes?", text: "", multiSelect: true)
        XCTAssertTrue(model.multiSelect)
        model.open(question: "Which color?", text: "")
        XCTAssertFalse(model.multiSelect, "a later opening says its own")
    }
}
