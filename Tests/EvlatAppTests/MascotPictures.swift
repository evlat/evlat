import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pictures the mascot tests draw for themselves, so no image is checked
/// in: a grid of solid cells, each its own colour.
enum MascotPictures {
    /// The colour of cell `index`: distinct for every index the tests use.
    static func color(of index: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        (UInt8(40 + (index * 53) % 200), UInt8(40 + (index * 97) % 200), UInt8(40 + (index * 31) % 200))
    }

    /// A PNG of `columns` × `rows` cells of `cell` pixels; cells past
    /// `filled` are left transparent, as a pet sheet's unused cells are.
    @discardableResult
    static func grid(at url: URL, columns: Int, rows: Int, cell: (width: Int, height: Int),
                     filled: Int? = nil) throws -> URL {
        let width = columns * cell.width, height = rows * cell.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for index in 0..<min(filled ?? columns * rows, columns * rows) {
            let c = color(of: index)
            context.setFillColor(red: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255,
                                 blue: CGFloat(c.blue) / 255, alpha: 1)
            // Core Graphics counts rows from the bottom; the sheet's from the top.
            let row = index / columns, column = index % columns
            context.fill(CGRect(x: column * cell.width, y: height - (row + 1) * cell.height,
                                width: cell.width, height: cell.height))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// The colour at the centre of `image`, unpremultiplied enough for solid
    /// cells.
    static func centre(of image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2,
                                        width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    /// A fresh folder of the test's own.
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("evlat-mascot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
