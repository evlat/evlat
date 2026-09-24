import Foundation

/// A reply's markdown, cut into blocks (`011/phase-3`, after the gate).
///
/// Foundation's `AttributedString(markdown:)` reads only what is inside a
/// line — emphasis, code spans, links — so a heading, a list or a fenced
/// block came out of the balloon as `#`, `*` and backticks. This is the other
/// half: a small line scanner for the blocks Claude writes, each block's text
/// left raw for the inline reader (the view's). It is not CommonMark: no
/// setext headings, no indented code (it fights nested lists), no HTML
/// blocks — raw HTML stays text.
///
/// A reply streams in, so a half-written reply must read well too: an open
/// fence is a code block with `closed == false`, a table row with no
/// delimiter under it yet is a paragraph. What text comes later changes the
/// last block only (`MarkdownBlockTests.testAStreamOnlyEverChangesItsLastBlock`),
/// so the reply does not jump while it grows.
public enum MarkdownBlock: Equatable, Sendable {
    /// Lines joined by `\n`, each trimmed: a reply's line breaks are kept.
    case paragraph(String)
    /// `#` to `######`; the view draws 3 and deeper alike.
    case heading(level: Int, text: String)
    /// Each item its own blocks: its text, then what is nested under it.
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    /// `language` is the info string's first word.
    case code(language: String?, text: String, closed: Bool)
    case quote([MarkdownBlock])
    case rule
    /// Every row has the header's number of cells.
    case table(header: [String], alignments: [Alignment], rows: [[String]])

