import Foundation

extension Antigravity {
    /// Antigravity: a plain arch, drawn here — not a trace of its logo,
    /// which has no outline in codenotch's set. One ring: the outer half
    /// ellipse up, the inner one back down.
    static let outline: [[CGPoint]] = {
        let steps = 24
        func arc(_ radius: CGSize, reversed: Bool) -> [CGPoint] {
            (0...steps).map { i -> CGPoint in
                let t = Double(reversed ? steps - i : i) / Double(steps)
                let angle = Double.pi * (1 - t)
                return CGPoint(x: 0.5 + radius.width * cos(angle), y: 0.92 - radius.height * sin(angle))
            }
        }
        return [arc(CGSize(width: 0.44, height: 0.82), reversed: false)
                + arc(CGSize(width: 0.2, height: 0.5), reversed: true)]
    }()
}
