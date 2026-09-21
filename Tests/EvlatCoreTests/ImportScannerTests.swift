import XCTest
@testable import EvlatCore

/// Tripwire'ın **tarayıcısının** kendi sınamaları.
///
/// Her vaka `/code-review`'ün phase-0'da bulduğu bir kaçak ya da yanlış
/// pozitife karşılık gelir: bir bekçi sınaması, neyi kaçırdığı sınanmadan
/// güven vermez.
final class ImportScannerTests: XCTestCase {
    private func modules(_ source: String) -> [String] {
        ImportPurityTests.imports(in: ImportPurityTests.strippingComments(source)).map(\.1)
    }

    /// Bulgu 1: keyfi bir modülü `canImport` ardına saklamak muafiyet değil.
    func testArbitraryModuleHiddenBehindCanImportIsStillCaught() {
        XCTAssertEqual(modules("""
            #if canImport(AppKit)
            import AppKit
            #endif
            """), ["AppKit"])
    }

    /// Muaf olan tek şey platform kabuğu deyimi.
    func testDarwinGlibcShimIsExempt() {
        XCTAssertEqual(modules("""
            #if canImport(Darwin)
            import Darwin
            #else
            import Glibc
            #endif
            """), [])
    }

    /// Bulgu 2: içteki `#if` muafiyeti erken bitirmemeli.
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

    /// Bulgu 3a: tür belirteçli import'ta modül adı ikinci sırada.
    func testTypeQualifiedImportReportsTheModule() {
        XCTAssertEqual(modules("import struct Foundation.Data"), ["Foundation"])
        XCTAssertEqual(modules("import func Darwin.sysctl"), ["Darwin"])
    }

    /// Bulgu 3b: öneki olan import'lar görünmez kalmamalı.
    func testPrefixedImportsAreCaught() {
        XCTAssertEqual(modules("@_exported import AppKit"), ["AppKit"])
        XCTAssertEqual(modules("public import AppKit"), ["AppKit"])
        XCTAssertEqual(modules("@testable import AppKit"), ["AppKit"])
    }

    /// Bulgu 4: yorumdaki "import" satırı ihlal değildir — bu deponun üslubu
    /// tam olarak "bunu neden YAPMIYORUZ"u yorumda anlatmak.
    func testCommentedImportIsNotAViolation() {
        XCTAssertEqual(modules("""
            // import AppKit  ← bunu yapmıyoruz
            /* import Network */
            import Foundation
            """), ["Foundation"])
    }

    func testStringLiteralWithSlashesSurvivesCommentStripping() {
        let stripped = ImportPurityTests.strippingComments(#"let path = "a//b" // yorum"#)
        XCTAssertTrue(stripped.contains(#""a//b""#))
        XCTAssertFalse(stripped.contains("yorum"))
    }
}
