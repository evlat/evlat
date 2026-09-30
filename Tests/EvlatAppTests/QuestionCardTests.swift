import XCTest
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// A held question on the card (`AskQuestion`): which drawn buttons take a
/// press, and what re-arms the card.
@MainActor
final class QuestionCardTests: XCTestCase {
    private let color = AskQuestion.Question(text: "Which color?", header: "Color",
                                             options: [.init(label: "Red"), .init(label: "Blue")])
    private let sizes = AskQuestion.Question(text: "Which sizes?", options: [.init(label: "S"), .init(label: "L")],
                                             multiSelect: true)

    private func request(_ questions: [AskQuestion.Question]?) -> PermissionHook.Request {
        PermissionHook.Request(id: "q-1", token: nil, tool: questions == nil ? "Bash" : AskQuestion.tool,
                               subject: nil, questions: questions, input: Data("{}".utf8))
    }

    /// A bare Allow answers no question; a faint card takes nothing.
    func testAQuestionCardHasNoAllow() {
        var draft = AskQuestion.Draft(questions: [color])
        let card = SessionDetail.ApprovalCard(request([color]), draft: draft, armed: true)
        XCTAssertFalse(card.takes(.allow))
        XCTAssertTrue(card.takes(.deny))
        XCTAssertTrue(card.takes(.option(1)))
        XCTAssertFalse(card.takes(.option(2)), "no such option")
        XCTAssertTrue(card.takes(.other))
        XCTAssertFalse(card.takes(.send), "a single-select question has no Send")
        let faint = SessionDetail.ApprovalCard(request([color]), draft: draft, armed: false)
        XCTAssertFalse([.deny, .option(0), .other].contains(where: faint.takes))

        draft.choose(0)
        XCTAssertNil(SessionDetail.ApprovalCard(request([color]), draft: draft, armed: true).question,
                     "an answered draft is no question")
    }

    func testAPermissionCardHasNoQuestionButtons() {
        let card = SessionDetail.ApprovalCard(request(nil), armed: true)
        XCTAssertTrue(card.takes(.allow))
        XCTAssertFalse(card.takes(.option(0)))
        XCTAssertFalse(card.takes(.other))
    }

    /// Send is live once something is picked.
    func testSendWaitsForAPick() {
        var draft = AskQuestion.Draft(questions: [sizes])
        XCTAssertFalse(SessionDetail.ApprovalCard(request([sizes]), draft: draft, armed: true).takes(.send))
        draft.choose(1)
        XCTAssertTrue(SessionDetail.ApprovalCard(request([sizes]), draft: draft, armed: true).takes(.send))
    }

    /// The next question is a new card: it arms again, so the press that
    /// answered one does not land on the next one's option.
    func testTheNextQuestionArmsAgain() {
        var draft = AskQuestion.Draft(questions: [color, sizes])
        let first = SessionDetail.ApprovalCard(request([color, sizes]), draft: draft, armed: true)
        draft.choose(0)
        let second = SessionDetail.ApprovalCard(request([color, sizes]), draft: draft, armed: true)
        XCTAssertNotEqual(first.key, second.key)
        draft.choose(1)
        XCTAssertEqual(SessionDetail.ApprovalCard(request([color, sizes]), draft: draft, armed: true).key, second.key,
                       "a tick is not a new card")
    }

    /// The way back is on the second question, not the first.
    func testBackIsOnlyAfterTheFirst() {
        var draft = AskQuestion.Draft(questions: [color, sizes])
        XCTAssertFalse(SessionDetail.ApprovalCard(request([color, sizes]), draft: draft, armed: true).takes(.back))
        draft.choose(0)
        XCTAssertTrue(SessionDetail.ApprovalCard(request([color, sizes]), draft: draft, armed: true).takes(.back))
    }

    func testTheTagNamesTheTabAndWhereItIs() throws {
        var draft = AskQuestion.Draft(questions: [color, sizes])
        XCTAssertEqual(DetailCard.questionTag(try XCTUnwrap(SessionDetail.QuestionCard(draft))), "Color · 1/2")
        draft.choose(0)
        XCTAssertEqual(DetailCard.questionTag(try XCTUnwrap(SessionDetail.QuestionCard(draft))), "2/2")
        XCTAssertEqual(DetailCard.questionTag(try XCTUnwrap(SessionDetail.QuestionCard(.init(questions: [color])))),
                       "Color")
    }

    /// The tallest question card, drawn: three lines of question, four
    /// options, a long description, the button row with the way back and
    /// `[Go to session]`. Under the cap, so nothing is clipped — a clipped
    /// button would still take clicks where it is not seen.
    func testTheTallestQuestionFitsTheCard() throws {
        let long = String(repeating: "A long description of what this option would change for the build. ", count: 4)
        let options = (1...4).map { AskQuestion.Option(label: "An option with a long label number \($0) that runs on",
                                                       description: long) }
        let question = AskQuestion.Question(
            text: String(repeating: "Which colour should the badge use when a long build waits on you? ", count: 5),
            header: "Colour", options: options, multiSelect: true)
        var draft = AskQuestion.Draft(questions: [color, question])
        draft.choose(0)
        let card = SessionDetail.ApprovalCard(request([color, question]), draft: draft, armed: true)
        XCTAssertTrue(try XCTUnwrap(card.question).canGoBack)

        let model = DetailModel()
        model.resolveHost = { _ in .notFound }
        model.update(row: SessionRow(entity: "s", label: "api", phase: .waiting, source: .claude, waitKind: .answer),
                     signal: nil, approval: card)
        model.hovered = .option(0)
        XCTAssertTrue(DetailCard.showsButton(try XCTUnwrap(model.detail)), "the way to the terminal stays")
        let height = NSHostingView(rootView: DetailCard(model: model, maxHeight: 10_000)).fittingSize.height
        XCTAssertGreaterThan(height, 200, "drawn")
        // With room to spare: type renders a little differently elsewhere.
        XCTAssertLessThanOrEqual(height, AppController.detailCardMaxHeight - 8, "clipped at the cap")
    }
}