    public enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return blocks(lines)
    }

    // MARK: - Blocks

    private static func blocks(_ lines: [String]) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
            } else if let fence = Fence(line) {
                var body: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    defer { i += 1 }
                    if fence.isClosed(by: lines[i]) { closed = true; break }
                    body.append(strip(lines[i], columns: fence.indent))
                }
                // An open fence's last line, when empty, is only the newline
                // the next piece will write after: no blank row under the code.
                if !closed, body.count > 0, body.last == "" { body.removeLast() }
                out.append(.code(language: fence.language, text: body.joined(separator: "\n"), closed: closed))
            } else if let heading = heading(line) {
                out.append(heading)
                i += 1
            } else if isRule(line) {
                out.append(.rule)
                i += 1
            } else if quoted(line) != nil {
                var inner: [String] = []
                while i < lines.count, let content = quoted(lines[i]) {
                    inner.append(content)
                    i += 1
                }
                out.append(.quote(blocks(inner)))
            } else if let marker = ListMarker(line) {
                let (list, next) = self.list(lines, from: i, first: marker)
                out.append(list)
                i = next
            } else if case let (table, next)? = table(lines, from: i) {
                out.append(table)
                i = next
            } else {
                var paragraph = [trim(line)]
                i += 1
                while i < lines.count, !isBlank(lines[i]), !interrupts(lines, at: i) {
                    paragraph.append(trim(lines[i]))
                    i += 1
                }
                out.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }
        return out
    }

    /// Does this line start a block of its own, ending a paragraph above it?
    /// A numbered line does only when it counts from 1: "Kanuna göre\n15.
    /// madde uyarınca" is one sentence broken before an ordinal.
    private static func interrupts(_ lines: [String], at i: Int) -> Bool {
        let line = lines[i]
        if let marker = ListMarker(line), !marker.ordered || marker.number == 1 { return true }
        return Fence(line) != nil || heading(line) != nil || isRule(line) || quoted(line) != nil
            || table(lines, from: i) != nil
    }

    // MARK: - Lists

    /// A list marker: `-`, `*`, `+`, or a number with `.` or `)`, then a
    /// space or the line's end.
    private struct ListMarker {
        let indent: Int
        let ordered: Bool
        let number: Int
        /// Where the item's text starts: its continuation lines are indented
        /// this far.
        let contentIndent: Int
        let content: String

        init?(_ line: String) {
            // `* * *` is a rule, not an item.
            guard !MarkdownBlock.isRule(line) else { return nil }
            let indent = MarkdownBlock.indent(of: line)
            let rest = Substring(MarkdownBlock.strip(line, columns: indent))
            guard let first = rest.first else { return nil }
            var width: Int
            if "-*+".contains(first) {
                ordered = false
                number = 1
                width = 1
            } else {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard (1...9).contains(digits.count), let number = Int(digits),
                      let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")"
                else { return nil }
                ordered = true
                self.number = number
                width = digits.count + 1
            }
            let after = rest.dropFirst(width)
            let spaces = after.prefix { $0 == " " }.count
            guard after.isEmpty || spaces > 0 else { return nil }
            // More than four spaces is the text's own indentation, not the
            // marker's.
            let gap = after.allSatisfy { $0 == " " } || spaces > 4 ? 1 : spaces
            self.indent = indent
            contentIndent = indent + width + gap
            content = String(after.dropFirst(min(gap, after.count)))
        }
    }

    /// A list and the line after it. A line belongs to the current item when
    /// it is indented under it — two spaces are enough, so `1.` items with
    /// two-space bullets under them nest; a marker of the same kind further
    /// out starts the next item; a line straight after the item's text
    /// continues it; anything else, or text after a blank line, ends it.
    private static func list(_ lines: [String], from start: Int, first: ListMarker) -> (MarkdownBlock, Int) {
        var items: [[String]] = [[first.content]]
        var current = first
        var afterBlank = false
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                items[items.count - 1].append("")
                afterBlank = true
                i += 1
                continue
            }
            let indent = indent(of: line)
            if indent >= min(current.contentIndent, current.indent + 2) {
                items[items.count - 1].append(strip(line, columns: current.contentIndent))
            } else if let marker = ListMarker(line), marker.ordered == first.ordered {
                items.append([marker.content])
                current = marker
            } else if !afterBlank, !interrupts(lines, at: i) {
                items[items.count - 1].append(trim(line))
            } else {
                break
            }
            afterBlank = false
            i += 1
        }
        return (.list(ordered: first.ordered, start: first.number, items: items.map(blocks)), i)
    }

    // MARK: - Fences, headings, rules, quotes

    private struct Fence {
        let indent: Int
        let mark: Character
        let length: Int
        let language: String?

        init?(_ line: String) {
            let indent = MarkdownBlock.indent(of: line)
            guard indent <= 3 else { return nil }
            let rest = MarkdownBlock.strip(line, columns: indent)
            guard let mark = rest.first, mark == "`" || mark == "~" else { return nil }
            let length = rest.prefix { $0 == mark }.count
            guard length >= 3 else { return nil }
            let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
            if mark == "`", info.contains("`") { return nil }
            self.indent = indent
            self.mark = mark
            self.length = length
            language = info.split(separator: " ").first.map(String.init)
        }

        func isClosed(by line: String) -> Bool {
            let indent = MarkdownBlock.indent(of: line)
            guard indent <= 3 else { return false }
            let rest = MarkdownBlock.strip(line, columns: indent)
            let run = rest.prefix { $0 == mark }.count
            return run >= length && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let indent = indent(of: line)
        guard indent <= 3 else { return nil }
        let rest = strip(line, columns: indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // A closing run of `#`s, after a space, is not the heading's text.
        if text.allSatisfy({ $0 == "#" }) {
            text = ""
        } else if let space = text.lastIndex(where: { $0 == " " || $0 == "\t" }),
                  text[text.index(after: space)...].allSatisfy({ $0 == "#" }) {
            text = text[..<space].trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: level, text: text)
    }

    /// `---`, `***` or `___`, three or more, spaces between allowed.
    private static func isRule(_ line: String) -> Bool {
        guard indent(of: line) <= 3 else { return false }
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// A `>` line's text: the marker and one space after it taken off.
    private static func quoted(_ line: String) -> String? {
        let indent = indent(of: line)
        guard indent <= 3 else { return nil }
        let rest = strip(line, columns: indent)
        guard rest.first == ">" else { return nil }
        let after = rest.dropFirst()
        return String(after.first == " " ? after.dropFirst() : after)
    }

    // MARK: - Tables

    /// A table: a row with a pipe, a delimiter row with as many cells under
    /// it, then every following line that has a pipe.
    private static func table(_ lines: [String], from i: Int) -> (MarkdownBlock, Int)? {
        guard i + 1 < lines.count, lines[i].contains("|"),
              let alignments = delimiter(lines[i + 1]) else { return nil }
        let header = cells(lines[i])
        guard header.count == alignments.count else { return nil }
        var rows: [[String]] = []
        var j = i + 2
        while j < lines.count, !isBlank(lines[j]), lines[j].contains("|") {
            let row = cells(lines[j])
            rows.append(Array((row + Array(repeating: "", count: max(0, header.count - row.count)))
                .prefix(header.count)))
            j += 1
        }
        return (.table(header: header, alignments: alignments, rows: rows), j)
    }

    /// `| --- | :-: | --: |`: each cell's alignment, or `nil` when the line
    /// is not a delimiter row. It needs a pipe: `---` alone is a rule.
    private static func delimiter(_ line: String) -> [Alignment]? {
        guard line.contains("|") else { return nil }
        let cells = cells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [Alignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right && cell.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments
    }

    /// A row's cells, trimmed: outer pipes dropped, split on the pipes that
    /// are neither escaped nor inside a code span. An escaped pipe is a pipe
    /// in the cell.
    private static func cells(_ line: String) -> [String] {
        var row = Substring(trim(line))
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for character in row {
            if escaped {
                cell += character == "|" ? "|" : "\\" + String(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell += "\\" }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Lines

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func trim(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    /// Leading columns; a tab runs to the next multiple of four.
    private static func indent(of line: String) -> Int {
        var column = 0
        for character in line {
            if character == " " { column += 1 } else if character == "\t" { column += 4 - column % 4 } else { break }
        }
        return column
    }

    /// The line with up to `columns` of its leading indentation taken off.
    private static func strip(_ line: String, columns: Int) -> String {
        var column = 0
        var index = line.startIndex
        while index < line.endIndex, column < columns {
            let character = line[index]
            if character == " " { column += 1 } else if character == "\t" { column += 4 - column % 4 } else { break }
            index = line.index(after: index)
        }
        return String(line[index...])
    }
}
