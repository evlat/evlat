import Foundation
import CoreGraphics
import ImageIO

/// A picture cut into a grid of cells, drawn one cell at a time
/// (`MascotShape.cells`): the frames of a character drawn as pictures
/// rather than shapes.
///
/// Read lazily. Finding a character reads only the picture's size
/// (`pixelSize(of:)`); its pixels are decoded the first time a cell is
/// drawn, at most `cellHeight` pixels a cell — enough for the bar's mascot
/// and the Settings tiles at 2×, a fraction of a full sheet's memory. A
/// picture that cannot be decoded draws nothing.
///
/// Main thread only, as the views that draw it are. One sheet per file
/// version (`sheet(at:columns:rows:)`): a rescan finds the same object, so
/// the picker's tiles neither decode again nor read as changed.
final class MascotSheet: Equatable {
    let url: URL
    let columns: Int
    let rows: Int

    /// Pixels a decoded cell is tall, at most.
    static let cellHeight = 96

    private var decoded: [CGImage?]?

    private init(url: URL, columns: Int, rows: Int) {
        self.url = url
        self.columns = columns
        self.rows = rows
    }

    static func == (a: MascotSheet, b: MascotSheet) -> Bool { a === b }

    private static var made: [String: MascotSheet] = [:]

    /// The sheet for this file as it is now: the one made before when the
    /// file has not changed since.
    static func sheet(at url: URL, columns: Int, rows: Int) -> MascotSheet {
        // Asked of the file system each time: a `URL` keeps the values it
        // read once.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = [url.path, "\(columns)x\(rows)", "\((attributes?[.size] as? Int) ?? -1)",
                   "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"].joined(separator: "|")
        if let sheet = made[key] { return sheet }
        let sheet = MascotSheet(url: url, columns: columns, rows: rows)
        made[key] = sheet
        return sheet
    }

    /// A picture's size in pixels, read from its header without decoding
    /// it; `nil` when it is not a picture ImageIO reads (PNG and WebP are).
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// The cell at `index`, row by row from the top left; `nil` outside the
    /// grid or when the picture could not be decoded.
    func cell(_ index: Int) -> CGImage? {
        let cells = decoded ?? decode()
        return cells.indices.contains(index) ? cells[index] : nil
    }

    private func decode() -> [CGImage?] {
        var cells: [CGImage?] = []
        if let size = Self.pixelSize(of: url), size.height > 0,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            // The thumbnail's cap is on its longer side; the cells' is on
            // their height.
            let scale = min(1, Double(Self.cellHeight * rows) / Double(size.height))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int((Double(max(size.width, size.height)) * scale).rounded())
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                decoded = cells
                return cells
            }
            let width = Double(image.width) / Double(columns)
            let height = Double(image.height) / Double(rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    let x = (Double(column) * width).rounded(), y = (Double(row) * height).rounded()
                    let rect = CGRect(x: x, y: y, width: (Double(column + 1) * width).rounded() - x,
                                      height: (Double(row + 1) * height).rounded() - y)
                    cells.append(image.cropping(to: rect))
                }
            }
        }
        decoded = cells
        return cells
    }
}
