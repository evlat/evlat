import Foundation

/// Finds the two eyes in a bot icon and paints them out, so the mascot can
/// draw its own — eyes that blink, follow the cursor and squint — where the
/// picture had them.
///
/// The icon is the one the character prompt asks for: flat colour regions,
/// exactly two near-black capsule eyes, a near-black background. That makes
/// this a decidable question for code, not a model: the eyes are the dark
/// regions that do **not** touch the picture's edge (the background does),
/// that are solid (a glasses rim is a ring), capsule-shaped (2.5–3 times as
/// long as wide), and of matching size. Anything else is an icon this cannot
/// use, and is said so instead of guessed at.
///
/// Pure over an RGBA buffer, so every rule is tested on pixels.
public enum EyeFinder {
    /// One eye, in fractions of the picture's side.
    public struct Eye: Equatable, Codable {
        public var cx: Double
        public var cy: Double
        /// The long axis and the short one.
        public var length: Double
        public var width: Double
        /// How far the long axis leans from upright, clockwise, in degrees.
        public var tilt: Double

        public init(cx: Double, cy: Double, length: Double, width: Double, tilt: Double) {
            self.cx = cx; self.cy = cy; self.length = length; self.width = width; self.tilt = tilt
        }
    }

    public enum Failure: Error, Equatable {
        /// Not two eye-shaped dark regions: how many there were.
        case eyesNotFound(Int)
        /// Two, but one much bigger than the other.
        case eyesDoNotMatch
        case badBuffer
    }

    public struct Found: Equatable {
        /// Left eye first.
        public let eyes: [Eye]
        /// The picture with the eyes painted over in the face around them.
        public let cleaned: [UInt8]
    }

    /// Below this mean brightness a pixel is dark.
    static let darkLevel = 70
    /// A region smaller than this share of the picture is noise.
    static let minimumShare = 0.0004
    static let ratios: ClosedRange<Double> = 1.8...4.5
    /// How much of its own ellipse a solid capsule fills; a ring fills little.
    static let minimumFill = 0.8

