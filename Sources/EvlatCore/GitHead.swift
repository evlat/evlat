import Foundation

/// The branch a folder is on, read from git's own files: no `git` process,
/// no permission. It tells apart sessions that share a name — the same repo
/// open in several worktrees, whose folders all end in the repo's name.
///
/// Two layouts are read:
/// - a repository: `<root>/.git/` is a directory holding `HEAD`;
/// - a worktree: `<root>/.git` is a file saying `gitdir: <path>`, and that
///   directory (`<repo>/.git/worktrees/<name>/`) holds the worktree's own
///   `HEAD`. The path may be relative to the file, as git allows.
///
/// The folder comes from a hook body on the loopback, so `HEAD` is held to
/// the two shapes git writes — `ref: refs/heads/<name>` and a bare commit id —
/// and anything else reads as no branch: what lands on the bar is a branch
/// name or nothing, never a stranger's file content.
public enum GitHead {
    /// How much of `HEAD` is read. git's own is one short line; a file
    /// longer than this is not one git wrote.
    static let readLimit = 512
    /// How many parents are climbed looking for `.git`: a session runs in a
    /// subfolder of its repo as often as at its root.
    static let climbLimit = 64
    /// A detached `HEAD` is drawn as git's short id.
    static let shortIDLength = 7

    /// The branch, or the short commit id when `HEAD` is detached; `nil`
    /// outside a repository and for anything git did not write.
    public static func branch(in directory: String) -> String? {
        guard directory.hasPrefix("/"), let gitDir = gitDirectory(above: directory),
              let head = read(gitDir + "/HEAD") else { return nil }
        return parse(head)
    }

    /// `HEAD`'s text to what the bar draws. Pure, for the tests.
    static func parse(_ head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) {
            let name = String(line.dropFirst(prefix.count))
            return isBranchName(name) ? name : nil
        }
        // SHA-1 or SHA-256, all hex.
        let hex = Set("0123456789abcdef")
        guard line.count == 40 || line.count == 64, line.allSatisfy(hex.contains) else { return nil }
        return String(line.prefix(shortIDLength))
    }

    /// What git itself refuses in a branch name, roughly: empty, control
    /// characters, a space. A name of 255 bytes or more is not drawn either.
    static func isBranchName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count < 255
            && !name.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7F }
    }

    /// The directory holding this folder's `HEAD`: the nearest `.git` above
    /// it, followed through a worktree's `gitdir:` line.
    static func gitDirectory(above directory: String) -> String? {
        var folder = (directory as NSString).standardizingPath
        for _ in 0..<climbLimit {
            let dotGit = folder + "/.git"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dotGit }
                guard let text = read(dotGit) else { return nil }
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("gitdir: ") else { return nil }
                let target = String(line.dropFirst("gitdir: ".count))
                return target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target)
            }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder { return nil }
            folder = parent
        }
        return nil
    }

    private static func read(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: readLimit), data.count < readLimit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
