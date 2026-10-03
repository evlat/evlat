import AppKit
import EvlatCore

/// Makes the user's character from a picture with the user's own agent —
/// the catalogue's `imageMaker`, today Codex (`codex exec`, image generation,
/// the picture attached): it draws a bot icon by the user's prompt, and
/// `Portrait.make` finds its eyes and stores it.
///
/// **Evlat ships no prompt.** The user brings one (`paste`, kept as
/// `prompt.md` beside the character); Settings links the one this was built
/// for, Serio_ai's Grokbot Icon prompt (CC BY-NC 4.0), at its source, under
/// its own license. Any prompt that draws two solid near-black capsule eyes on
/// a flat face works (`EyeFinder`).
///
/// Nothing leaves the Mac through Evlat: the picture goes where the user's
/// agent sends it, under the user's own login and plan. The run is Evlat's
/// errand (`EVLAT_TASK`), so its hook events neither add a session to the bar
/// nor play a sound.
@MainActor
final class CharacterMaker {
    enum State: Equatable {
        case idle
        case working
        case failed(Portrait.MakeError)
    }

    private(set) var state = State.idle
    var onChange: () -> Void = {}
    /// Codex, the maker measured, took under two minutes at its slowest; this
    /// bounds a stuck run.
    nonisolated static let timeout: TimeInterval = 6 * 60

    /// The prompt Codex is given: the user's own, `prompt.md` beside the
    /// character; `nil` until one is pasted.
    static func prompt(home: URL?) -> String? {
        guard let home,
              let own = try? String(contentsOf: promptFile(home: home), encoding: .utf8),
              !own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return own
    }

    static func promptFile(home: URL) -> URL {
        Portrait.folder(home: home).appendingPathComponent("prompt.md")
    }

    /// Where the prompt this was built for is published, with its license.
    static let promptSource = URL(string: "https://grokbot-icon-studio.serio-ai.chatgpt.site/")!

    /// Keeps `text` as the user's prompt; empty text keeps nothing.
    @discardableResult
    static func savePrompt(_ text: String, home: URL) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: Portrait.folder(home: home), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: promptFile(home: home), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The line after the prompt that says where to put the icon.
    static let outputLine = "\n\n[Output]\nGenerate the icon from the attached image, then save the final PNG in the current directory as icon.png.\n"

    /// `executable` is the maker's program as its locator found it (`nil`:
    /// not on this Mac); `name` is how a failure names the maker.
    func generate(from picture: URL, home: URL, maker: ImageMaker, name: String,
                  executable: String?, path: String?, done: @escaping (Portrait?) -> Void) {
        guard state != .working else { return }
        guard let base = Self.prompt(home: home) else { return finish(.failure(.noPrompt), done) }
        guard let executable else { return finish(.failure(.makerMissing), done) }
        set(.working)
        let prompt = base + Self.outputLine
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(executable, arguments: maker.arguments, name: name,
                                  picture: picture, prompt: prompt, path: path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error): self.finish(.failure(error), done)
                case .success(let icon): self.finish(Portrait.make(from: icon, home: home), done)
                }
            }
        }
    }

    /// An icon made elsewhere: only the eyes are found.
    func importIcon(_ url: URL, home: URL, done: @escaping (Portrait?) -> Void) {
        guard let image = NSImage(contentsOf: url) else { return finish(.failure(.unreadable), done) }
        finish(Portrait.make(from: image, home: home), done)
    }

    private func finish(_ result: Result<Portrait, Portrait.MakeError>, _ done: (Portrait?) -> Void) {
        switch result {
        case .success(let portrait):
            set(.idle)
            done(portrait)
        case .failure(let error):
            set(.failed(error))
            done(nil)
        }
    }

    private func set(_ state: State) {
        self.state = state
        onChange()
    }

    /// One run in a fresh folder of its own, which is also all its sandbox
    /// may write. Off the main queue.
    nonisolated static func run(_ executable: String, arguments: (String) -> [String], name: String,
                                picture: URL, prompt: String,
                                path: String?) -> Result<NSImage, Portrait.MakeError> {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("evlat-character-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("picture." + (picture.pathExtension.isEmpty ? "png" : picture.pathExtension))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: picture, to: input)
        } catch {
            return .failure(.unreadable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(input.path)
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        if let path { environment["PATH"] = path }
        environment[TurnLaunch.taskVariable] = "character-\(UUID().uuidString)"
        process.environment = environment
        let stdin = Pipe(), output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        let log = LogTail()
        output.fileHandleForReading.readabilityHandler = { log.append($0.availableData) }
        do { try process.run() } catch { return .failure(.makerMissing) }
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        if ended.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            output.fileHandleForReading.readabilityHandler = nil
            return .failure(.generationFailed("\(name) took longer than \(Int(timeout / 60)) minutes."))
        }
        output.fileHandleForReading.readabilityHandler = nil
        guard let icon = NSImage(contentsOf: folder.appendingPathComponent("icon.png")) else {
            return .failure(.generationFailed(log.tail))
        }
        return .success(icon)
    }

    /// The last lines the maker printed, for the failure line.
    private final class LogTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk)
            if data.count > 8192 { data = data.suffix(8192) }
            lock.unlock()
        }
        var tail: String {
            lock.lock(); defer { lock.unlock() }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(3)
            return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
    }
}
