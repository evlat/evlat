import XCTest

/// The shared code names no agent. The core is closed by the compiler — it
/// cannot import `EvlatAgents` — but a word is not an import: a `"claude"`
/// literal or a path under `.claude` compiles anywhere, and the shell can
/// import the agents' module. So the shared sources are searched by name.
///
/// What is searched: every agent's name (any case) and every type
/// `EvlatAgents` declares, except its open door, the catalog (`Agents`).
/// Comments are not searched; they explain which agent a rule came from.
///
/// A file that must name one has its **count** listed with a reason. The
/// count is exact both ways: a new mention fails, and so does a removed one,
/// so the list never outlives what it excuses.
final class BoundaryTests: XCTestCase {
    private static let agentNames = ["claude", "codex", "antigravity", "gemini"]

    /// The shared sources, relative to `Sources`.
    private static let shared = ["EvlatCore", "EvlatApp"]

    /// File (relative to `Sources`) → (mentions, why).
    private static let allowed: [String: (count: Int, reason: String)] = [
        "EvlatApp/SessionHost/TabLink.swift": (3, "host layer: an app's tab link, not an agent's"),
    ]

    private static var repo: URL {
        // Tests/EvlatCoreTests/BoundaryTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var sources: URL { repo.appendingPathComponent("Sources") }

    func testTheSharedSourcesNameNoAgent() throws {
        let types = try Self.agentTypes()
        XCTAssertFalse(types.isEmpty, "no agent types found under Sources/EvlatAgents")
        let words = try NSRegularExpression(pattern: Self.agentNames.joined(separator: "|"),
                                            options: [.caseInsensitive])
        // Only the type names no agent name already covers; the rest are
        // counted once, as a name.
        let lone = types.filter { type in !Self.agentNames.contains { type.lowercased().contains($0) } }
        let typeWords = try NSRegularExpression(
            pattern: "\\b(" + lone.sorted().joined(separator: "|") + ")\\b")

        var found: [String: Int] = [:]
        var lines: [String: [String]] = [:]
        for target in Self.shared {
            for file in try Self.swiftFiles(under: Self.sources.appendingPathComponent(target)) {
                let path = Self.relative(file)
                let text = ImportPurityTests.strippingComments(try String(contentsOf: file, encoding: .utf8))
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    var hits = words.numberOfMatches(in: line, range: range)
                    if !lone.isEmpty { hits += typeWords.numberOfMatches(in: line, range: range) }
                    guard hits > 0 else { continue }
                    found[path, default: 0] += hits
                    lines[path, default: []].append("  \(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        var violations: [String] = []
        for (path, count) in found.sorted(by: { $0.key < $1.key }) {
            let allowance = Self.allowed[path]?.count ?? 0
            guard count != allowance else { continue }
            violations.append("\(path): \(count) mention(s), \(allowance) allowed\n"
                              + (lines[path] ?? []).joined(separator: "\n"))
        }
        for (path, entry) in Self.allowed.sorted(by: { $0.key < $1.key }) where found[path] == nil {
            violations.append("\(path): 0 mentions, \(entry.count) allowed — take it off the list")
        }
        XCTAssertTrue(violations.isEmpty, """
            The shared sources name no agent; what is particular to one is its own values in \
            Sources/EvlatAgents, reached through the catalog.
            \(violations.joined(separator: "\n"))
            """)
    }

    func testEveryAllowanceHasAReason() {
        for (path, entry) in Self.allowed {
            XCTAssertGreaterThan(entry.count, 0, path)
            XCTAssertFalse(entry.reason.isEmpty, path)
        }
    }

    /// `EvlatAgents` sees Foundation and the core, nothing more: no UI, and
    /// the shell's process and window code stay out of the agents.
    func testTheAgentsImportOnlyFoundationAndTheCore() throws {
        let allowed: Set<String> = ["Foundation", "EvlatCore"]
        let files = try Self.swiftFiles(under: Self.sources.appendingPathComponent("EvlatAgents"))
        XCTAssertFalse(files.isEmpty, "no EvlatAgents sources found")
        var violations: [String] = []
        for file in files {
            let text = ImportPurityTests.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for (index, module) in ImportPurityTests.imports(in: text) where !allowed.contains(module) {
                violations.append("\(Self.relative(file)):\(index + 1) → import \(module)")
            }
        }
        XCTAssertTrue(violations.isEmpty, """
            EvlatAgents imports only \(allowed.sorted().joined(separator: ", ")).
            \(violations.joined(separator: "\n"))
            """)
    }

    /// The search finds what it is meant to find: a name in code counts, in
    /// a comment it does not, and a type name only as a whole word.
    func testTheSearchSeesCodeNotComments() throws {
        let source = """
            let a = "claude" // codex
            /* Antigravity */ let b = SessionsProvider.self
            let c = SessionsProviderish
            """
        let text = ImportPurityTests.strippingComments(source)
        let words = try NSRegularExpression(pattern: Self.agentNames.joined(separator: "|"),
                                            options: [.caseInsensitive])
        let types = try NSRegularExpression(pattern: "\\b(SessionsProvider)\\b")
        let range = NSRange(text.startIndex..., in: text)
        XCTAssertEqual(words.numberOfMatches(in: text, range: range), 1)
        XCTAssertEqual(types.numberOfMatches(in: text, range: range), 1)
    }

    /// The top-level types `EvlatAgents` declares, but the catalog. An
    /// `extension` declares nothing new: `HeldRequest` there extends the
    /// core's own type.
    private static func agentTypes() throws -> Set<String> {
        let declaration = try NSRegularExpression(pattern:
            "^(?:(?:public|internal|fileprivate|private|final)\\s+)*(?:struct|class|enum|protocol|typealias|actor)\\s+([A-Za-z_][A-Za-z0-9_]*)",
            options: [.anchorsMatchLines])
        var types: Set<String> = []
        for file in try swiftFiles(under: sources.appendingPathComponent("EvlatAgents")) {
            let text = ImportPurityTests.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                types.insert(String(text[range]))
            }
        }
        types.remove("Agents")
        return types
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private static func relative(_ file: URL) -> String {
        let base = sources.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}
