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
    /// Asks and exits. The socket and the token come from the mark, never
    /// from `EVLAT_SOCKET` or the home: they name the Evlat that started
    /// this `ssh`. The token travels in a header, never in an argv.
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
        let answer = UnixHTTP.send(Askpass.path, socket: mark.socket,
                                   headers: [(Askpass.header, mark.token),
                                             ("Content-Type", "text/plain; charset=utf-8")],
                                   body: Data(prompt.utf8), timeout: nil)
        guard case .status(200, let data) = answer else { return nil }
        return data
    }
}
