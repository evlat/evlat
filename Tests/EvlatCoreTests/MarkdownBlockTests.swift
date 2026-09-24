import XCTest
@testable import EvlatCore

/// The reply's block reader. Inline syntax (emphasis, code spans, links,
/// escapes) is not read here: it reaches the view as it was written.
final class MarkdownBlockTests: XCTestCase {
    private func parse(_ text: String) -> [MarkdownBlock] { MarkdownBlock.parse(text) }

    func testPlainTextIsOneParagraphWithItsLineBreaks() {
        XCTAssertEqual(parse("Hello **there**.\nSecond `line`  "), [.paragraph("Hello **there**.\nSecond `line`")])
        XCTAssertEqual(parse(""), [])
    }

    func testBlankLinesSplitParagraphs() {
        XCTAssertEqual(parse("\n\none\n\n\n  two\n\n"), [.paragraph("one"), .paragraph("two")])
    }

    func testHeadings() {
        XCTAssertEqual(parse("# One\n## Two ##\n### Three\n#### Four\nbody"), [
            .heading(level: 1, text: "One"), .heading(level: 2, text: "Two"),
            .heading(level: 3, text: "Three"), .heading(level: 4, text: "Four"), .paragraph("body"),
        ])
        // No space after the marks: a hashtag, not a heading.
        XCTAssertEqual(parse("#tag and ####### seven"), [.paragraph("#tag and ####### seven")])
        XCTAssertEqual(parse("#"), [.heading(level: 1, text: "")])
    }

    func testAHeadingEndsAParagraph() {
        XCTAssertEqual(parse("text\n## Next"), [.paragraph("text"), .heading(level: 2, text: "Next")])
    }

    func testBulletAndNumberedLists() {
        XCTAssertEqual(parse("- a\n* b\n+ c"),
                       [.list(ordered: false, start: 1, items: [[.paragraph("a")], [.paragraph("b")], [.paragraph("c")]])])
        XCTAssertEqual(parse("3. three\n4) four"),
                       [.list(ordered: true, start: 3, items: [[.paragraph("three")], [.paragraph("four")]])])
    }

    func testAListAfterTextEndsTheParagraph() {
        XCTAssertEqual(parse("Steps:\n1. one\n2. two\n\nDone."), [
            .paragraph("Steps:"),
            .list(ordered: true, start: 1, items: [[.paragraph("one")], [.paragraph("two")]]),
            .paragraph("Done."),
        ])
    }

    /// Only a list counting from 1 breaks into a paragraph; an ordinal at a
    /// line's start is the sentence's.
    func testAnOrdinalAtALineStartStaysInTheParagraph() {
        XCTAssertEqual(parse("Kanuna göre\n15. madde uyarınca silinir"),
                       [.paragraph("Kanuna göre\n15. madde uyarınca silinir")])
        XCTAssertEqual(parse("15. madde\n16. madde"),
                       [.list(ordered: true, start: 15, items: [[.paragraph("madde")], [.paragraph("madde")]])])
    }

    func testNestedLists() {
        let text = """
        1. first
           - under first
             - deeper
        2. second
          - two-space indent still nests
        - a bullet ends the numbered list
        """
        XCTAssertEqual(parse(text), [
            .list(ordered: true, start: 1, items: [
                [.paragraph("first"),
                 .list(ordered: false, start: 1, items: [
                     [.paragraph("under first"), .list(ordered: false, start: 1, items: [[.paragraph("deeper")]])],
                 ])],
                [.paragraph("second"),
                 .list(ordered: false, start: 1, items: [[.paragraph("two-space indent still nests")]])],
            ]),
            .list(ordered: false, start: 1, items: [[.paragraph("a bullet ends the numbered list")]]),
        ])
    }

    func testAnItemContinuesOnTheNextLineAndAcrossABlankIndentedLine() {
        XCTAssertEqual(parse("- wrapped\nline\n\n  more of it\n\nafter"), [
            .list(ordered: false, start: 1, items: [[.paragraph("wrapped\nline"), .paragraph("more of it")]]),
            .paragraph("after"),
        ])
        // A loose list is still one list.
        XCTAssertEqual(parse("- a\n\n- b"),
                       [.list(ordered: false, start: 1, items: [[.paragraph("a")], [.paragraph("b")]])])
    }

    func testAFencedCodeBlockKeepsItsTextAsItIs() {
        let text = """
        Run:
        ```swift
        let x = 1

            // **not bold** # not a heading
        ```
        after
        """
        XCTAssertEqual(parse(text), [
            .paragraph("Run:"),
            .code(language: "swift", text: "let x = 1\n\n    // **not bold** # not a heading", closed: true),
            .paragraph("after"),
        ])
        XCTAssertEqual(parse("~~~\n```\n~~~"), [.code(language: nil, text: "```", closed: true)])
        XCTAssertEqual(parse("````md\n```\ninner\n```\n````"),
                       [.code(language: "md", text: "```\ninner\n```", closed: true)])
    }

