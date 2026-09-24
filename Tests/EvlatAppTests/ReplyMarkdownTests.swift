import XCTest
import AppKit
import SwiftUI
import EvlatCore
@testable import EvlatApp

/// A reply's markdown in the balloon: the inline reader and what a link and
/// `[Copy]` are allowed to do. Neither the user's pasteboard nor their
/// browser is touched: the model's closures are the seam.
@MainActor
final class ReplyMarkdownTests: XCTestCase {
    func testALinkOpensOnlyForWebAndMailSchemes() throws {
        let model = ChatModel()
        var opened: [URL] = []
        model.onOpenLink = { opened.append($0) }
        for link in ["https://example.com/a", "HTTP://example.com", "mailto:a@b.c"] {
            XCTAssertTrue(model.openLink(try XCTUnwrap(URL(string: link))), link)
        }
        for link in ["file:///etc/passwd", "x-apple.systempreferences:com.apple.preference", "docs/readme.md",
                     "javascript:alert(1)"] {
            XCTAssertFalse(model.openLink(try XCTUnwrap(URL(string: link))), link)
        }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a", "HTTP://example.com", "mailto:a@b.c"])
    }

    func testCopyHandsTheCodeToTheController() {
        let model = ChatModel()
        var copied: [String] = []
        model.onCopy = { copied.append($0) }
        model.copy("make hepsi\n")
        XCTAssertEqual(copied, ["make hepsi\n"])
    }

    func testTheInlineReaderStylesCodeSpansAndKeepsLinks() {
        let string = MarkdownInline.attributed("run `make` or see [docs](https://example.com) and **this**")
        XCTAssertEqual(String(string.characters), "run make or see docs and this")
        let code = string.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code.map { String(string[$0.range].characters) }, "make")
        XCTAssertNotNil(code?.font, "a code span gets the monospaced face")
        XCTAssertNotNil(code?.backgroundColor)
        XCTAssertEqual(string.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com"])
    }

    /// Raw HTML is not drawn; escapes are read; a line break stays one.
    func testHTMLStaysTextAndEscapesAreRead() {
        XCTAssertEqual(String(MarkdownInline.attributed("<b>hi</b> \\*no\\*\nnext").characters),
                       "<b>hi</b> *no*\nnext")
    }

    func testTheCopyWordsAreInBothTables() {
        XCTAssertEqual(L10n.t("chat.code.copy", in: "tr"), "Kopyala")
        XCTAssertEqual(L10n.t("chat.code.copied", in: "en"), "Copied")
    }

    /// Every block kind lays out in the balloon's width without a zero or
    /// runaway height — a horizontal scroll inside the vertical one is the
    /// easy way to get either.
    func testAReplyWithEveryBlockLaysOut() {
        let text = """
        # Title
        Text with `code` and a [link](https://example.com).
        1. one
           - nested
        > quote
        ```swift
        let x = 1
        ```
        | a | b |
        |---|--:|
        | 1 | 2 |
        ---
        """
        let host = NSHostingView(rootView: ReplyView(text: text).frame(width: 300))
        let size = host.fittingSize
        XCTAssertEqual(size.width, 300, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 150)
        XCTAssertLessThan(size.height, 600)
    }
}
