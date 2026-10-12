import Foundation

extension OpenCode {
    /// OpenCode's mark: a tall frame with a smaller block inside it, drawn
    /// here — not a trace of its logo. Two rings, filled even-odd, so the
    /// inner one is the frame's opening.
    static let outline: [[CGPoint]] = [
        [CGPoint(x: 0.14, y: 0.04), CGPoint(x: 0.86, y: 0.04), CGPoint(x: 0.86, y: 0.96), CGPoint(x: 0.14, y: 0.96)],
        [CGPoint(x: 0.32, y: 0.26), CGPoint(x: 0.68, y: 0.26), CGPoint(x: 0.68, y: 0.74), CGPoint(x: 0.32, y: 0.74)],
    ]
}
