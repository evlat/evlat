import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// The `codex-usage` provider's contract. Headless: the rollout tree is built
/// under a temporary home, so the real `~/.codex` is never read.
final class CodexUsageProviderTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("evlat-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    /// Epoch seconds of the fixture's resets and its observation.
    private let fiveHourReset = 1_790_206_798
    private let weekReset = 1_790_772_967
    private let observedText = "2026-09-23T22:24:30.649Z"
    private var observed: Date { Date(timeIntervalSince1970: 1_790_202_270.649) }

    /// A `token_count` line shaped like codex-cli 0.156.1's, with its noise.
    private func line(used5h: String = "25.0", used7d: String = "39.0",
                      limitId: String = "codex", timestamp: String? = nil,
                      nullWindows: Bool = false) -> String {
        let windows = nullWindows
            ? #""primary":null,"secondary":null"#
            : #""primary":{"used_percent":\#(used5h),"window_minutes":300,"resets_at":\#(fiveHourReset)},"#
              + #""secondary":{"used_percent":\#(used7d),"window_minutes":10080,"resets_at":\#(weekReset)}"#
        let stamp = timestamp ?? observedText
        return #"{"timestamp":"\#(stamp)","ordinal":27,"type":"event_msg","payload":{"type":"token_count","#
            + #""info":{"total_token_usage":{"input_tokens":37983},"model_context_window":258400},"#
            + #""rate_limits":{"limit_id":"\#(limitId)","limit_name":null,\#(windows),"#
            + #""credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"#
            + #""spend_control_reached":null,"plan_type":null,"rate_limit_reached_type":null}}}"#
    }

    /// Something the tail also holds that is not a rate-limit line.
    private let noise = #"{"timestamp":"2026-09-23T22:24:31.000Z","type":"response_item","payload":{"type":"message","content":"hi"}}"#

    @discardableResult
    private func write(_ lines: [String], day: String = "2026/09/23", name: String = "a",
                       modified: Date? = nil, trailingNewline: Bool = true) throws -> URL {
        let dir = CodexUsageProvider.sessionsDirectory(home: home).appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-\(name).jsonl")
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try text.write(to: file, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        return file
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func reloaded() -> CodexUsageProvider {
        let provider = CodexUsageProvider(home: home)
        provider.reload()
        return provider
    }

    private func percents(_ provider: CodexUsageProvider) -> [Int: Double] {
        Dictionary(uniqueKeysWithValues: provider.currentSignals().compactMap { signal in
            signal.usage.map { ($0.windowMinutes, signal.progress ?? .nan) }
        })
    }

    // MARK: - Cases

    func testTwoWindowsBecomeTwoSignals() throws {
        try write([noise, line(), noise])
        let signals = reloaded().currentSignals().sorted { $0.entity < $1.entity }
        XCTAssertEqual(signals.map(\.entity), ["usage:codex-usage:10080", "usage:codex-usage:300"])
        let five = try XCTUnwrap(signals.first { $0.usage?.windowMinutes == 300 })
        let week = try XCTUnwrap(signals.first { $0.usage?.windowMinutes == 10080 })
        XCTAssertEqual(five.progress ?? .nan, 0.25, accuracy: 1e-9)
        XCTAssertEqual(week.progress ?? .nan, 0.39, accuracy: 1e-9)
        XCTAssertEqual(five.usage?.resetsAt, Date(timeIntervalSince1970: TimeInterval(fiveHourReset)))
        XCTAssertEqual(week.usage?.resetsAt, Date(timeIntervalSince1970: TimeInterval(weekReset)))
        for signal in signals {
            XCTAssertEqual(signal.kind, .usage)
            XCTAssertEqual(signal.phase, .idle)
            XCTAssertEqual(signal.provider, CodexUsageProvider.id)
            XCTAssertEqual(signal.usage?.group, "Codex")
            XCTAssertEqual(signal.fidelity, .derived, "the rollout format is undocumented")
            XCTAssertEqual(signal.updatedAt.timeIntervalSince1970,
                           observed.timeIntervalSince1970, accuracy: 0.001,
                           "the line's own stamp, not the reset and not now")
        }
    }

    /// Past 100 is kept as the source said it; drawing clips, the model does not.
    func testAWindowPastItsLimitKeepsItsValue() throws {
        try write([line(used5h: "112.5")])
        XCTAssertEqual(percents(reloaded())[300] ?? .nan, 1.125, accuracy: 1e-9)
    }

    func testATimestampWithoutFractionsIsRead() throws {
        try write([line(timestamp: "2026-09-23T22:24:30Z")])
        let signal = try XCTUnwrap(reloaded().currentSignals().first)
        XCTAssertEqual(signal.updatedAt, Date(timeIntervalSince1970: 1_790_202_270))
    }

    func testANullWindowedLineAtTheEndGivesWayToTheOneBefore() throws {
        try write([line(used5h: "10.0"), line(limitId: "premium", nullWindows: true)])
        let provider = reloaded()
        XCTAssertEqual(provider.currentSignals().count, 2)
        XCTAssertEqual(percents(provider)[300] ?? .nan, 0.10, accuracy: 1e-9)
    }

    func testATornLastLineIsSkipped() throws {
        let torn = String(line(used5h: "90.0").prefix(180))
        try write([line(used5h: "10.0"), torn], trailingNewline: false)
        XCTAssertEqual(percents(reloaded())[300] ?? .nan, 0.10, accuracy: 1e-9)
    }

    /// The tail is 256 KB; a longer last line fills all of it. Nothing
    /// complete is left to read, and the reading already held stays.
    func testALineLongerThanTheTailKeepsTheLastGoodReading() throws {
        let file = try write([line(used5h: "10.0")])
        let provider = reloaded()
        XCTAssertEqual(provider.currentSignals().count, 2)
        let huge = #"{"type":"response_item","payload":{"content":""# + String(repeating: "x", count: 300_000) + "\"}}\n"
        try append(huge, to: file)
        provider.reload()
        XCTAssertEqual(percents(provider)[300] ?? .nan, 0.10, accuracy: 1e-9, "the last good reading stays")
        XCTAssertTrue(provider.lastReadFailed, "but the failure is said")
    }

    func testALineLongerThanTheTailWithNoEarlierReadingGivesNothing() throws {
        let huge = #"{"type":"response_item","payload":{"content":""# + String(repeating: "x", count: 300_000) + "\"}}"
        try write([line(), huge])
        let provider = reloaded()
        XCTAssertTrue(provider.currentSignals().isEmpty)
        XCTAssertTrue(provider.lastReadFailed)
    }

    func testUnknownFieldsAreIgnored() throws {
        let extra = line().replacingOccurrences(
            of: #""window_minutes":300,"#, with: #""window_minutes":300,"new_field":{"a":[1,2]},"#)
        try write([extra])
        XCTAssertEqual(reloaded().currentSignals().count, 2)
    }

    /// A number in the wrong type is not guessed at: that window is absent.
    func testAStringPercentDropsThatWindow() throws {
        try write([line(used5h: #""25.0""#)])
        let provider = reloaded()
        XCTAssertEqual(provider.currentSignals().compactMap(\.usage?.windowMinutes), [10080])
    }

    func testABooleanPercentDropsThatWindow() throws {
        try write([line(used7d: "true")])
        XCTAssertEqual(reloaded().currentSignals().compactMap(\.usage?.windowMinutes), [300])
    }

    func testNoRateLimitsGivesNoSignal() throws {
        try write([noise, noise])
        let provider = reloaded()
        XCTAssertTrue(provider.currentSignals().isEmpty)
        XCTAssertTrue(provider.lastReadFailed, "a rollout was there and said nothing usable")
    }

    /// A machine that never ran Codex is not a failure.
    func testNoRolloutIsSilent() {
        let provider = reloaded()
        XCTAssertTrue(provider.currentSignals().isEmpty)
        XCTAssertFalse(provider.lastReadFailed)
    }

    /// A long session keeps writing into the day directory it started in.
    func testTheNewestFileWinsWhateverItsDay() throws {
        let now = Date()
        try write([line(used5h: "70.0")], day: "2026/09/05", name: "long", modified: now)
        try write([line(used5h: "10.0")], day: "2026/09/23", name: "short",
                  modified: now.addingTimeInterval(-600))
        XCTAssertEqual(percents(reloaded())[300] ?? .nan, 0.70, accuracy: 1e-9)
    }

    /// An older file is not a fallback: its reading would pass for a new one.
    func testAnOlderFileIsNotFallenBackTo() throws {
        let now = Date()
        try write([line(used5h: "70.0")], day: "2026/09/22", name: "old", modified: now.addingTimeInterval(-600))
        try write([noise], day: "2026/09/23", name: "new", modified: now)
        let provider = reloaded()
        XCTAssertTrue(provider.currentSignals().isEmpty)
        XCTAssertTrue(provider.lastReadFailed)
    }

    func testOnlyRolloutFilesAtTheDayDepthAreRead() throws {
        let now = Date()
        try write([line(used5h: "10.0")], name: "a", modified: now.addingTimeInterval(-600))
        let dir = CodexUsageProvider.sessionsDirectory(home: home)
        try line(used5h: "99.0").write(to: dir.appendingPathComponent("rollout-top.jsonl"),
                                       atomically: true, encoding: .utf8)
        try line(used5h: "99.0").write(to: dir.appendingPathComponent("2026/09/23/notes.jsonl"),
                                       atomically: true, encoding: .utf8)
        XCTAssertEqual(percents(reloaded())[300] ?? .nan, 0.10, accuracy: 1e-9)
    }

    /// `refresh` asks every 1.5 s and on every hook event: the answer comes
    /// from memory, and only `reload()` touches the disk.
    func testCurrentSignalsNeverOpensTheFile() throws {
        try write([line()])
        let provider = CodexUsageProvider(home: home)
        XCTAssertTrue(provider.currentSignals().isEmpty, "nothing read before the first reload")
        XCTAssertEqual(provider.reads, 0)
        provider.reload()
        XCTAssertEqual(provider.reads, 1)
        for _ in 0..<3 { _ = provider.currentSignals() }
        XCTAssertEqual(provider.reads, 1)
        XCTAssertEqual(provider.currentSignals().count, 2)
    }

    /// The fan-out does not ask which provider it is talking to.
    func testTheRegistryReloadsEveryReloadable() throws {
        try write([line()])
        let provider = CodexUsageProvider(home: home)
        let registry = Registry()
        registry.register(provider)
        XCTAssertTrue(registry.snapshot().usage.isEmpty)
        registry.reload()
        XCTAssertEqual(provider.reads, 1)
        XCTAssertEqual(registry.snapshot().usage.count, 2)
        XCTAssertTrue(registry.snapshot().ordered.isEmpty, "a window is not a session")
    }
}
