import Foundation

/// A question an agent asks the user through its permission path, as the
/// card draws and answers it: one key per answer, up to four options, one
/// or several picked. The agent's own wire format reads into it and writes
/// the answers back (`ApprovalChannel`).
public struct AgentQuestion: Equatable {
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

        public let questions: [AgentQuestion]
        /// Each question's, in the questions' order.
        public private(set) var choices: [Choice]
        /// The question up; `questions.count` once every one is answered.
        public private(set) var index = 0

        public init(questions: [AgentQuestion]) {
            self.questions = questions
            choices = Array(repeating: Choice(), count: questions.count)
        }

        /// `nil` once every question is answered.
        public var current: AgentQuestion? { questions.indices.contains(index) ? questions[index] : nil }
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
        static func answer(_ question: AgentQuestion, _ choice: Choice) -> String {
            let labels = question.options.indices.filter(choice.picked.contains).map { question.options[$0].label }
            if !question.multiSelect { return choice.written ?? labels.first ?? "" }
            return (labels + [choice.written].compactMap { $0 }).joined(separator: AgentQuestion.separator)
        }
    }
}
