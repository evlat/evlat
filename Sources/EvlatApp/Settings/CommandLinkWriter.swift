import Foundation
import EvlatCore

/// Writes and takes away `~/.local/bin/evlat` (`CommandLink` reads it). The
/// state is read again at the write, not trusted from the row: what the
/// consent line showed is what `replacing` says was agreed to.
enum CommandLinkWriter {
    enum Failure: Error, Equatable {
        /// Not Evlat's: never written over or removed.
        case foreign
        /// Another copy's or a broken link, and the consent did not say so.
        case notAgreed
        /// There is nothing of this copy's to remove.
        case nothingToRemove
        case unwritable
    }

    /// Makes `link` point at `binary`. `replacing` is the consent to write
    /// over another Evlat's link or a broken one.
    static func install(at link: URL, binary: URL, replacing: Bool) throws {
        switch CommandLink.state(at: link, binary: binary) {
        case .current: return
        case .foreign: throw Failure.foreign
        case .otherCopy, .broken:
            guard replacing else { throw Failure.notAgreed }
            try swap(link, to: binary)
        case .missing:
            do {
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
            } catch {
                throw Failure.unwritable
            }
        }
    }

    /// Only this copy's link goes; another copy's is its own to remove.
    static func remove(at link: URL, binary: URL) throws {
        guard CommandLink.state(at: link, binary: binary) == .current else {
            throw CommandLink.state(at: link, binary: binary) == .foreign
                ? Failure.foreign : Failure.nothingToRemove
        }
        do { try FileManager.default.removeItem(at: link) } catch { throw Failure.unwritable }
    }

    /// A new link beside the old one, renamed over it: the path is never
    /// empty, and a failure leaves the old link as it was.
    private static func swap(_ link: URL, to binary: URL) throws {
        let fresh = link.deletingLastPathComponent()
            .appendingPathComponent(".\(link.lastPathComponent).evlat-\(UUID().uuidString)")
        do {
            try FileManager.default.createSymbolicLink(at: fresh, withDestinationURL: binary)
        } catch {
            throw Failure.unwritable
        }
        guard rename(fresh.path, link.path) == 0 else {
            try? FileManager.default.removeItem(at: fresh)
            throw Failure.unwritable
        }
    }
}
