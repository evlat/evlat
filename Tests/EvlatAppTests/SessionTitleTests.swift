import XCTest
import EvlatCore
@testable import EvlatApp

final class SessionTitleTests: XCTestCase {
    private func signal(kind: Signal.Kind = .session, label: String = "Fix login", folder: String? = "/work/project") -> Signal {
        Signal(provider: "test", entity: "session", kind: kind, phase: .working,
               label: label, detail: folder, fidelity: .derived, updatedAt: Date())
    }

    func testFolderIsTheDefaultForAbsentOrUnknownPreferences() {
        XCTAssertEqual(SessionTitle.stored(nil), .folder)
        XCTAssertEqual(SessionTitle.stored("future"), .folder)
        for title in SessionTitle.allCases {
            XCTAssertEqual(SessionTitle.stored(title.rawValue), title)
        }
    }

    func testEachChoiceResolvesItsOwnTitle() {
        let session = signal()
        XCTAssertEqual(SessionTitle.folder.label(for: session) { XCTFail("Unexpected branch read"); return nil }, "project")
        XCTAssertEqual(SessionTitle.cli.label(for: session) { XCTFail("Unexpected branch read"); return nil }, "Fix login")
        XCTAssertEqual(SessionTitle.branch.label(for: session) { "feature/login" }, "feature/login")
    }

    func testMissingMetadataFallsBackWithoutEmptyTitles() {
        XCTAssertEqual(SessionTitle.branch.label(for: signal()) { nil }, "project")
        XCTAssertEqual(SessionTitle.cli.label(for: signal(label: "  \n")) { nil }, "project")
        XCTAssertEqual(SessionTitle.folder.label(for: signal(folder: nil)) { nil }, "Fix login")
        XCTAssertEqual(SessionTitle.folder.label(for: signal(folder: "")) { nil }, "Fix login")
        XCTAssertEqual(SessionTitle.branch.label(for: signal(folder: nil)) { "main" }, "main")
    }

    func testNonSessionNamesArePreservedAndNeverReadGit() {
        for kind in [Signal.Kind.job, .custom, .usage] {
            for title in SessionTitle.allCases {
                XCTAssertEqual(title.label(for: signal(kind: kind)) {
                    XCTFail("Non-session read Git"); return nil
                }, "Fix login")
            }
        }
    }
}
