import Foundation

/// Turns a bot icon whose eyes are painted out (`EyeFinder`) into a floating
/// head: the background made transparent, the head turned upright by the
/// eyes' lean, what the picture's frame cut off rebuilt from the other side
/// of the face, and the result cropped to the head and scaled to fill the
/// side. The eyes move with it, so the mascot's own eyes land where the
/// picture's were.
///
/// The prompt crops the head at the frame's left and bottom on purpose. A
/// face is near enough to symmetric that its other half is the best guess at
/// the missing part: mirrored across the line between the eyes, the cut side
/// gets back its hair, ear and beard. What neither side has (the very bottom
/// of a cropped chin) fades out.
///
/// The prompt draws a tilted, cropped close-up on a near-black background;
/// upright and unframed, the head can lean and bob as the cube does.
///
/// Pure over premultiplied RGBA buffers.
public enum PortraitShaper {
    public struct Shaped: Equatable {
        public let rgba: [UInt8]
        public let side: Int
        public let eyes: [EyeFinder.Eye]
    }

    /// How far (largest channel difference) a pixel joined to the edge may
    /// be from the edge's colour and still be background. Dark hair is
    /// usually warmer than the neutral background by more than this.
    static let tolerance = 12

    public static func shape(rgba input: [UInt8], side: Int, eyes: [EyeFinder.Eye], out: Int = 512) -> Shaped {
        var rgba = input
        clearBackground(&rgba, side: side)
        let tilt = eyes.isEmpty ? 0 : eyes.map(\.tilt).reduce(0, +) / Double(eyes.count)
        let cut = cutEdges(rgba, side: side)
        var (turned, turnedSide, beyond) = rotate(rgba, side: side, degrees: -tilt)
        // Missing is only what lies past an edge the head ran into; past an
        // edge with background at it there was only more background.
        var inside = beyond.map { $0 & cut == 0 }
        let turnedEyes = eyes.map { turn($0, side: side, into: turnedSide, degrees: -tilt) }
        if !turnedEyes.isEmpty {
            let axis = turnedEyes.map(\.cx).reduce(0, +) / Double(turnedEyes.count) * Double(turnedSide)
            mirrorFill(&turned, inside: &inside, side: turnedSide, axis: axis)
        }
        fadeMissing(&turned, inside: inside, side: turnedSide)
        guard let box = opaqueBox(turned, side: turnedSide) else {
            return Shaped(rgba: resample(turned, side: turnedSide, crop: (0, 0, turnedSide), out: out),
                          side: out, eyes: turnedEyes)
        }
        let extent = Int((Double(max(box.w, box.h)) * 1.04).rounded(.up))
        let x = box.x + box.w / 2 - extent / 2, y = box.y + box.h / 2 - extent / 2
        let finalEyes = turnedEyes.map { eye -> EyeFinder.Eye in
            var e = eye
            e.cx = (eye.cx * Double(turnedSide) - Double(x)) / Double(extent)
            e.cy = (eye.cy * Double(turnedSide) - Double(y)) / Double(extent)
            e.length = eye.length * Double(turnedSide) / Double(extent)
            e.width = eye.width * Double(turnedSide) / Double(extent)
            return e
        }
        return Shaped(rgba: resample(turned, side: turnedSide, crop: (x, y, extent), out: out),
                      side: out, eyes: finalEyes)
    }

    // MARK: - Steps

