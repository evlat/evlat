import XCTest
@testable import EvlatCore

/// `AskUserQuestion` answered from the bar: the questions read off the
/// request, the draft that answers them one at a time, and the reply —
/// the shape measured to close the terminal's dialog (`AskQuestion`).
final class AskQuestionTests: XCTestCase {
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// A real request's body (2.1.285), two questions in one call.
    private let body = #"""
    {"session_id":"s-1","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion",
     "tool_input":{"questions":[
       {"question":"Which color?","header":"Color","options":[{"label":"Red","description":"The color red"},
                                                              {"label":"Blue","description":""}],"multiSelect":false},
       {"question":"Which sizes?","header":"Size","options":[{"label":"Small"},{"label":"Medium"},{"label":"Large"}],
        "multiSelect":true}],
      "metadata":{"source":"x"}}}
    """#

    private var color: AskQuestion.Question {
        .init(text: "Which color?", header: "Color",
              options: [.init(label: "Red", description: "The color red"), .init(label: "Blue")])
    }
    private var sizes: AskQuestion.Question {
        .init(text: "Which sizes?", header: "Size",
              options: [.init(label: "Small"), .init(label: "Medium"), .init(label: "Large")], multiSelect: true)
    }

    func testTheRequestReadsTheQuestionsAndKeepsTheInput() throws {
        let request = try XCTUnwrap(PermissionHook.Request(json: try object(body), token: nil))
        XCTAssertEqual(request.questions, [color, sizes])
        let input = try XCTUnwrap(request.input.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual((input["metadata"] as? [String: String])?["source"], "x", "a field not modelled is kept")
    }

    /// Anything but the question tool keeps nothing of its input.
    func testAnotherToolKeepsNoInput() throws {
        let request = try XCTUnwrap(PermissionHook.Request(json: try object(
            #"{"tool_name":"Write","tool_input":{"file_path":"/a","content":"x","questions":[]}}"#), token: nil))
        XCTAssertNil(request.questions)
        XCTAssertNil(request.input)
    }

    /// Answers are keyed by the question's text: what cannot be keyed is
    /// not a question the card answers.
    func testQuestionsThatCannotBeKeyedAreRefused() {
        let option: [String: Any] = ["label": "A"]
        XCTAssertNil(AskQuestion.questions(in: nil))
        XCTAssertNil(AskQuestion.questions(in: ["questions": []]))
        XCTAssertNil(AskQuestion.questions(in: ["questions": [["question": "", "options": [option]]]]))
        XCTAssertNil(AskQuestion.questions(in: ["questions": [["question": "Q", "options": [option]],
                                                            ["question": "Q", "options": [option]]]]))
        XCTAssertNil(AskQuestion.questions(in: ["questions": [["question": "Q", "options": []]]]))
        XCTAssertEqual(AskQuestion.questions(in: ["questions": [["question": "Q", "options": [option]]]])?.count, 1)
    }

    func testASingleSelectQuestionIsOnePress() {
        var draft = AskQuestion.Draft(questions: [color])
        XCTAssertEqual(draft.current, color)
        XCTAssertNil(draft.answers)
        draft.choose(1)
        XCTAssertNil(draft.current)
        XCTAssertEqual(draft.answers, ["Which color?": "Blue"])
    }

    /// Measured: text that is no label goes through as written.
    func testAWrittenAnswerIsTheWholeAnswerOfASingleSelect() {
        var draft = AskQuestion.Draft(questions: [color])
        draft.write("   ")
        XCTAssertEqual(draft.index, 0, "a blank answer answers nothing")
        draft.write(" Chartreuse ")
        XCTAssertEqual(draft.answers, ["Which color?": "Chartreuse"])
    }

    /// Labels in the options' order, the written answer last, joined as
    /// measured; nothing to send until something is picked.
    func testAMultiSelectCollectsThenCommits() {
        var draft = AskQuestion.Draft(questions: [sizes])
        XCTAssertFalse(draft.canCommit)
        draft.commit()
        XCTAssertEqual(draft.index, 0)
        draft.choose(2)
        draft.choose(0)
        draft.choose(1)
        draft.choose(1)
        XCTAssertEqual(draft.picked, [0, 2])
        draft.write("XL")
        XCTAssertTrue(draft.canCommit)
        draft.commit()
        XCTAssertEqual(draft.answers, ["Which sizes?": "Small, Large, XL"])
    }

    /// Measured: a question left out reaches Claude as unanswered, with no
    /// error — so nothing is sent until every one is in.
    func testSeveralQuestionsAreAnsweredInTurnAndSentTogether() {
        var draft = AskQuestion.Draft(questions: [color, sizes])
        draft.choose(0)
        XCTAssertEqual(draft.current, sizes, "the next question, with nothing picked")
        XCTAssertTrue(draft.picked.isEmpty)
        XCTAssertNil(draft.answers)
        draft.choose(1)
        draft.commit()
        XCTAssertEqual(draft.answers, ["Which color?": "Red", "Which sizes?": "Medium"])
        draft.choose(0)
        XCTAssertEqual(draft.answers, ["Which color?": "Red", "Which sizes?": "Medium"], "a press after the end does nothing")
    }

    /// Back returns to the question before with its answer marked; a new
    /// answer replaces it, and what was picked further on is kept.
    func testBackKeepsWhatWasPicked() {
        var draft = AskQuestion.Draft(questions: [color, sizes])
        XCTAssertFalse(draft.canGoBack, "nothing before the first")
        draft.choose(0)
        draft.choose(2)
        draft.write("XL")
        XCTAssertTrue(draft.canGoBack)
        draft.back()
        XCTAssertEqual(draft.current, color)
        XCTAssertEqual(draft.picked, [0], "the answer given is marked")
        draft.write("Teal")
        XCTAssertEqual(draft.current, sizes)
        XCTAssertEqual(draft.picked, [2])
        XCTAssertEqual(draft.written, "XL")
        draft.commit()
        XCTAssertEqual(draft.answers, ["Which color?": "Teal", "Which sizes?": "Large, XL"])
    }

    /// The reply that closed the terminal's dialog: allow, the input as it
    /// came, and `answers`.
    func testTheAnswerIsTheInputWithItsAnswers() throws {
        let input = Data(#"{"questions":[{"header":"Color","multiSelect":false,"options":[{"label":"Red"},{"label":"Blue"}],"question":"Which color?"}]}"#.utf8)
        XCTAssertEqual(PermissionHook.body(.answer(input: input, answers: ["Which color?": "Blue"])),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"answers":{"Which color?":"Blue"},"#
                       + #""questions":[{"header":"Color","multiSelect":false,"options":[{"label":"Red"},{"label":"Blue"}],"#
                       + #""question":"Which color?"}]}},"hookEventName":"PermissionRequest"}}"#)
    }
}