    public static func find(rgba: [UInt8], width: Int, height: Int) -> Result<Found, Failure> {
        guard width > 2, height > 2, rgba.count == width * height * 4 else { return .failure(.badBuffer) }
        let count = width * height
        var dark = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let sum = Int(rgba[i * 4]) + Int(rgba[i * 4 + 1]) + Int(rgba[i * 4 + 2])
            dark[i] = sum < darkLevel * 3
        }
        var label = [Int32](repeating: 0, count: count)
        var regions: [(id: Int32, pixels: [Int], eye: Eye, fill: Double)] = []
        var next: Int32 = 0
        var stack: [Int] = []
        for start in 0..<count where dark[start] && label[start] == 0 {
            next += 1
            label[start] = next
            stack.append(start)
            var pixels: [Int] = []
            var touchesEdge = false
            while let i = stack.popLast() {
                pixels.append(i)
                let x = i % width, y = i / width
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { touchesEdge = true }
                for n in [x > 0 ? i - 1 : -1, x < width - 1 ? i + 1 : -1,
                          y > 0 ? i - width : -1, y < height - 1 ? i + width : -1]
                where n >= 0 && dark[n] && label[n] == 0 {
                    label[n] = next
                    stack.append(n)
                }
            }
            guard !touchesEdge, Double(pixels.count) >= minimumShare * Double(count),
                  let (eye, fill) = shape(of: pixels, width: width, height: height) else { continue }
            regions.append((next, pixels, eye, fill))
        }
        let capsules = regions
            .filter { ratios.contains($0.eye.length / max($0.eye.width, 1e-9)) && $0.fill >= minimumFill }
            .sorted { $0.pixels.count > $1.pixels.count }
        guard capsules.count >= 2 else { return .failure(.eyesNotFound(capsules.count)) }
        let pair = Array(capsules.prefix(2))
        let sizes = Double(pair[0].pixels.count) / Double(pair[1].pixels.count)
        guard (0.7...1.43).contains(sizes) else { return .failure(.eyesDoNotMatch) }
        var cleaned = rgba
        for region in pair {
            paintOut(region.pixels, label: region.id, labels: label, dark: dark,
                     in: &cleaned, width: width, height: height)
        }
        let eyes = pair.map(\.eye).sorted { $0.cx < $1.cx }
        return .success(Found(eyes: eyes, cleaned: cleaned))
    }

    /// The region as an ellipse of the same spread (its covariance), and
    /// how much of that ellipse it fills.
    static func shape(of pixels: [Int], width: Int, height: Int) -> (Eye, Double)? {
        let n = Double(pixels.count)
        var sx = 0.0, sy = 0.0
        for i in pixels { sx += Double(i % width); sy += Double(i / width) }
        let mx = sx / n, my = sy / n
        var xx = 0.0, yy = 0.0, xy = 0.0
        for i in pixels {
            let dx = Double(i % width) - mx, dy = Double(i / width) - my
            xx += dx * dx; yy += dy * dy; xy += dx * dy
        }
        xx /= n; yy /= n; xy /= n
        let mean = (xx + yy) / 2
        let spread = sqrt(max(0, (xx - yy) * (xx - yy) / 4 + xy * xy))
        let major = 4 * sqrt(max(0, mean + spread)), minor = 4 * sqrt(max(0, mean - spread))
        guard major > 0, minor > 0 else { return nil }
        // The long axis' direction, measured from upright (y down), turned
        // so a top leaning right is a positive, clockwise tilt.
        var degrees = 0.5 * atan2(2 * xy, yy - xx) * 180 / .pi
        degrees = -degrees
        let fill = n / (.pi / 4 * major * minor)
        let side = Double(max(width, height))
        return (Eye(cx: mx / Double(width), cy: my / Double(height),
                    length: major / side, width: minor / side, tilt: degrees), fill)
    }

    /// Covers an eye, and a little around its antialiased edge, with the
    /// median colour of the face just outside it.
    static func paintOut(_ pixels: [Int], label id: Int32, labels: [Int32], dark: [Bool],
                         in buffer: inout [UInt8], width: Int, height: Int) {
        let grow = max(2, Int(Double(max(width, height)) * 0.012))
        let ring = grow * 3
        var minX = width, minY = height, maxX = 0, maxY = 0
        for i in pixels {
            minX = min(minX, i % width); maxX = max(maxX, i % width)
            minY = min(minY, i / width); maxY = max(maxY, i / width)
        }
        // Distance (in steps) from the eye, out to the ring, by a breadth-first walk.
        let x0 = max(0, minX - ring), x1 = min(width - 1, maxX + ring)
        let y0 = max(0, minY - ring), y1 = min(height - 1, maxY + ring)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var distance = [Int](repeating: Int.max, count: w * h)
        var queue: [Int] = []
        for i in pixels {
            let local = (i / width - y0) * w + (i % width - x0)
            distance[local] = 0
            queue.append(local)
        }
        var head = 0
        while head < queue.count {
            let local = queue[head]; head += 1
            let d = distance[local]
            guard d < ring else { continue }
            let lx = local % w, ly = local / w
            for (nx, ny) in [(lx - 1, ly), (lx + 1, ly), (lx, ly - 1), (lx, ly + 1)]
            where nx >= 0 && ny >= 0 && nx < w && ny < h && distance[ny * w + nx] == Int.max {
                distance[ny * w + nx] = d + 1
                queue.append(ny * w + nx)
            }
        }
        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        for local in 0..<(w * h) where distance[local] > grow && distance[local] <= ring {
            let i = (local / w + y0) * width + (local % w + x0)
            guard !dark[i] else { continue }
            reds.append(buffer[i * 4]); greens.append(buffer[i * 4 + 1]); blues.append(buffer[i * 4 + 2])
        }
        guard !reds.isEmpty else { return }
        let fill = [median(reds), median(greens), median(blues)]
        for local in 0..<(w * h) where distance[local] <= grow {
            let i = (local / w + y0) * width + (local % w + x0)
            buffer[i * 4] = fill[0]; buffer[i * 4 + 1] = fill[1]; buffer[i * 4 + 2] = fill[2]
            buffer[i * 4 + 3] = 255
        }
    }

    private static func median(_ values: [UInt8]) -> UInt8 { values.sorted()[values.count / 2] }
}