    /// Background: the pixels joined to the picture's edge whose colour is
    /// close to the edge's median colour, cleared to transparent; one ring
    /// beyond them is cleared in part, so the outline is not jagged.
    static func clearBackground(_ rgba: inout [UInt8], side: Int) {
        let count = side * side
        var edge: [[Int]] = [[], [], []]
        for i in 0..<side {
            for p in [i, (side - 1) * side + i, i * side, i * side + side - 1] {
                for c in 0..<3 { edge[c].append(Int(rgba[p * 4 + c])) }
            }
        }
        let key = edge.map { $0.sorted()[$0.count / 2] }
        func distance(_ p: Int) -> Int {
            (0..<3).map { abs(Int(rgba[p * 4 + $0]) - key[$0]) }.max() ?? 0
        }
        var background = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for i in 0..<side {
            for p in [i, (side - 1) * side + i, i * side, i * side + side - 1]
            where !background[p] && distance(p) <= tolerance {
                background[p] = true
                stack.append(p)
            }
        }
        while let p = stack.popLast() {
            let x = p % side, y = p / side
            for n in [x > 0 ? p - 1 : -1, x < side - 1 ? p + 1 : -1, y > 0 ? p - side : -1, y < side - 1 ? p + side : -1]
            where n >= 0 && !background[n] && distance(n) <= tolerance {
                background[n] = true
                stack.append(n)
            }
        }
        var alpha = [Double](repeating: 1, count: count)
        for p in 0..<count where background[p] { alpha[p] = 0 }
        for p in 0..<count where !background[p] {
            let x = p % side, y = p / side
            let touches = [x > 0 ? p - 1 : -1, x < side - 1 ? p + 1 : -1, y > 0 ? p - side : -1, y < side - 1 ? p + side : -1]
                .contains { $0 >= 0 && background[$0] }
            guard touches else { continue }
            let d = Double(distance(p))
            alpha[p] = min(1, max(0.25, (d - Double(tolerance)) / Double(tolerance * 2)))
        }
        apply(alpha, to: &rgba)
    }

    /// What the picture's frame cut off (`inside` false: the turned canvas
    /// there came from outside the picture, or from its last rows, which the
    /// frame clipped) is taken from the mirror image across `axis`, where the
    /// mirror lies inside.
    static func mirrorFill(_ rgba: inout [UInt8], inside: inout [Bool], side: Int, axis: Double) {
        var filled = inside
        for y in 0..<side {
            for x in 0..<side where !inside[y * side + x] {
                let mx = Int((2 * axis - Double(x) - 1).rounded())
                guard mx >= 0, mx < side, inside[y * side + mx] else { continue }
                let from = (y * side + mx) * 4, to = (y * side + x) * 4
                for c in 0..<4 { rgba[to + c] = rgba[from + c] }
                filled[y * side + x] = true
            }
        }
        inside = filled
    }

