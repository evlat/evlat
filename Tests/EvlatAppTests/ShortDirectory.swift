import Foundation

/// A directory short enough for a unix socket's address (104 bytes, NUL
/// included): `$TMPDIR` plus a UUID is not. `/tmp/evlat-<8 hex>`, new for
/// every test — the suite runs in parallel — and removed by its owner.
enum ShortDirectory {
    static func make() throws -> String {
        let path = "/tmp/evlat-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return path
    }

    static func remove(_ path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
