// Draws Evlat's app icon ("B2 · Çerçeve", "frame": the bar's black as a
// frame, the mascot's two eyes looking toward the screen edge) into an
// .iconset.
//
// The icon is code, not a checked-in image: this file is its only source, and
// bundle-app.sh turns the iconset into AppIcon.icns with `iconutil`. No new
// dependency — AppKit and CoreGraphics only.
//
//   swift scripts/make-icon.swift <out.iconset>
//
// Geometry is on Apple's 1024 grid (body 824 pt with a 100 pt margin), the
// same numbers as the approved sketch, y measured from the top.
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

/// A rounded rect on the 1024 grid, y from the top.
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: 1024 - y - h, width: w, height: h), xRadius: r, yRadius: r)
}

/// Fills top-to-bottom, the way the sketch's `linearGradient y1=0 y2=1` did.
func fill(_ path: NSBezierPath, top: UInt32, bottom: UInt32) {
    NSGradient(starting: color(top), ending: color(bottom))!.draw(in: path, angle: -90)
}

func draw() {
    fill(rect(100, 100, 824, 824, 185), top: 0x5a5d63, bottom: 0x1c1e21)   // frame: the bar's black
    fill(rect(136, 136, 752, 752, 152), top: 0xfbfaf7, bottom: 0xe4e2dc)   // face
    color(0x15171a).setFill()
    rect(508, 382, 88, 260, 44).fill()                                      // eyes, looking
    rect(658, 382, 88, 260, 44).fill()                                      // toward the edge
}

func png(pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    NSAffineTransform().then { $0.scale(by: scale); $0.concat() }
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSAffineTransform {
    func then(_ body: (NSAffineTransform) -> Void) { body(self) }
}

// iconutil's names: every point size at 1x and 2x.
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: out.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
