import Foundation
import EvlatCore

/// The sending half of `/signal`: `Evlat signal`, `Evlat
/// watch` and `--list`'s probes post through here.
///
/// The commands post to Evlat's socket (`EvlatSocket`), found by the app's
/// own rule on every call, and send no key: only the user's processes can
/// reach it. Evlat not running, no socket, a refused connection, a timeout:
/// all **silent** — a build must not fail, or print, because the bar is not
/// there.
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
        /// Nobody to tell: not running, no socket, no answer in time.
        case silent
        /// The endpoint said no (`400`/`403`/`404`…): the one case a sender
        /// has a mistake to fix. The text is one line.
        case refused(String)
    }

    static let timeout: TimeInterval = 2

    /// `post` to the Evlat this environment points at.
    static func post(_ post: SignalCommand.Post,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: String = NSHomeDirectory()) -> Outcome {
        guard let socket = EvlatSocket.path(environment: environment, home: home) else { return .silent }
        switch send(post.body, socket: socket, timeout: timeout) {
        case .status(200, _): return .delivered
        case .status(let code, let body): return .refused(refusal(code: code, body: body))
        case .notRunning, .failed: return .silent
        }
    }

    /// One `POST /signal` to the socket, answered or given up within
    /// `timeout`.
    static func send(_ body: Data, socket: String, timeout: TimeInterval) -> Answer {
        switch UnixHTTP.send(SignalReport.path, socket: socket,
                             headers: [("Content-Type", "application/json")], body: body, timeout: timeout) {
        case .status(let code, let data): return .status(code, String(decoding: data, as: UTF8.self))
        case .notRunning: return .notRunning
        case .timeout: return .failed("no answer within \(timeout) s")
        case .failed(let reason): return .failed(reason)
        }
    }

    /// One keyed `POST /signal` to a loopback port, answered or given up
    /// within `timeout`: `--list`'s probe of the port, which still asks for
    /// the key.
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
