import Foundation
import EvlatCore

/// The sending half of `/signal`: `Evlat signal`, `Evlat
/// watch` and `--list`'s probe post through here.
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
        /// The endpoint said no (`400`/`404`…): the one case a sender
        /// has a mistake to fix. The text is one line.
        case refused(String)
    }

    static let timeout: TimeInterval = 2

    /// `post` to the Evlat this environment points at.
    static func post(_ post: SignalCommand.Post,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: String = NSHomeDirectory()) -> Outcome {
        // An old isolation recipe (`EVLAT_PORT`) would post to the user's
        // socket: nothing is sent, and it reads as a refusal — silent in
        // `watch`, one line in `signal`.
        if Isolation.setsRetiredPort(environment) { return .refused(Isolation.retiredPortLine) }
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

    /// `400 invalidTtl: ttl must be …` — the route's stable code and its
    /// message when the body carries them.
    static func refusal(code: Int, body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let name = error["code"] as? String else { return "\(code)" }
        // Whatever holds the socket wrote this, and it goes to a terminal:
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
