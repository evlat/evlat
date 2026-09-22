import XCTest
@testable import EvlatCore

/// Tests for the tripwire's **own scanner**.
///
/// Each case corresponds to a leak or false positive `/code-review` found in
/// phase-0: a guard that has never been tested for what it misses is not a
/// guard worth trusting.
final class ImportScannerTests: XCTestCase {
    private func modules(_ source: String) -> [String] {
        ImportPurityTests.imports(in: ImportPurityTests.strippingComments(source)).map(\.1)
    }

    /// Finding 1: hiding an arbitrary module behind `canImport` is not an
    /// exemption.
    func testArbitraryModuleHiddenBehindCanImportIsStillCaught() {
        XCTAssertEqual(modules("""
            #if canImport(AppKit)
            import AppKit
            #endif
            """), ["AppKit"])
    }

    /// The only exemption is the platform-shim idiom.
    func testDarwinGlibcShimIsExempt() {
        XCTAssertEqual(modules("""
            #if canImport(Darwin)
            import Darwin
            #else
            import Glibc
            #endif
            """), [])
    }

    /// Finding 2: a nested `#if` must not end the exemption early.
    func testNestedConditionalDoesNotEndTheExemption() {
        XCTAssertEqual(modules("""
            #if canImport(Darwin)
            import Darwin
            #if DEBUG
            import Foundation
            #endif
            import Dispatch
            #endif
            import AppKit
            """), ["AppKit"])
    }

    /// Finding 3a: with a kind specifier the module name is the second token.
    func testTypeQualifiedImportReportsTheModule() {
        XCTAssertEqual(modules("import struct Foundation.Data"), ["Foundation"])
        XCTAssertEqual(modules("import func Darwin.sysctl"), ["Darwin"])
    }

    /// Finding 3b: prefixed imports must not stay invisible.
    func testPrefixedImportsAreCaught() {
        XCTAssertEqual(modules("@_exported import AppKit"), ["AppKit"])
        XCTAssertEqual(modules("public import AppKit"), ["AppKit"])
        XCTAssertEqual(modules("@testable import AppKit"), ["AppKit"])
    }

    /// Finding 4: an "import" inside a comment is not a violation — explaining
    /// why we do NOT do something in a comment is exactly this repo's style.
    func testCommentedImportIsNotAViolation() {
        XCTAssertEqual(modules("""
            // import AppKit  ← we do not do this
            /* import Network */
            import Foundation
            """), ["Foundation"])
    }

    func testStringLiteralWithSlashesSurvivesCommentStripping() {
        let stripped = ImportPurityTests.strippingComments(#"let path = "a//b" // comment"#)
        XCTAssertTrue(stripped.contains(#""a//b""#))
        XCTAssertFalse(stripped.contains("comment"))
    }
}