    /// The subject still running into what is missing ends in a short fade,
    /// not a straight cut; what is missing is cleared.
    static func fadeMissing(_ rgba: inout [UInt8], inside: [Bool], side: Int) {
        let margin = max(2, Int(Double(side) * 0.05))
        var distance = [Int](repeating: Int.max, count: side * side)
        var queue: [Int] = []
        for p in 0..<(side * side) where !inside[p] { distance[p] = 0; queue.append(p) }
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            guard distance[p] < margin else { continue }
            let x = p % side, y = p / side
            for n in [x > 0 ? p - 1 : -1, x < side - 1 ? p + 1 : -1, y > 0 ? p - side : -1, y < side - 1 ? p + side : -1]
            where n >= 0 && distance[n] == Int.max {
                distance[n] = distance[p] + 1
                queue.append(n)
            }
        }
        var alpha = [Double](repeating: 1, count: side * side)
        for p in 0..<(side * side) where distance[p] <= margin {
            alpha[p] = Double(distance[p]) / Double(margin)
        }
        apply(alpha, to: &rgba)
    }

    /// Scales each pixel's premultiplied colour and alpha.
    private static func apply(_ alpha: [Double], to rgba: inout [UInt8]) {
        for p in 0..<alpha.count where alpha[p] < 1 {
            for c in 0..<4 { rgba[p * 4 + c] = UInt8((Double(rgba[p * 4 + c]) * alpha[p]).rounded()) }
        }
    }

    /// The frame's edges the subject runs into, as `Edge` bits: more than a
    /// sliver of opaque pixels along them.
    static func cutEdges(_ rgba: [UInt8], side: Int) -> UInt8 {
        var bits: UInt8 = 0
        let edges: [(UInt8, (Int) -> Int)] = [
            (Edge.left, { $0 * side }), (Edge.right, { $0 * side + side - 1 }),
            (Edge.top, { $0 }), (Edge.bottom, { (side - 1) * side + $0 }),
        ]
        for (bit, pixel) in edges {
            let opaque = (0..<side).filter { rgba[pixel($0) * 4 + 3] > 128 }.count
            if Double(opaque) > Double(side) * 0.04 { bits |= bit }
        }
        return bits
    }

    enum Edge {
        static let left: UInt8 = 1, right: UInt8 = 2, top: UInt8 = 4, bottom: UInt8 = 8
    }

    /// Turned by `degrees` (positive is clockwise on screen) about the
    /// centre, onto a canvas big enough to keep every corner; `beyond` says,
    /// for each pixel, past which of the picture's edges it came from (0:
    /// from inside, short of the frame's last rows — the frame's own clip is
    /// not the subject's edge).
    static func rotate(_ rgba: [UInt8], side: Int, degrees: Double) -> ([UInt8], Int, [UInt8]) {
        let a = degrees * .pi / 180
        let outSide = Int((Double(side) * (abs(cos(a)) + abs(sin(a)))).rounded(.up))
        var out = [UInt8](repeating: 0, count: outSide * outSide * 4)
        var beyond = [UInt8](repeating: 0, count: outSide * outSide)
        let keep = Double(side) * 0.012
        let c = Double(side) / 2, oc = Double(outSide) / 2
        for y in 0..<outSide {
            for x in 0..<outSide {
                // Back into the source: the inverse turn.
                let u = Double(x) + 0.5 - oc, v = Double(y) + 0.5 - oc
                let sx = u * cos(a) + v * sin(a) + c - 0.5
                let sy = -u * sin(a) + v * cos(a) + c - 0.5
                sample(rgba, side: side, x: sx, y: sy, into: &out, at: (y * outSide + x) * 4)
                var bits: UInt8 = 0
                if sx < keep { bits |= Edge.left }
                if sx > Double(side - 1) - keep { bits |= Edge.right }
                if sy < keep { bits |= Edge.top }
                if sy > Double(side - 1) - keep { bits |= Edge.bottom }
                beyond[y * outSide + x] = bits
            }
        }
        return (out, outSide, beyond)
    }

    /// An eye, through the same turn as the picture.
    static func turn(_ eye: EyeFinder.Eye, side: Int, into outSide: Int, degrees: Double) -> EyeFinder.Eye {
        let a = degrees * .pi / 180
        let dx = eye.cx * Double(side) - Double(side) / 2, dy = eye.cy * Double(side) - Double(side) / 2
        let x = dx * cos(a) - dy * sin(a), y = dx * sin(a) + dy * cos(a)
        var e = eye
        e.cx = (x + Double(outSide) / 2) / Double(outSide)
        e.cy = (y + Double(outSide) / 2) / Double(outSide)
        e.length = eye.length * Double(side) / Double(outSide)
        e.width = eye.width * Double(side) / Double(outSide)
        e.tilt = eye.tilt + degrees
        return e
    }

    static func opaqueBox(_ rgba: [UInt8], side: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = side, minY = side, maxX = -1, maxY = -1
        for p in 0..<(side * side) where rgba[p * 4 + 3] > 24 {
            let x = p % side, y = p / side
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        return maxX < 0 ? nil : (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// The square `crop` (x, y, side; may reach past the canvas, which is
    /// transparent there) scaled to `out`.
    static func resample(_ rgba: [UInt8], side: Int, crop: (Int, Int, Int), out: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: out * out * 4)
        let scale = Double(crop.2) / Double(out)
        for y in 0..<out {
            for x in 0..<out {
                sample(rgba, side: side, x: Double(crop.0) + (Double(x) + 0.5) * scale - 0.5,
                       y: Double(crop.1) + (Double(y) + 0.5) * scale - 0.5, into: &result, at: (y * out + x) * 4)
            }
        }
        return result
    }

    /// Bilinear, transparent outside the canvas.
    private static func sample(_ rgba: [UInt8], side: Int, x: Double, y: Double, into out: inout [UInt8], at o: Int) {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Double(x0), fy = y - Double(y0)
        var acc = [0.0, 0.0, 0.0, 0.0]
        for (dx, dy, w) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
            let px = x0 + dx, py = y0 + dy
            guard w > 0, px >= 0, py >= 0, px < side, py < side else { continue }
            let i = (py * side + px) * 4
            for c in 0..<4 { acc[c] += Double(rgba[i + c]) * w }
        }
        for c in 0..<4 { out[o + c] = UInt8(min(255, max(0, acc[c].rounded()))) }
    }
}
