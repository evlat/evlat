import XCTest

/// A **tripwire** guarding `EvlatCore`'s import surface.
///
/// It is written knowing it is not a PROOF: on macOS `Foundation` re-exports
/// Darwin, so `sysctl`, `kill` and `open` can be called from a file that
/// imports nothing but `Foundation`, and this test **cannot see** that. The
/// counter-example is real: v1's `Sources/Evlat/Sessions/SessionHost.swift`
/// imports only `Foundation`, uses `kinfo_proc`/`CTL_KERN`/`sysctl`, and would
/// not compile on Linux.
///
/// Portability's real gate is therefore the mechanism, not this test: platform
/// capability is **injected** through `Platform`. This test's only job is to
/// catch a blunt leak — an `import AppKit` — before it reaches a commit.
final class ImportPurityTests: XCTestCase {
    /// What is permitted. The list is an **allowlist**: a denylist would come
    /// up short (`Combine` and `os.log` do not exist on Linux, yet both would
    /// pass a "not AppKit" check).
    private static let allowed: Set<String> = ["Foundation", "Dispatch"]

    private var coreRoot: URL {
        // Tests/EvlatCoreTests/ImportPurityTests.swift → repo root → Sources/EvlatCore
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EvlatCore")
    }

    /// Only the platform-shim idiom is exempt: `#if canImport(Darwin)` /
    /// `#else` `import Glibc`. Hiding an arbitrary module behind `canImport` is
    /// not an exemption but a leak — the first version silently passed a file
    /// writing `#if canImport(AppKit)` (caught at the gate).
    private static let shimModules: Set<String> = ["Darwin", "Glibc", "WinSDK", "Musl"]

    func testCoreImportsOnlyAllowedModules() throws {
        let files = try swiftFiles()
        XCTAssertFalse(files.isEmpty, "no EvlatCore sources found: \(coreRoot.path)")

        var violations: [String] = []
        for file in files {
            // Comments are stripped here too. In this repo comments explain
            // "why we do NOT do this", and a line reading `// import AppKit`
            // counted as a violation under a raw scan.
            let text = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for (index, module) in Self.imports(in: text) {
                guard !Self.allowed.contains(module) else { continue }
                violations.append("\(file.lastPathComponent):\(index + 1) → import \(module)")
            }
        }

        XCTAssertTrue(violations.isEmpty, """
            EvlatCore imports only \(Self.allowed.sorted().joined(separator: ", ")).
            Violations:
            \(violations.joined(separator: "\n"))
            Platform-specific capability is not imported into EvlatCore; it is injected via Platform.
            """)
    }

    /// `(line, module)` pairs from comment-free source. Lines inside exempt
    /// blocks are skipped.
    ///
    /// An import can be written three ways and all three must be caught:
    /// `import AppKit`, `@_exported import AppKit`, `public import AppKit`.
    /// It can also carry a **kind specifier** as in
    /// `import struct Foundation.Data` (`struct`, `class`, `func`, …) — the
    /// module name is the token after it.
    static func imports(in source: String) -> [(Int, String)] {
        let kindKeywords: Set<String> = ["struct", "class", "enum", "protocol",
                                         "typealias", "func", "let", "var", "actor"]
        var out: [(Int, String)] = []
        var stack: [Bool] = []   // true = exempt (platform shim) block

        for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#if") || line.hasPrefix("#elseif") {
                let exempt = Self.shimModules.contains { line.contains("canImport(\($0))") }
                if line.hasPrefix("#if") { stack.append(exempt) }
                else if !stack.isEmpty { stack[stack.count - 1] = exempt }
                continue
            }
            if line.hasPrefix("#else") {
                // The `#else` branch counts as shim too:
                // `#if canImport(Darwin) … #else import Glibc`
                if !stack.isEmpty, stack[stack.count - 1] { stack[stack.count - 1] = true }
                continue
            }
            // EVERY `#endif` closes a block. The first version opened depth
            // only for `#if canImport` but closed on any `#endif`, so a nested
            // `#if DEBUG` ended the exemption early (caught at the gate).
            if line.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if stack.contains(true) { continue }

            var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Drop the prefix: @_exported, @testable, public, internal, …
            while let first = tokens.first, first != "import" { tokens.removeFirst() }
            guard tokens.first == "import", tokens.count >= 2 else { continue }
            tokens.removeFirst()
            if kindKeywords.contains(tokens[0]), tokens.count >= 2 { tokens.removeFirst() }
            let module = tokens[0]
                .components(separatedBy: CharacterSet(charactersIn: " ."))
                .first ?? tokens[0]
            out.append((index, module))
        }
        return out
    }

    /// `EvlatCore` can reach Darwin without importing it, so the blunt leaks
    /// are searched for by name. Also a tripwire — not an exhaustive list.
    func testCoreDoesNotCallDarwinDirectly() throws {
        let markers = ["sysctl", "kinfo_proc", "kill(", "CTL_KERN", "DispatchSource.makeFileSystemObjectSource"]
        var violations: [String] = []
        for file in try swiftFiles() {
            // Comments are stripped: these files' comments explain exactly WHY
            // those APIs are not here, and a raw scan read them as violations
            // (measured — Platform.swift's own comment).
            let text = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for marker in markers where text.contains(marker) {
                violations.append("\(file.lastPathComponent) → \(marker)")
            }
        }
        XCTAssertTrue(violations.isEmpty, """
            EvlatCore does not call Darwin; those capabilities are injected via Platform.
            Violations: \(violations.joined(separator: ", "))
            """)
    }

    private func swiftFiles() throws -> [URL] {
        guard let e = FileManager.default.enumerator(at: coreRoot, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Replaces line (`//`) and block (`/* */`) comments with nothing.
    /// String state is tracked so a `//` inside a literal is not mistaken for a
    /// comment.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var inLineComment = false, inBlockComment = false, inString = false
        var previous: Character = " "
        var iterator = Array(source)
        var i = 0
        while i < iterator.count {
            let c = iterator[i]
            let next: Character? = i + 1 < iterator.count ? iterator[i + 1] : nil

            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
            } else if inBlockComment {
                if c == "*", next == "/" { inBlockComment = false; i += 1 }
            } else if inString {
                if c == "\"", previous != "\\" { inString = false }
                out.append(c)
            } else if c == "/", next == "/" {
                inLineComment = true; i += 1
            } else if c == "/", next == "*" {
                inBlockComment = true; i += 1
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            previous = c
            i += 1
        }
        return out
    }

}
