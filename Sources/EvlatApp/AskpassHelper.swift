import Foundation
import EvlatCore

/// The binary as `ssh`'s askpass helper (`LaunchMode.askpass`): the prompt
/// goes to the running Evlat's `/askpass`, the answer comes back on stdout.
///
/// `ssh` reads stdout as the answer and the exit code as whether there is
/// one: exit `0` with `answer\n`, or a non-zero exit with **nothing** written,
/// on which `ssh` sends no password at all — no failed attempt reaches the
/// server's log (measured, `.tasks/017` → Kanıt). So every failure here is
/// silent and non-zero.
public enum AskpassHelper {
    /// Asks and exits. The port and the token come from the mark, never from
    /// `EVLAT_PORT` or a key file: they name the Evlat that started this
    /// `ssh`. The token travels in a header, never in an argv.
    public static func run(_ argv: [String], mark: Askpass.Mark) -> Never {
        let prompt = argv.count > 1 ? argv[1] : ""
        guard let answer = ask(prompt, mark: mark) else { exit(1) }
        FileHandle.standardOutput.write(answer + Data("\n".utf8))
        exit(0)
    }

    /// The answer's bytes, or `nil` for anything but a `200`.
    ///
    /// No timeout of its own: the user may take their time over the prompt,
    /// and if `ssh` gives up it closes the pipe and the helper goes with it;
    /// the held connection then reads as abandoned on Evlat's side.
    static func ask(_ prompt: String, mark: Askpass.Mark) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(mark.port)\(Askpass.path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(mark.token, forHTTPHeaderField: Askpass.header)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(prompt.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        // URLSession's default gives up after 60 s of silence; the answer is
        // a person's, so it waits as long as `ssh` does — a week stands for
        // "no limit" (the resource default), not an infinity the
        // framework's arithmetic has to survive.
        configuration.timeoutIntervalForRequest = 7 * 24 * 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        // Loopback only; a system proxy has no business here.
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var answer: Data?
        session.dataTask(with: request) { data, response, error in
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                lock.withLock { answer = data ?? Data() }
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return lock.withLock { answer }
    }
}
