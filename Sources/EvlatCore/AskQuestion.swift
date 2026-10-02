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

    /// The questions of a tool input. `nil` when they cannot be answered by
    /// key: none, an empty text, two with the same text, or one with no
    /// option to press.
    public static func questions(in input: [String: Any]?) -> [AgentQuestion]? {
        guard let list = input?["questions"] as? [[String: Any]], !list.isEmpty else { return nil }
        var questions: [AgentQuestion] = []
        for item in list {
            guard let text = item["question"] as? String, !text.isEmpty,
                  !questions.contains(where: { $0.text == text }) else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestion.Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                let description = (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return AgentQuestion.Option(label: label, description: description)
            }
            guard !options.isEmpty, options.count <= maxOptions else { return nil }
            questions.append(AgentQuestion(text: text, header: (item["header"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                      options: options, multiSelect: item["multiSelect"] as? Bool ?? false))
        }
        return questions
    }
}
