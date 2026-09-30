import Foundation

/// Claude Code's `AskUserQuestion`, answered from the bar.
///
/// The tool reaches the approval hook (`ApprovalHook`) as a
/// `PermissionRequest` like any other, but a bare `allow` answers nothing:
/// the terminal's dialog stays up (the reported bug). The documented answer
/// is `allow` with `updatedInput` — the tool's input as it came, plus an
/// `answers` object from each question's text to its answer. Measured on
/// Claude Code 2.1.285, interactive, the answer sent 5 s and 30 s after the
/// terminal's dialog was drawn:
///
/// - the dialog closed and Claude received the answer;
/// - a text that is no option's label (the terminal's "Type something") went
///   through as written;
/// - a multi-select answer is the labels joined by `", "`;
/// - one call carries up to four questions (the terminal's tabs), answered
///   in one reply; a question missing from `answers` raised no error but
///   reached Claude as unanswered — so a draft is sent only when complete.
///
/// Pure: dictionaries in, values out.
public enum AskQuestion {
    public static let tool = "AskUserQuestion"
    /// The tool's own limit, and the most the card has room for.
    static let maxOptions = 4
    /// How a multi-select answer joins its labels (documented, and measured).
    static let separator = ", "

    public struct Option: Equatable {
        public let label: String
        public let description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public struct Question: Equatable {
        /// The key of its answer, so it is never rewritten.
        public let text: String
        /// The terminal's tab title ("Color").
        public let header: String?
        public let options: [Option]
        public let multiSelect: Bool

        public init(text: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
            self.text = text
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    /// The questions of a tool input. `nil` when they cannot be answered by
    /// key: none, an empty text, two with the same text, or one with no
    /// option to press.
    public static func questions(in input: [String: Any]?) -> [Question]? {
        guard let list = input?["questions"] as? [[String: Any]], !list.isEmpty else { return nil }
        var questions: [Question] = []
        for item in list {
            guard let text = item["question"] as? String, !text.isEmpty,
                  !questions.contains(where: { $0.text == text }) else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                let description = (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return Option(label: label, description: description)
            }
            guard !options.isEmpty, options.count <= maxOptions else { return nil }
            questions.append(Question(text: text, header: (item["header"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                      options: options, multiSelect: item["multiSelect"] as? Bool ?? false))
        }
        return questions
    }

    /// The questions answered one at a time, as the terminal's tabs are,
    /// and sent together once the last is answered.
    ///
    /// A single-select question is answered by one press: an option, or a
    /// written answer. A multi-select one collects presses and a written
    /// answer, and is answered by `commit`. `back` returns to the question
    /// before, its answer still marked; what was picked further on is kept.
    public struct Draft: Equatable {
        /// One question's answer as picked: options by index, and a
        /// written answer.
        public struct Choice: Equatable {
            public var picked: Set<Int> = []
            public var written: String?
        }

        public let questions: [Question]
        /// Each question's, in the questions' order.
        public private(set) var choices: [Choice]
        /// The question up; `questions.count` once every one is answered.
        public private(set) var index = 0

        public init(questions: [Question]) {
            self.questions = questions
            choices = Array(repeating: Choice(), count: questions.count)
        }

        /// `nil` once every question is answered.
        public var current: Question? { questions.indices.contains(index) ? questions[index] : nil }
        /// The current question's pressed options, and its written answer.
        public var picked: Set<Int> { current == nil ? [] : choices[index].picked }
        public var written: String? { current == nil ? nil : choices[index].written }
        public var canGoBack: Bool { index > 0 && current != nil }

        /// Every answer by its question's text; `nil` until all are in.
        public var answers: [String: String]? {
            guard current == nil else { return nil }
            return Dictionary(uniqueKeysWithValues: zip(questions, choices).map { ($0.text, Self.answer($0, $1)) })
        }

        /// A multi-select question with something to send.
        public var canCommit: Bool {
            guard current?.multiSelect == true else { return false }
            return !picked.isEmpty || written != nil
        }

        /// An option pressed: the answer to a single-select question, one
        /// more (or one fewer) of a multi-select one's.
        public mutating func choose(_ option: Int) {
            guard let question = current, question.options.indices.contains(option) else { return }
            if question.multiSelect {
                if choices[index].picked.contains(option) {
                    choices[index].picked.remove(option)
                } else {
                    choices[index].picked.insert(option)
                }
            } else {
                choices[index] = Choice(picked: [option])
                index += 1
            }
        }

        /// A written answer: a single-select question's whole answer; a
        /// multi-select one's last part, after the pressed labels. Blank
        /// clears it.
        public mutating func write(_ text: String) {
            guard let question = current else { return }
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if question.multiSelect {
                choices[index].written = text.isEmpty ? nil : text
            } else if !text.isEmpty {
                choices[index] = Choice(written: text)
                index += 1
            }
        }

        /// A multi-select question's answer, as picked.
        public mutating func commit() {
            guard canCommit else { return }
            index += 1
        }

        /// The question before, its answer as it was.
        public mutating func back() {
            guard canGoBack else { return }
            index -= 1
        }

        /// A single-select one's written answer or its option's label; a
        /// multi-select one's labels in the options' order, then the
        /// written answer.
        static func answer(_ question: Question, _ choice: Choice) -> String {
            let labels = question.options.indices.filter(choice.picked.contains).map { question.options[$0].label }
            if !question.multiSelect { return choice.written ?? labels.first ?? "" }
            return (labels + [choice.written].compactMap { $0 }).joined(separator: AskQuestion.separator)
        }
    }
}