    /// While a reply streams, an open fence is already a code block — the
    /// text inside never flashes as markdown.
    func testAHalfWrittenFenceIsAnOpenCodeBlock() {
        XCTAssertEqual(parse("Here:\n```py\nprint(1)\n# comment"),
                       [.paragraph("Here:"), .code(language: "py", text: "print(1)\n# comment", closed: false)])
        XCTAssertEqual(parse("```"), [.code(language: nil, text: "", closed: false)])
        XCTAssertEqual(parse("```sh\nls\n``"), [.code(language: "sh", text: "ls\n``", closed: false)])
        XCTAssertEqual(parse("```sh\nls\n"), [.code(language: "sh", text: "ls", closed: false)],
                       "the line not yet written is not a blank row")
        XCTAssertEqual(parse("```sh\nls\n\n"), [.code(language: "sh", text: "ls\n", closed: false)])
    }

    func testAFenceInAListItem() {
        XCTAssertEqual(parse("1. Run\n   ```sh\n   make\n   ```\n2. Done"), [
            .list(ordered: true, start: 1, items: [
                [.paragraph("Run"), .code(language: "sh", text: "make", closed: true)],
                [.paragraph("Done")],
            ]),
        ])
    }

    func testQuotes() {
        XCTAssertEqual(parse("> one\n>two\n> - item\n\nafter"), [
            .quote([.paragraph("one\ntwo"), .list(ordered: false, start: 1, items: [[.paragraph("item")]])]),
            .paragraph("after"),
        ])
    }

    func testRules() {
        XCTAssertEqual(parse("a\n---\nb\n***\n_ _ _\n- - -"),
                       [.paragraph("a"), .rule, .paragraph("b"), .rule, .rule, .rule])
        XCTAssertEqual(parse("- a\n* * *"), [.list(ordered: false, start: 1, items: [[.paragraph("a")]]), .rule])
        XCTAssertEqual(parse("--"), [.paragraph("--")])
    }

    func testTables() {
        let text = """
        | Name | Size | Kind |
        |:-----|-----:|:----:|
        | a.txt | 1 KB | `text` |
        | b | 2 |
        c | 3 | x | extra
        """
        XCTAssertEqual(parse(text), [
            .table(header: ["Name", "Size", "Kind"], alignments: [.leading, .trailing, .center], rows: [
                ["a.txt", "1 KB", "`text`"],
                ["b", "2", ""],
                ["c", "3", "x"],
            ]),
        ])
    }

    func testATableWithoutOuterPipesEndsAtALineWithoutOne() {
        XCTAssertEqual(parse("Intro\na | b\n--|--\n1 | 2\nafter"), [
            .paragraph("Intro"),
            .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]]),
            .paragraph("after"),
        ])
    }

    func testARowWithoutADelimiterIsText() {
        XCTAssertEqual(parse("| a | b |"), [.paragraph("| a | b |")])
        XCTAssertEqual(parse("| a | b |\n|---|"), [.paragraph("| a | b |\n|---|")])
    }

    func testPipesInCodeSpansAndEscapedPipesStayInTheirCell() {
        XCTAssertEqual(parse("| op | means |\n|---|---|\n| `a|b` | x \\| y |"), [
            .table(header: ["op", "means"], alignments: [.leading, .leading], rows: [["`a|b`", "x | y"]]),
        ])
    }

    /// Escapes are the inline reader's: the text reaches it untouched, and
    /// an escaped marker starts no block.
    func testEscapedMarkersStartNoBlock() {
        XCTAssertEqual(parse("\\# not a heading\n\\- not an item\n1\\. not a number\n\\> not a quote"),
                       [.paragraph("\\# not a heading\n\\- not an item\n1\\. not a number\n\\> not a quote")])
        XCTAssertEqual(parse("\\```\nx"), [.paragraph("\\```\nx")])
    }

    /// Raw HTML is not drawn: it stays text.
    func testHTMLIsText() {
        XCTAssertEqual(parse("<div align=\"center\">\n<b>hi</b>\n</div>"),
                       [.paragraph("<div align=\"center\">\n<b>hi</b>\n</div>")])
    }

    func testEmphasisAtALineStartIsNotAnItem() {
        XCTAssertEqual(parse("**Bold** start\n*italic* too"), [.paragraph("**Bold** start\n*italic* too")])
    }

    func testWindowsLineEnds() {
        XCTAssertEqual(parse("# T\r\n\r\ntext"), [.heading(level: 1, text: "T"), .paragraph("text")])
    }

    /// A reply streams in: at every point of the stream, the blocks before
    /// the last one are the finished reply's own — only the block being
    /// written moves, so the balloon does not jump above it.
    func testAStreamOnlyEverChangesItsLastBlock() {
        let reply = """
        # Plan

        Here is what I found in `src/`:

        1. **Parser** — reads the lines
           - nested bullet
        2. Renderer

        > A quote
        > over two lines

        ```swift
        let x = [1, 2]

        print(x)
        ```

        | File | Lines |
        |------|------:|
        | a.swift | 10 |
        | b.swift | 20 |

        ---

        See [the docs](https://example.com).
        """
        let full = parse(reply)
        XCTAssertEqual(full.count, 8)
        var prefix = ""
        for character in reply {
            prefix.append(character)
            let partial = parse(prefix)
            XCTAssertLessThanOrEqual(partial.count, full.count, "prefix: \(prefix.debugDescription)")
            XCTAssertEqual(Array(partial.dropLast()), Array(full.prefix(max(0, partial.count - 1))),
                           "prefix: \(prefix.debugDescription)")
        }
    }
}
