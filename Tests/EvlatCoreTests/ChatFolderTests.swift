import XCTest
@testable import EvlatCore

/// The folder a chat runs in and what the dropped files are: pure path arithmetic, no disk.
final class ChatFolderTests: XCTestCase {
    private let home = "/Users/me"

    private func file(_ path: String) -> ChatFolder.Item { ChatFolder.Item(path: path, isDirectory: false) }
    private func folder(_ path: String) -> ChatFolder.Item { ChatFolder.Item(path: path, isDirectory: true) }

    // MARK: - The folder

    func testFilesRunInTheirCommonParent() {
        XCTAssertEqual(ChatFolder.folder(for: [file("/Users/me/Work/q3/rapor.pdf"),
                                              file("/Users/me/Work/q3/fatura.pdf")], home: home),
                       "/Users/me/Work/q3")
        XCTAssertEqual(ChatFolder.folder(for: [file("/Users/me/Work/q3/rapor.pdf"),
                                              file("/Users/me/Work/q4/x/fatura.pdf")], home: home),
                       "/Users/me/Work")
    }

    func testOneFileRunsInItsOwnFolder() {
        XCTAssertEqual(ChatFolder.folder(for: [file("/Users/me/Work/rapor.pdf")], home: home), "/Users/me/Work")
    }

    func testADroppedFolderIsItself() {
        XCTAssertEqual(ChatFolder.folder(for: [folder("/Users/me/Work/q3")], home: home), "/Users/me/Work/q3")
        XCTAssertEqual(ChatFolder.folder(for: [folder("/Users/me/Work/q3/")], home: home), "/Users/me/Work/q3",
                       "a trailing slash is the same folder")
    }

    /// A folder among other things is a thing in its parent, like a file.
    func testAFolderWithFilesRunsInTheirCommonParent() {
        XCTAssertEqual(ChatFolder.folder(for: [folder("/Users/me/Work/q3"), file("/Users/me/Work/notes.txt")],
                                         home: home),
                       "/Users/me/Work")
    }

    func testNothingDroppedIsTheWorkspace() {
        XCTAssertNil(ChatFolder.folder(for: [], home: home))
    }

    /// A file on the Desktop and one in Downloads have the home as their
    /// common parent — and a turn run there reaches everything the user
    /// has. So never the home. The chat gets its own workspace and the
    /// files are named by their full paths.
    func testTheHomeOrAboveIsNeverTheFolder() {
        XCTAssertNil(ChatFolder.folder(for: [file("/Users/me/Desktop/a.pdf"),
                                            file("/Users/me/Downloads/b.pdf")], home: home))
        XCTAssertNil(ChatFolder.folder(for: [file("/Users/me/a.pdf")], home: home), "a file right in the home")
        XCTAssertNil(ChatFolder.folder(for: [folder("/Users/me")], home: home), "the home dropped itself")
        XCTAssertNil(ChatFolder.folder(for: [file("/Users/me/a.pdf"), file("/Volumes/USB/b.pdf")], home: home),
                     "no common parent but the root")
        XCTAssertNil(ChatFolder.folder(for: [folder("/Users")], home: home), "above the home")
        XCTAssertEqual(ChatFolder.folder(for: [file("/Users/meadow/a.pdf")], home: home), "/Users/meadow",
                       "a sibling that only shares the home's spelling is not the home")
    }

    // MARK: - Attachments in the prompt

    func testAttachmentsInsideTheFolderAreRelative() {
        XCTAssertEqual(ChatFolder.attachmentPath("/Users/me/Work/q3/rapor.pdf", in: "/Users/me/Work"), "q3/rapor.pdf")
        XCTAssertEqual(ChatFolder.attachmentPath("/Users/me/Work", in: "/Users/me/Work"), "./",
                       "the folder itself")
        XCTAssertEqual(ChatFolder.attachmentPath("/Users/me/Workshop/a.pdf", in: "/Users/me/Work"),
                       "/Users/me/Workshop/a.pdf", "a sibling with the folder's spelling is outside it")
        XCTAssertEqual(ChatFolder.attachmentPath("/tmp/a.pdf", in: "/Users/me/Work"), "/tmp/a.pdf")
    }

    // MARK: - Kinds

    func testTheKindComesFromTheExtension() {
        XCTAssertEqual(ChatFolder.kind(of: file("/a/Rapor.PDF")), .pdf)
        for name in ["a.png", "a.jpg", "a.jpeg", "a.heic", "a.gif", "a.webp", "a.tiff"] {
            XCTAssertEqual(ChatFolder.kind(of: file("/a/" + name)), .image, name)
        }
        XCTAssertEqual(ChatFolder.kind(of: folder("/a/q3.pdf")), .folder, "a folder is a folder, whatever its name")
        XCTAssertEqual(ChatFolder.kind(of: file("/a/notes.txt")), .other)
        XCTAssertEqual(ChatFolder.kind(of: file("/a/Makefile")), .other)
    }

    /// What the balloon suggests reads the files as one group: all of a
    /// kind is that kind, anything else is mixed.
    func testTheGroupHasOneKindOrIsMixed() {
        XCTAssertEqual(ChatFolder.kind(of: [file("/a/x.pdf"), file("/a/y.pdf")]), .pdf)
        XCTAssertEqual(ChatFolder.kind(of: [file("/a/x.png")]), .image)
        XCTAssertEqual(ChatFolder.kind(of: [folder("/a/q3")]), .folder)
        XCTAssertNil(ChatFolder.kind(of: [file("/a/x.pdf"), file("/a/y.png")]), "mixed")
        XCTAssertNil(ChatFolder.kind(of: []))
    }

    func testTheLabelIsTheExtension() {
        XCTAssertEqual(ChatFolder.label(of: file("/a/rapor.pdf")), "PDF")
        XCTAssertEqual(ChatFolder.label(of: file("/a/photo.jpeg")), "JPEG")
        XCTAssertNil(ChatFolder.label(of: file("/a/Makefile")))
        XCTAssertNil(ChatFolder.label(of: folder("/a/q3.d")), "a folder has an icon, not an extension")
    }
}
