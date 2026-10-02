import SwiftUI
import EvlatCore
import EvlatAgents

/// The mark of the tool a session runs in, drawn inside its ring: the ring
/// says what the session is doing, the mark says where it runs. Two sessions
/// in the same folder, one Claude and one Codex, carry the same name; the mark
/// tells them apart without making the row any longer, and it reads on the
/// closed bar too, where there are no names.
///
/// The outlines are traced (a unit box, filled even-odd so the OpenAI knot's
/// counters stay open), crisp enough at the indicator's size. An official
/// vector would be exact at any size.
struct SourceGlyph: Shape {
    let source: AgentID

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for ring in Self.outline(for: source) {
            guard let first = ring.first else { continue }
            path.move(to: point(first, in: rect))
            for next in ring.dropFirst() { path.addLine(to: point(next, in: rect)) }
            path.closeSubpath()
        }
        return path
    }

    private func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    /// The agent's own (`AgentDisplay.outline`); an id the catalog does not
    /// know draws no mark.
    static func outline(for source: AgentID) -> [[CGPoint]] {
        Agents.all[id: source]?.display.outline ?? []
    }
}
