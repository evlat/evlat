import XCTest
@testable import EvlatCore
@testable import EvlatAgents

/// The catalog holds together: an agent not in it does not exist, so one in
/// it must not collide with another or go nameless.
final class AgentCatalogTests: XCTestCase {
    func testTheIdsAreUnique() {
        XCTAssertEqual(Set(Agents.all.ids).count, Agents.all.count)
    }

    /// Every route answers as one agent: no path is claimed twice, none is a
    /// fixed route's, and the table made from the catalog has them all.
    func testNoRouteCollides() {
        let hooks = Agents.all.flatMap(\.hooks.paths)
        let usage = Agents.all.compactMap(\.statusLineUsage?.path)
        let fixed = [PermissionHook.path, ApprovalHook.path, SignalReport.path, Askpass.path, "/health"]
        XCTAssertEqual(Set(hooks + usage + fixed).count, hooks.count + usage.count + fixed.count)
        XCTAssertEqual(Agents.routes.hooks.count, hooks.count)
        XCTAssertEqual(Agents.routes.usage.count, usage.count)
        for agent in Agents.all {
            XCTAssertTrue(agent.hookPath.hasPrefix(RouteTable.installedPrefix), agent.id.rawValue)
            XCTAssertFalse(agent.hooks.events.isEmpty, agent.id.rawValue)
            XCTAssertFalse(agent.presence.isEmpty, agent.id.rawValue)
        }
        XCTAssertEqual(Agents.all.filter { $0.approvals != nil }.count, 1,
                       "`/approval` holds one agent's requests (`RouteTable.approval`)")
    }

    /// Each agent's name is in both string tables.
    func testEveryAgentHasAName() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        for language in ["en", "tr"] {
            let table = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent(
                "\(language).lproj/Evlat.strings")) as? [String: String], language)
            for agent in Agents.all {
                XCTAssertNotNil(table[agent.display.nameKey], "\(language): \(agent.id.rawValue)")
            }
        }
    }

    /// Each agent has a mark to draw in its rings, and no two look alike:
    /// rings of at least three points, in the unit box the shell scales (a
    /// traced outline overshoots it by a hair).
    func testEveryAgentHasAMark() {
        for agent in Agents.all {
            let outline = agent.display.outline
            XCTAssertFalse(outline.isEmpty, agent.id.rawValue)
            for ring in outline {
                XCTAssertGreaterThanOrEqual(ring.count, 3, agent.id.rawValue)
                for point in ring {
                    XCTAssertTrue((-0.1...1.1).contains(point.x) && (-0.1...1.1).contains(point.y),
                                  "\(agent.id.rawValue): \(point)")
                }
            }
        }
        let outlines = Agents.all.map { $0.display.outline.map { $0.map { [$0.x, $0.y] } } }
        for (i, outline) in outlines.enumerated() {
            XCTAssertFalse(outlines[(i + 1)...].contains(outline), Agents.all[i].id.rawValue)
        }
    }

    /// The stored switches and the routes speak the same words as before
    /// the catalog: `agents.enabled` and a machine's `agents` keep their
    /// values.
    func testTheIdsAreTheStoredWords() {
        XCTAssertEqual(Agents.all.ids.map(\.rawValue), ["claude", "codex", "antigravity"])
    }
}
