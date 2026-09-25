import Foundation
import EvlatCore

/// The sending half of `/signal` (`012/phase-4`): `Evlat signal`, `Evlat
/// watch` and `--list`'s probe post through here.
///
/// The key is read **on every call** (`SignalKey`) and the port resolved the
/// way the app resolves it (`EVLAT_PORT`), so a watch that outlives an Evlat
/// restart finds the new key on its next heartbeat. Evlat not running, no
/// key file, a refused connection, a timeout: all **silent** — a build must
/// not fail, or print, because the bar is not there.
enum SignalClient {
    /// What came back from one POST.
    enum Answer: Equatable {
        case status(Int, String)
        case notRunning
        case failed(String)
    }

    /// What a command makes of it.
    enum Outcome: Equatable {
        case delivered
        /// Nobody to tell: not running, no key, no answer in time.
        case silent
        /// The endpoint said no (`400`/`403`/`404`…): the one case a sender
        /// has a mistake to fix. The text is one line.
        case refused(String)
    }

    static let timeout: TimeInterval = 2

    /// `post` to the Evlat this environment points at.
    static func post(_ post: SignalCommand.Post,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Outcome {
        let port = HookListener.resolvePort(environment).port
        guard let file = SignalKey.location(port: port, environment: environment),
              let key = SignalKey.read(from: file) else { return .silent }
        switch send(post.body, port: port, key: key, timeout: timeout) {
        case .status(200, _): return .delivered
        case .status(let code, let body): return .refused(refusal(code: code, body: body))
        case .notRunning, .failed: return .silent
        }
    }

    /// One keyed `POST /signal`, answered or given up within `timeout`.
    static func send(_ body: Data, port: UInt16, key: String, timeout: TimeInterval) -> Answer {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(SignalReport.path)") else {
            return .failed("unreadable address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: SignalReport.keyHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // Loopback only; a system proxy has no business here.
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var answer: Answer?
        session.dataTask(with: request) { data, response, error in
            let result: Answer
            if let error = error as? URLError, error.code == .cannotConnectToHost {
                result = .notRunning
            } else if let error {
                result = .failed(error.localizedDescription)
            } else {
                result = .status((response as? HTTPURLResponse)?.statusCode ?? -1,
                                 data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            }
            lock.withLock { answer = result }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return lock.withLock { answer } ?? .failed("no answer within \(timeout + 1) s")
    }

    /// `400 invalidTtl: ttl must be …` — the route's stable code and its
    /// message when the body carries them.
    static func refusal(code: Int, body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let name = error["code"] as? String else { return "\(code)" }
        // Whatever holds the port wrote this, and it goes to a terminal:
        // cleaned like a sender's text, so no escape sequence reaches it.
        let line = "\(name)" + ((error["message"] as? String).map { ": \($0)" } ?? "")
        return "\(code) " + SignalReport.clean(line, limit: SignalReport.detailLimit)
    }
}

/// `Evlat signal` and `Evlat watch`: the process never becomes an app.
public enum CommandMode {
    /// Runs the subcommand in `argv[1]` and exits; returns when there is none.
    public static func runIfAsked(_ argv: [String] = CommandLine.arguments) {
        guard SignalCommand.subcommand(argv) != nil else { return }
        switch SignalCommand.parse(Array(argv.dropFirst())) {
        case .failure(let error):
            FileHandle.standardError.write(Data("Evlat: \(error.message)\n\(SignalCommand.usage)\n".utf8))
            exit(SignalCommand.usageExitCode)
        case .success(.help):
            print(SignalCommand.usage)
            exit(0)
        case .success(.signal(let post)):
            exit(signal(post))
        case .success(.watch(let watch)):
            Watch.run(watch)
        }
    }

    /// `0` when delivered or when there was nobody to deliver to; `1` with
    /// one stderr line when the endpoint refused — the sender's mistake,
    /// worth seeing, and a script can test for it.
    static func signal(_ post: SignalCommand.Post) -> Int32 {
        switch SignalClient.post(post) {
        case .delivered, .silent:
            return 0
        case .refused(let reason):
            FileHandle.standardError.write(Data("Evlat: signal \(post.id) refused (\(reason))\n".utf8))
            return 1
        }
    }
}
