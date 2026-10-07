import Foundation

/// `Tests/Fixtures/fake-ssh` behind a wrapper of the test's own: the
/// wrapper names the "server's" home, the log and whatever else the test
/// fixes, so every call reaches them — the master, which `RemoteTunnels`
/// starts with the tunnel's environment, and the calls over it, which
/// `RemoteInstaller` starts with the test process's.
///
/// A value the tunnel's environment already sets (a prompt, a log) wins:
/// the wrapper only fills what is missing.
enum FakeSSH {
    static var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake-ssh").path
    }

    /// The wrapper's path. `home` is the server's home: short, since the
    /// probe's socket lives under it (`EvlatSocket.pathLimit`).
    static func make(in directory: URL, name: String = "fake-ssh", home: String, log: URL? = nil,
                     environment: [String: String] = [:]) throws -> String {
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        var values = environment
        values["FAKE_SSH_HOME"] = home
        if let log { values["FAKE_SSH_LOG"] = log.path }
        let exports = values.keys.sorted().map { name in
            "\(name)=${\(name)-\(quoted(values[name]!))}\nexport \(name)"
        }.joined(separator: "\n")
        let script = directory.appendingPathComponent(name)
        try """
            #!/bin/sh
            \(FreshExecutable.warmLine)
            \(exports)
            exec \(quoted(fixture)) "$@"

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        FreshExecutable.warm(script.path)
        FreshExecutable.warm(fixture)
        return script.path
    }

    /// The arguments of each run in `log` (the masters'), or of its calls.
    static func runs(in log: URL, calls: Bool = false) -> [[String]] {
        let path = calls ? log.path + ".calls" : log.path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "--- run\n").dropFirst().map {
            $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
