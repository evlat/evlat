import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// The Antigravity CLI's usage: its status line JSON, the route it is posted
/// on, the provider it lands in and the relay that posts it. The body is
/// shaped like one `agy` 1.2.14 sent (measured), with its identifying fields
/// replaced.
final class AntigravityUsageTests: XCTestCase {
    private func body(quota: String? = AntigravityUsageTests.quota) -> [String: Any] {
        let text = #"{"cwd":"/Users/someone/private","session_id":"","product":"antigravity","#
            + #""model":{"id":"Gemini 3.8 Flash (Medium)"},"email":"someone@example.com","#
            + #""context_window":{"used_percentage":0}"#
            + (quota.map { #","quota":"# + $0 } ?? "") + "}"
        return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private static let quota = #"{"3p-5h":{"remaining_fraction":1,"reset_time":"2026-10-01T19:05:51Z","reset_in_seconds":17998},"#
        + #""3p-weekly":{"remaining_fraction":1,"reset_time":"2026-10-08T14:05:51Z","reset_in_seconds":604798},"#
        + #""gemini-5h":{"remaining_fraction":1,"reset_time":"2026-10-01T19:05:51Z","reset_in_seconds":17998},"#
        + #""gemini-weekly":{"remaining_fraction":0.9227441,"reset_time":"2026-10-06T08:14:14Z","reset_in_seconds":410901}}"#

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: - The parser

    /// Gemini's two windows, used as the rest of the fraction; the other
    /// vendors' pool is named, not drawn.
    func testTheMeasuredBodyGivesGeminisWindows() throws {
        let report = UsageReport(statusLine: body(), source: .antigravity)
        XCTAssertEqual(report.source, .antigravity)
        XCTAssertEqual(report.windows.map(\.minutes), [300, 10080])
        XCTAssertEqual(report.windows[0].usedPercent, 0)
        XCTAssertEqual(report.windows[1].usedPercent, 7.72559, accuracy: 0.0001)
        XCTAssertEqual(report.windows.map(\.resetsAt), [date("2026-10-01T19:05:51Z"), date("2026-10-06T08:14:14Z")])
        XCTAssertEqual(report.unrecognizedWindows, ["3p-5h", "3p-weekly"])
    }

    func testNoQuotaIsAnEmptyReport() {
        let report = UsageReport(statusLine: body(quota: nil), source: .antigravity)
        XCTAssertEqual(report, UsageReport(windows: [], unrecognizedWindows: [], source: .antigravity))
    }

    func testABrokenWindowIsLeftOutAlone() {
        let quota = #"{"gemini-5h":{"remaining_fraction":true,"reset_time":"2026-10-01T19:05:51Z"},"#
            + #""gemini-weekly":{"remaining_fraction":0.5,"reset_time":"2026-10-06T08:14:14.250Z"}}"#
        let report = UsageReport(statusLine: body(quota: quota), source: .antigravity)
        XCTAssertEqual(report.windows.map(\.minutes), [10080], "a boolean is not a fraction")
        XCTAssertEqual(report.windows.first?.usedPercent, 50)
        XCTAssertEqual(report.windows.first?.resetsAt, date("2026-10-06T08:14:14Z").addingTimeInterval(0.25),
                       "fractional seconds are read too")
        let badDate = #"{"gemini-5h":{"remaining_fraction":0.5,"reset_time":"soon"}}"#
        XCTAssertEqual(UsageReport(statusLine: body(quota: badDate), source: .antigravity).windows, [])
    }

    // MARK: - The route and the provider

    func testItsRouteDeliversItsReport() throws {
        XCTAssertEqual(Antigravity().statusLineUsage?.path, "/usage/antigravity")
        XCTAssertEqual(LocalAPI.dispatch(method: "POST", target: "/usage/antigravity", origin: nil, host: nil,
                                         routes: Agents.routes),
                       .usage(.antigravity))
        XCTAssertEqual(LocalAPI.dispatch(method: "GET", target: "/usage/antigravity", origin: nil, host: nil,
                                         routes: Agents.routes),
                       .notFound)
        let data = try JSONSerialization.data(withJSONObject: body())
        let request = HTTPRequest(method: "POST", target: "/usage/antigravity", body: data,
                                  taskID: nil, pid: nil, origin: nil, host: "127.0.0.1:48151")
        guard case .usage(let report)? = LocalAPI.handleAsTheApp(request).delivery else { return XCTFail("no report") }
        XCTAssertEqual(report.source, .antigravity)
        XCTAssertEqual(report.windows.count, 2)
    }

    func testItsProviderIsGeminisGroup() {
        let now = date("2026-10-01T14:05:51Z")
        let provider = StatusLineUsageProvider(now: { now }, source: .antigravity)
        XCTAssertEqual(provider.id, "antigravity-usage")
        XCTAssertEqual(provider.group, "Gemini")
        provider.handle(UsageReport(statusLine: body(), source: .antigravity))
        let signals = provider.currentSignals()
        XCTAssertEqual(signals.map(\.usage?.group), ["Gemini", "Gemini"])
        XCTAssertEqual(signals.map(\.usage?.windowMinutes), [300, 10080])
        XCTAssertEqual(signals.map(\.fidelity), [.derived, .derived], "undocumented: drawn with ~")
        let claude = StatusLineUsageProvider(now: { now }, source: .claude)
        claude.handle(UsageReport(windows: [UsageReport.Window(minutes: 300, usedPercent: 1, resetsAt: now + 60)],
                                  unrecognizedWindows: [], source: .claude))
        XCTAssertEqual(claude.currentSignals().map(\.fidelity), [.official], "Claude's stays official")
        XCTAssertEqual(signals.map(\.entity), ["usage:antigravity-usage:300", "usage:antigravity-usage:10080"])
    }

    // MARK: - The relay

    /// The fixed point for Antigravity, as Claude's is pinned in
    /// `StatusLineRelayTests`.
    func testTheInstalledCommandIsUnchanged() {
        let relay = #"i=$(cat; printf x); i=${i%x}; printf %s "$i" | curl -s -m 2 -X POST"#
            + #" -H "Content-Type: application/json" --data-binary @-"#
            + #" http://127.0.0.1:48151/usage/antigravity >/dev/null 2>&1 &"#
        XCTAssertEqual(StatusLineRelay.command(wrapping: nil, source: .antigravity), "sh -c '" + relay + "'")
        XCTAssertEqual(StatusLineRelay.command(wrapping: "x", source: .antigravity),
                       "sh -c '" + relay + #" printf %s "$i" | sh -c "$1"' evlat-statusline 'x'"#)
    }

    /// One agent's wrapper is not the other's: neither reads as installed
    /// nor is taken apart by the other's removal.
    func testTheSourcesWrappersAreTheirOwn() {
        let claude: [String: Any] = ["statusLine": ["type": "command", "command": StatusLineRelay.command(wrapping: nil, source: .claude)]]
        XCTAssertEqual(StatusLineRelay.state(of: claude, source: .antigravity), .missing)
        XCTAssertEqual(StatusLineRelay.removing(from: claude, source: .antigravity)?["statusLine"] as? [String: String],
                       claude["statusLine"] as? [String: String])
        XCTAssertEqual(StatusLineRelay.state(of: claude, source: .codex), .missing)
        XCTAssertNil(StatusLineRelay.installing(into: [:], source: .codex), "Codex has no status line route")
    }

    /// The relay alone keeps the CLI's own line (`stack_with_default`), and
    /// its removal takes that key out with it; a wrapped command needs none.
    func testInstallingAndRemovingRoundTrips() throws {
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: ["model": "x"], source: .antigravity))
        let line = try XCTUnwrap(installed["statusLine"] as? [String: Any])
        XCTAssertEqual(line["stack_with_default"] as? Bool, true)
        XCTAssertEqual(line["type"] as? String, "command")
        XCTAssertEqual(StatusLineRelay.state(of: installed, source: .antigravity), .current)
        let removed = try XCTUnwrap(StatusLineRelay.removing(from: installed, source: .antigravity))
        XCTAssertNil(removed["statusLine"])
        XCTAssertEqual(removed["model"] as? String, "x")

        let own: [String: Any] = ["statusLine": ["type": "command", "command": "mine.sh"]]
        let wrapped = try XCTUnwrap(StatusLineRelay.installing(into: own, source: .antigravity))
        let wrappedLine = try XCTUnwrap(wrapped["statusLine"] as? [String: Any])
        XCTAssertNil(wrappedLine["stack_with_default"], "the user's own line is still drawn")
        XCTAssertEqual(StatusLineRelay.removing(from: wrapped, source: .antigravity)?["statusLine"] as? [String: String],
                       ["type": "command", "command": "mine.sh"])
    }

    /// A `statusLine` with no command gets the relay alone, and so the key:
    /// without it the CLI's own line would be replaced by an empty one. A
    /// value the user set is kept.
    func testARelayAloneKeepsTheCLIsLineEvenBesideAnEmptyStatusLine() throws {
        for line in [[:], ["type": "command"]] as [[String: Any]] {
            let installed = try XCTUnwrap(StatusLineRelay.installing(into: ["statusLine": line], source: .antigravity))
            let written = try XCTUnwrap(installed["statusLine"] as? [String: Any])
            XCTAssertEqual(written["stack_with_default"] as? Bool, true)
            XCTAssertEqual(StatusLineRelay.state(of: installed, source: .antigravity), .current)
        }
        let own: [String: Any] = ["statusLine": ["stack_with_default": false]]
        let installed = try XCTUnwrap(StatusLineRelay.installing(into: own, source: .antigravity))
        XCTAssertEqual((installed["statusLine"] as? [String: Any])?["stack_with_default"] as? Bool, false)
    }

    func testItsFileIsTheCLIsSettings() {
        let home = URL(fileURLWithPath: "/h")
        XCTAssertEqual(Antigravity().statusLineFile(home: home)?.path,
                       "/h/.gemini/antigravity-cli/settings.json")
        XCTAssertEqual(Claude().statusLineFile(home: home), Claude().hooksFile(home: home))
        XCTAssertNil(Codex().statusLineFile(home: home))
    }
}
